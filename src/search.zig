const std = @import("std");
const storage = @import("storage.zig");
const embedding = @import("embedding.zig");
const simd = @import("simd.zig");
const runtime = @import("runtime.zig");

const sqlite = storage.sqlite;

pub const SearchMode = enum {
    vector,
    lexical,
    hybrid,

    pub fn parse(value: []const u8) !SearchMode {
        if (std.mem.eql(u8, value, "vector")) return .vector;
        if (std.mem.eql(u8, value, "lexical")) return .lexical;
        if (std.mem.eql(u8, value, "hybrid")) return .hybrid;
        return error.InvalidMode;
    }
};

pub const Options = struct {
    top_n: usize = 10,
    candidate_multiplier: usize = 5,
    mode: SearchMode = .hybrid,
    weight_vector: f32 = 1.0,
    weight_lexical: f32 = 1.0,
    weight_recency: f32 = 0.3,
    score_dropoff: f32 = 0.3,
    role_filter: ?[]const u8 = null,
    project_filter: ?[]const u8 = null,
    project_dir_filter: ?[]const u8 = null,
    since: ?[]const u8 = null,
    until: ?[]const u8 = null,
};

/// Reciprocal Rank Fusion smoothing constant (Cormack et al. 2009). Larger k
/// flattens the contribution of top ranks; 60 is the community-standard value.
const rrf_k: f32 = 60.0;

pub const Result = struct {
    id: i64,
    message: storage.Message,
    score: f32,
    distance: f32,
    lexical: f32,
    bm25: f32,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        self.message.deinit(allocator);
        self.* = undefined;
    }
};

pub const SearchResult = struct {
    results: []Result,
    total_relevant: usize,
};

pub fn search(
    allocator: std.mem.Allocator,
    db: storage.Db,
    embedder: ?embedding.Embedder,
    query: []const u8,
    options: Options,
) !SearchResult {
    if (query.len == 0) return error.EmptyQuery;
    if (options.top_n == 0) return .{ .results = try allocator.alloc(Result, 0), .total_relevant = 0 };

    var weight_vector = options.weight_vector;
    var weight_lexical = options.weight_lexical;
    var weight_recency = options.weight_recency;
    if (options.mode == .hybrid) {
        const sum = weight_vector + weight_lexical + weight_recency;
        if (sum <= 0) return error.InvalidWeights;
        weight_vector /= sum;
        weight_lexical /= sum;
        weight_recency /= sum;
    }

    var results = std.ArrayListUnmanaged(Result).empty;
    errdefer {
        for (results.items) |*res| res.deinit(allocator);
        results.deinit(allocator);
    }

    // Reciprocal Rank Fusion (hybrid): remember each candidate's RANK in the
    // vector and lexical rankers so hybrid fuses by rank POSITION (scale-free)
    // rather than summing incomparable raw scores. A doc present in a ranker
    // adds w/(k+rank); absent -> 0. This also fixes the old dedup bug where a
    // vector hit's lexical signal was silently dropped.
    var vrank = std.AutoHashMapUnmanaged(i64, usize){};
    defer vrank.deinit(allocator);
    var lrank = std.AutoHashMapUnmanaged(i64, usize){};
    defer lrank.deinit(allocator);

    const limit = options.top_n * options.candidate_multiplier;

    if (options.mode == .lexical) {
        const lexical = try lexicalCandidates(allocator, db, query, limit, options);
        for (lexical) |res| try results.append(allocator, res);
        allocator.free(lexical);
    } else {
        // Vector search requires an embedder
        if (embedder) |emb| {
            const inputs = [_][]const u8{query};
            const embeddings = try emb.embed(emb.ctx, allocator, &inputs);
            defer emb.free(emb.ctx, allocator, embeddings);
            if (embeddings.len != 1) return error.InvalidEmbeddingCount;

            const vector_results = try vectorCandidates(allocator, db, embeddings[0], limit);
            for (vector_results, 0..) |res, rank| {
                if (options.mode == .hybrid) try vrank.put(allocator, res.id, rank);
                try results.append(allocator, res);
            }
            allocator.free(vector_results);

            if (options.mode == .hybrid) {
                var seen = std.AutoHashMap(i64, void).init(allocator);
                defer seen.deinit();
                for (results.items) |res| try seen.put(res.id, {});

                const lexical = try lexicalCandidates(allocator, db, query, limit, options);
                defer allocator.free(lexical);

                for (lexical, 0..) |res, rank| {
                    try lrank.put(allocator, res.id, rank);
                    if (seen.contains(res.id)) {
                        var tmp = res;
                        tmp.deinit(allocator);
                    } else {
                        try seen.put(res.id, {});
                        try results.append(allocator, res);
                    }
                }
            }
        } else {
            // No embedder available — fall back to lexical
            const lexical = try lexicalCandidates(allocator, db, query, limit, options);
            for (lexical) |res| try results.append(allocator, res);
            allocator.free(lexical);
        }
    }

    // Apply filters
    if (options.role_filter != null or options.project_filter != null or options.project_dir_filter != null or options.since != null or options.until != null) {
        var filtered = std.ArrayListUnmanaged(Result).empty;
        for (results.items) |res| {
            var keep = true;
            if (options.role_filter) |role| {
                if (!std.mem.eql(u8, res.message.role, role)) keep = false;
            }
            if (options.project_filter) |proj| {
                if (!projectMatches(res.message.project_name, res.message.project_dir, proj)) keep = false;
            }
            if (options.project_dir_filter) |pd| {
                if (res.message.project_dir) |mpd| {
                    if (!std.mem.eql(u8, mpd, pd)) keep = false;
                } else keep = false;
            }
            if (options.since != null or options.until != null) {
                if (!dateInRange(res.message.timestamp, options.since, options.until)) keep = false;
            }
            if (keep) {
                try filtered.append(allocator, res);
            } else {
                var tmp = res;
                tmp.deinit(allocator);
            }
        }
        results.deinit(allocator);
        results = filtered;
    }

    // Score and sort
    const now_epoch: i64 = @intCast(@divFloor(std.Io.Timestamp.now(runtime.io(), .real).nanoseconds, std.time.ns_per_s));
    if (options.mode == .hybrid) {
        // Recency is the third RRF ranker: rank survivors newest-first so it acts
        // as a gentle, scale-free tiebreaker instead of a co-equal additive term
        // that recent-but-irrelevant messages could win on outright.
        const rec = try allocator.alloc(f32, results.items.len);
        defer allocator.free(rec);
        const order = try allocator.alloc(usize, results.items.len);
        defer allocator.free(order);
        for (results.items, 0..) |res, i| {
            rec[i] = computeRecencyScore(res.message.timestamp, now_epoch);
            order[i] = i;
        }
        std.mem.sortUnstable(usize, order, @as([]const f32, rec), struct {
            fn lessThan(r: []const f32, a: usize, b: usize) bool {
                return r[a] > r[b]; // newest (highest recency) first
            }
        }.lessThan);
        for (order, 0..) |res_idx, recency_pos| {
            const res = &results.items[res_idx];
            var fused: f32 = 0;
            if (vrank.get(res.id)) |r| fused += weight_vector / (rrf_k + @as(f32, @floatFromInt(r)));
            if (lrank.get(res.id)) |r| fused += weight_lexical / (rrf_k + @as(f32, @floatFromInt(r)));
            fused += weight_recency / (rrf_k + @as(f32, @floatFromInt(recency_pos)));
            res.score = fused;
        }
    } else {
        for (results.items) |*res| {
            res.score = switch (options.mode) {
                .lexical => res.lexical,
                .vector => if (res.distance >= 0) 1.0 / (1.0 + res.distance) else 0,
                .hybrid => unreachable,
            };
        }
    }

    // Sort by score descending
    std.mem.sortUnstable(Result, results.items, {}, struct {
        fn lessThan(_: void, a: Result, b: Result) bool {
            return a.score > b.score;
        }
    }.lessThan);

    // Collapse to the best-scoring message per conversation (F1). Results are
    // sorted by score desc, so the FIRST time a conversation key is seen is its
    // best message; later messages from the same conversation are dropped so the
    // list surfaces DISTINCT conversations, not fragments of one. In-place
    // compaction (write <= read always) avoids aliasing the payload pointers.
    {
        var seen_conv = std.StringHashMapUnmanaged(void){};
        defer seen_conv.deinit(allocator);
        var write: usize = 0;
        for (results.items) |res| {
            const key = res.message.session_id orelse res.message.file_path;
            if (seen_conv.contains(key)) {
                var tmp = res;
                tmp.deinit(allocator); // drop duplicate conversation message
            } else {
                // On OOM, keep the item anyway (a stray duplicate beats a leak).
                seen_conv.put(allocator, key, {}) catch {};
                results.items[write] = res;
                write += 1;
            }
        }
        results.shrinkRetainingCapacity(write);
    }

    // Score dropoff
    const total_relevant = blk: {
        if (results.items.len == 0) break :blk @as(usize, 0);
        const top_score = results.items[0].score;
        const threshold = top_score * options.score_dropoff;
        var count: usize = results.items.len;
        for (results.items, 0..) |res, idx| {
            if (res.score < threshold) {
                count = idx;
                break;
            }
        }
        break :blk count;
    };

    // Trim to top_n
    const final_count = @min(options.top_n, total_relevant);
    for (results.items[final_count..]) |*res| res.deinit(allocator);
    results.shrinkRetainingCapacity(final_count);

    return SearchResult{
        .results = try results.toOwnedSlice(allocator),
        .total_relevant = total_relevant,
    };
}

fn vectorCandidates(
    allocator: std.mem.Allocator,
    db: storage.Db,
    query_vec: []const f32,
    limit: usize,
) ![]Result {
    const json = try storage.vectorToJson(allocator, query_vec);
    defer allocator.free(json);

    const sql =
        \\SELECT m.id, m.file_path, m.line_number, m.role, m.content,
        \\       m.timestamp, m.session_id, m.project_name, m.project_dir,
        \\       e.distance
        \\FROM embeddings AS e
        \\JOIN messages AS m ON e.rowid = m.id
        \\WHERE e.embedding MATCH vec_f32(?1) AND k = ?2
        \\ORDER BY e.distance
    ;

    var stmt: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != sqlite.SQLITE_OK) {
        return allocator.alloc(Result, 0);
    }
    defer _ = sqlite.sqlite3_finalize(stmt);
    const s = stmt.?;

    storage.bindTextPub(s, 1, json);
    _ = sqlite.sqlite3_bind_int(s, 2, @intCast(limit));

    var results = std.ArrayListUnmanaged(Result).empty;
    errdefer {
        for (results.items) |*res| res.deinit(allocator);
        results.deinit(allocator);
    }

    while (sqlite.sqlite3_step(s) == sqlite.SQLITE_ROW) {
        try results.append(allocator, .{
            .id = sqlite.sqlite3_column_int64(s, 0),
            .message = .{
                .id = sqlite.sqlite3_column_int64(s, 0),
                .file_path = try allocator.dupe(u8, storage.columnText(s, 1)),
                .line_number = sqlite.sqlite3_column_int64(s, 2),
                .role = try allocator.dupe(u8, storage.columnText(s, 3)),
                .content = try allocator.dupe(u8, storage.columnText(s, 4)),
                .timestamp = if (storage.columnTextOpt(s, 5)) |t| try allocator.dupe(u8, t) else null,
                .session_id = if (storage.columnTextOpt(s, 6)) |t| try allocator.dupe(u8, t) else null,
                .project_name = if (storage.columnTextOpt(s, 7)) |t| try allocator.dupe(u8, t) else null,
                .project_dir = if (storage.columnTextOpt(s, 8)) |t| try allocator.dupe(u8, t) else null,
            },
            .score = 0,
            .distance = @floatCast(sqlite.sqlite3_column_double(s, 9)),
            .lexical = 0,
            .bm25 = 0,
        });
    }

    return results.toOwnedSlice(allocator);
}

/// Build a case-insensitive LIKE pattern for a `--project` filter: wrap with %,
/// mapping '/' to the slug separator '-' so a path fragment matches project_dir.
/// This is an equal-or-superset of projectMatches (which still runs as the exact
/// final filter), so pushing it into SQL only lets LIMIT apply to filtered rows.
fn projectLikePattern(allocator: std.mem.Allocator, filter: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, filter.len + 2);
    out[0] = '%';
    for (filter, 0..) |c, i| out[i + 1] = if (c == '/') '-' else c;
    out[filter.len + 1] = '%';
    return out;
}

/// Append " AND ..." clauses for the active filters using column prefix `prefix`
/// ("m." for joined queries, "" for the bare messages table). The emit order
/// MUST match bindActiveFilters. These narrow the candidate set BEFORE LIMIT;
/// the exact Zig filter pass still runs, so results are unchanged in content.
fn appendFilterClauses(w: *std.Io.Writer, prefix: []const u8, o: Options) !void {
    if (o.role_filter != null) try w.print(" AND {s}role = ?", .{prefix});
    if (o.since != null) try w.print(" AND substr({s}timestamp, 1, 10) >= ?", .{prefix});
    if (o.until != null) try w.print(" AND substr({s}timestamp, 1, 10) <= ?", .{prefix});
    if (o.project_dir_filter != null) try w.print(" AND {s}project_dir = ?", .{prefix});
    if (o.project_filter != null) try w.print(" AND ({s}project_name LIKE ? OR {s}project_dir LIKE ?)", .{ prefix, prefix });
}

/// Bind the active filters at 1-based index `start`, in appendFilterClauses order.
/// `proj_pat` (the LIKE pattern) must outlive the step; null when no project filter.
fn bindActiveFilters(s: *sqlite.sqlite3_stmt, start: c_int, o: Options, proj_pat: ?[]const u8) c_int {
    var idx = start;
    if (o.role_filter) |v| {
        storage.bindTextPub(s, idx, v);
        idx += 1;
    }
    if (o.since) |v| {
        storage.bindTextPub(s, idx, v);
        idx += 1;
    }
    if (o.until) |v| {
        storage.bindTextPub(s, idx, v);
        idx += 1;
    }
    if (o.project_dir_filter) |v| {
        storage.bindTextPub(s, idx, v);
        idx += 1;
    }
    if (o.project_filter != null) {
        storage.bindTextPub(s, idx, proj_pat.?);
        idx += 1;
        storage.bindTextPub(s, idx, proj_pat.?);
        idx += 1;
    }
    return idx;
}

fn lexicalCandidates(
    allocator: std.mem.Allocator,
    db: storage.Db,
    query: []const u8,
    limit: usize,
    options: Options,
) ![]Result {
    // Try FTS5 first
    const fts_results = try ftsCandidates(allocator, db, query, limit, options);
    if (fts_results.len > 0) return fts_results;
    allocator.free(fts_results);

    // Fall back to LIKE
    return likeCandidates(allocator, db, query, limit, options);
}

fn ftsCandidates(
    allocator: std.mem.Allocator,
    db: storage.Db,
    query: []const u8,
    limit: usize,
    options: Options,
) ![]Result {
    var sqlbuf: std.Io.Writer.Allocating = .init(allocator);
    defer sqlbuf.deinit();
    try sqlbuf.writer.writeAll(
        \\SELECT m.id, m.file_path, m.line_number, m.role, m.content,
        \\       m.timestamp, m.session_id, m.project_name, m.project_dir,
        \\       bm25(messages_fts, 1.0)
        \\FROM messages_fts AS fts
        \\JOIN messages AS m ON fts.rowid = m.id
        \\WHERE messages_fts MATCH ?
    );
    try appendFilterClauses(&sqlbuf.writer, "m.", options);
    try sqlbuf.writer.writeAll("\nORDER BY bm25(messages_fts, 1.0)\nLIMIT ?");
    const sql = try sqlbuf.toOwnedSlice();
    defer allocator.free(sql);

    var stmt: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null) != sqlite.SQLITE_OK) {
        return allocator.alloc(Result, 0);
    }
    defer _ = sqlite.sqlite3_finalize(stmt);
    const s = stmt.?;

    // Build FTS query: OR all tokens for broad matching
    const fts_query = try buildFtsQuery(allocator, query);
    defer allocator.free(fts_query);
    const proj_pat = if (options.project_filter) |pf| try projectLikePattern(allocator, pf) else null;
    defer if (proj_pat) |pp| allocator.free(pp);

    storage.bindTextPub(s, 1, fts_query);
    const limit_idx = bindActiveFilters(s, 2, options, proj_pat);
    _ = sqlite.sqlite3_bind_int(s, limit_idx, @intCast(limit));

    var results = std.ArrayListUnmanaged(Result).empty;
    errdefer {
        for (results.items) |*res| res.deinit(allocator);
        results.deinit(allocator);
    }

    while (sqlite.sqlite3_step(s) == sqlite.SQLITE_ROW) {
        const raw_bm25 = sqlite.sqlite3_column_double(s, 9);
        // FTS5 bm25 is negative (lower = better); normalize to 0-1
        const normalized: f32 = @floatCast(1.0 / (1.0 + @abs(raw_bm25)));

        try results.append(allocator, .{
            .id = sqlite.sqlite3_column_int64(s, 0),
            .message = .{
                .id = sqlite.sqlite3_column_int64(s, 0),
                .file_path = try allocator.dupe(u8, storage.columnText(s, 1)),
                .line_number = sqlite.sqlite3_column_int64(s, 2),
                .role = try allocator.dupe(u8, storage.columnText(s, 3)),
                .content = try allocator.dupe(u8, storage.columnText(s, 4)),
                .timestamp = if (storage.columnTextOpt(s, 5)) |t| try allocator.dupe(u8, t) else null,
                .session_id = if (storage.columnTextOpt(s, 6)) |t| try allocator.dupe(u8, t) else null,
                .project_name = if (storage.columnTextOpt(s, 7)) |t| try allocator.dupe(u8, t) else null,
                .project_dir = if (storage.columnTextOpt(s, 8)) |t| try allocator.dupe(u8, t) else null,
            },
            .score = 0,
            .distance = -1,
            .lexical = normalized,
            .bm25 = @floatCast(raw_bm25),
        });
    }

    return results.toOwnedSlice(allocator);
}

fn likeCandidates(
    allocator: std.mem.Allocator,
    db: storage.Db,
    query: []const u8,
    limit: usize,
    options: Options,
) ![]Result {
    const like_pattern = try allocPrintZ(allocator, "%{s}%", .{query});
    defer allocator.free(like_pattern);

    var sqlbuf: std.Io.Writer.Allocating = .init(allocator);
    defer sqlbuf.deinit();
    try sqlbuf.writer.writeAll(
        \\SELECT id, file_path, line_number, role, content,
        \\       timestamp, session_id, project_name, project_dir
        \\FROM messages
        \\WHERE content LIKE ? COLLATE NOCASE
    );
    try appendFilterClauses(&sqlbuf.writer, "", options);
    try sqlbuf.writer.writeAll("\nLIMIT ?");
    const sql = try sqlbuf.toOwnedSlice();
    defer allocator.free(sql);

    var stmt: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null) != sqlite.SQLITE_OK) {
        return allocator.alloc(Result, 0);
    }
    defer _ = sqlite.sqlite3_finalize(stmt);
    const s = stmt.?;

    const proj_pat = if (options.project_filter) |pf| try projectLikePattern(allocator, pf) else null;
    defer if (proj_pat) |pp| allocator.free(pp);

    storage.bindTextPub(s, 1, like_pattern);
    const limit_idx = bindActiveFilters(s, 2, options, proj_pat);
    _ = sqlite.sqlite3_bind_int(s, limit_idx, @intCast(limit));

    var results = std.ArrayListUnmanaged(Result).empty;
    errdefer {
        for (results.items) |*res| res.deinit(allocator);
        results.deinit(allocator);
    }

    while (sqlite.sqlite3_step(s) == sqlite.SQLITE_ROW) {
        try results.append(allocator, .{
            .id = sqlite.sqlite3_column_int64(s, 0),
            .message = .{
                .id = sqlite.sqlite3_column_int64(s, 0),
                .file_path = try allocator.dupe(u8, storage.columnText(s, 1)),
                .line_number = sqlite.sqlite3_column_int64(s, 2),
                .role = try allocator.dupe(u8, storage.columnText(s, 3)),
                .content = try allocator.dupe(u8, storage.columnText(s, 4)),
                .timestamp = if (storage.columnTextOpt(s, 5)) |t| try allocator.dupe(u8, t) else null,
                .session_id = if (storage.columnTextOpt(s, 6)) |t| try allocator.dupe(u8, t) else null,
                .project_name = if (storage.columnTextOpt(s, 7)) |t| try allocator.dupe(u8, t) else null,
                .project_dir = if (storage.columnTextOpt(s, 8)) |t| try allocator.dupe(u8, t) else null,
            },
            .score = 0,
            .distance = -1,
            .lexical = 0.5, // Basic relevance for LIKE match
            .bm25 = 0,
        });
    }

    return results.toOwnedSlice(allocator);
}

fn buildFtsQuery(allocator: std.mem.Allocator, query: []const u8) ![:0]u8 {
    // Tokenize query and join with OR for broad matching
    var tokens = std.ArrayListUnmanaged([]const u8).empty;
    defer tokens.deinit(allocator);

    var iter = std.mem.tokenizeAny(u8, query, " \t\n\r");
    while (iter.next()) |token| {
        if (token.len >= 2) { // Skip very short tokens
            try tokens.append(allocator, token);
        }
    }

    if (tokens.items.len == 0) {
        return allocPrintZ(allocator, "\"{s}\"", .{query});
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    for (tokens.items, 0..) |token, idx| {
        if (idx > 0) try out.writer.writeAll(" OR ");
        try out.writer.print("\"{s}\"", .{token});
    }

    const slice = try out.toOwnedSlice();
    const result = try allocator.allocSentinel(u8, slice.len, 0);
    @memcpy(result, slice);
    allocator.free(slice);
    return result;
}

fn allocPrintZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    const tmp = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(tmp);
    return allocator.dupeZ(u8, tmp);
}

/// Normalize a byte for project matching: ASCII-lowercase, and treat the path
/// separator '/' as equivalent to the conversation-dir slug separator '-' so a
/// user can pass either a real path fragment or a slug fragment.
fn normProjectChar(ch: u8) u8 {
    const lc = std.ascii.toLower(ch);
    return if (lc == '/') '-' else lc;
}

/// Case-insensitive, separator-insensitive substring test (haystack contains needle).
/// O(n*m) but project strings are short; avoids any allocation on the filter path.
fn containsNormalized(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (normProjectChar(haystack[i + j]) != normProjectChar(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

/// Does a message's project satisfy a `--project` filter? Partial + case-insensitive:
/// matches when `filter` is a substring of either the project name OR the project dir
/// slug (with '/' treated as '-'). This is what lets `--project Code/codescan` or
/// `--project codes` narrow to the right project instead of requiring the exact name.
pub fn projectMatches(project_name: ?[]const u8, project_dir: ?[]const u8, filter: []const u8) bool {
    if (project_name) |pn| {
        if (containsNormalized(pn, filter)) return true;
    }
    if (project_dir) |pd| {
        if (containsNormalized(pd, filter)) return true;
    }
    return false;
}

/// Inclusive day-range filter: keep a message whose timestamp's date (YYYY-MM-DD)
/// falls within [since, until]. Bounds are "YYYY-MM-DD" (or null). ISO-8601
/// timestamps sort lexicographically, so we compare the leading 10-char date slice.
/// A message with no usable timestamp fails any active date filter.
pub fn dateInRange(timestamp: ?[]const u8, since: ?[]const u8, until: ?[]const u8) bool {
    if (since == null and until == null) return true;
    const ts = timestamp orelse return false;
    if (ts.len < 10) return false;
    const ts_date = ts[0..10];
    if (since) |s| {
        if (std.mem.order(u8, ts_date, s) == .lt) return false;
    }
    if (until) |u| {
        if (std.mem.order(u8, ts_date, u) == .gt) return false;
    }
    return true;
}



/// Compute a recency score from 0.0 (ancient) to 1.0 (now).
/// Uses exponential decay with a half-life of 30 days.
fn computeRecencyScore(timestamp: ?[]const u8, now_epoch: i64) f32 {
    const ts = timestamp orelse return 0.0;
    const msg_epoch = parseIso8601(ts) orelse return 0.0;
    const age_secs = now_epoch - msg_epoch;
    if (age_secs <= 0) return 1.0;
    // Half-life of 30 days = 2592000 seconds
    const half_life: f64 = 30.0 * 24.0 * 3600.0;
    const decay: f64 = @exp(-0.693147 * @as(f64, @floatFromInt(age_secs)) / half_life);
    return @floatCast(decay);
}

/// Parse a subset of ISO 8601 timestamps (YYYY-MM-DDTHH:MM:SS) to epoch seconds.
fn parseIso8601(ts: []const u8) ?i64 {
    // Minimum: "YYYY-MM-DDTHH:MM:SS" = 19 chars
    if (ts.len < 19) return null;
    const year = std.fmt.parseInt(i64, ts[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, ts[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, ts[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, ts[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, ts[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, ts[17..19], 10) catch return null;

    // Days from epoch (1970-01-01) using the civil calendar algorithm
    var y = year;
    var m = month;
    if (m <= 2) {
        y -= 1;
        m += 12;
    }
    const era_days = 365 * y + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400) +
        @divFloor(306 * (m + 1), 10) + day - 719591;
    return era_days * 86400 + hour * 3600 + minute * 60 + second;
}

pub fn freeResults(allocator: std.mem.Allocator, results: []Result) void {
    for (results) |*res| {
        var r = res.*;
        r.deinit(allocator);
    }
    allocator.free(results);
}

// ── Tests ────────────────────────────────────────────────────────────

test "buildFtsQuery" {
    const allocator = std.testing.allocator;
    const q = try buildFtsQuery(allocator, "SIMD optimization");
    defer allocator.free(q);
    try std.testing.expectEqualStrings("\"SIMD\" OR \"optimization\"", q);
}

test "buildFtsQuery single token" {
    const allocator = std.testing.allocator;
    const q = try buildFtsQuery(allocator, "hello");
    defer allocator.free(q);
    try std.testing.expectEqualStrings("\"hello\"", q);
}

test "parseIso8601 basic" {
    // 2026-03-07T12:00:00Z -> should produce a reasonable epoch
    const epoch = parseIso8601("2026-03-07T12:00:00Z").?;
    // 2026-03-07 is about 56 years after 1970, roughly 1.77 billion seconds
    try std.testing.expect(epoch > 1_770_000_000);
    try std.testing.expect(epoch < 1_780_000_000);
}

test "computeRecencyScore recent is high" {
    const now: i64 = @intCast(@divFloor(std.Io.Timestamp.now(runtime.io(), .real).nanoseconds, std.time.ns_per_s));
    _ = now;
    // A message from "now" should score ~1.0
    const score_recent = computeRecencyScore("2026-03-07T12:00:00Z", parseIso8601("2026-03-07T12:00:00Z").?);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), score_recent, 0.01);
}

test "computeRecencyScore old is low" {
    // A message from 6 months ago should score much lower
    const now = parseIso8601("2026-03-07T12:00:00Z").?;
    const score = computeRecencyScore("2025-09-07T12:00:00Z", now);
    try std.testing.expect(score < 0.1);
}

test "computeRecencyScore null timestamp" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), computeRecencyScore(null, 0), 0.001);
}

test "search with empty query returns error" {
    const allocator = std.testing.allocator;
    const db = try storage.openMemoryWithVec(allocator);
    defer storage.close(db);
    var result = try storage.initSchema(allocator, db, .{ .embedding_dim = 1024 });
    defer result.deinit(allocator);

    try std.testing.expectError(error.EmptyQuery, search(allocator, db, null, "", .{}));
}

test "search with zero top_n returns empty" {
    const allocator = std.testing.allocator;
    const db = try storage.openMemoryWithVec(allocator);
    defer storage.close(db);
    var result = try storage.initSchema(allocator, db, .{ .embedding_dim = 1024 });
    defer result.deinit(allocator);

    const sr = try search(allocator, db, null, "test", .{ .top_n = 0 });
    defer allocator.free(sr.results);
    try std.testing.expectEqual(@as(usize, 0), sr.results.len);
}


test "projectMatches: partial name/path, case-insensitive, classifier over a set" {
    // Exact name still matches.
    try std.testing.expect(projectMatches("codescan", "-Users-pmarreck-Code-codescan", "codescan"));
    // Substring of the name.
    try std.testing.expect(projectMatches("codescan", "-Users-pmarreck-Code-codescan", "codes"));
    // Case-insensitive.
    try std.testing.expect(projectMatches("codescan", "-Users-pmarreck-Code-codescan", "CODESCAN"));
    // Partial PATH: user types '/', slug uses '-' — they must be equivalent.
    try std.testing.expect(projectMatches("codescan", "-Users-pmarreck-Code-codescan", "Code/codescan"));
    try std.testing.expect(projectMatches("codescan", "-Users-pmarreck-Code-codescan", "code-codescan"));
    // Non-match.
    try std.testing.expect(!projectMatches("codescan", "-Users-pmarreck-Code-codescan", "validate"));

    // As a classifier over a SET: "scan" selects the scan-projects, rejects validate.
    try std.testing.expect(projectMatches("chatscan", "-x-chatscan", "scan"));
    try std.testing.expect(projectMatches("docscan", "-x-docscan", "scan"));
    try std.testing.expect(!projectMatches("validate", "-x-validate", "scan"));

    // Null fields never match a non-empty filter.
    try std.testing.expect(!projectMatches(null, null, "anything"));
    // Empty filter is a no-op (matches anything present).
    try std.testing.expect(projectMatches("codescan", null, ""));
}

test "lexical search finds indexed messages and --project partial-path filter narrows over a set" {
    const allocator = std.testing.allocator;
    const db = try storage.openMemoryWithVec(allocator);
    defer storage.close(db);
    var schema = try storage.initSchema(allocator, db, .{ .embedding_dim = 1024 });
    defer schema.deinit(allocator);

    // Two different projects, both mentioning "html".
    _ = try storage.insertMessage(db, .{
        .file_path = "a.jsonl", .line_number = 1, .role = "user",
        .content = "how do I render html here", .timestamp = null, .session_id = null,
        .project_name = "codescan", .project_dir = "-Users-pmarreck-Code-codescan",
    });
    _ = try storage.insertMessage(db, .{
        .file_path = "b.jsonl", .line_number = 1, .role = "user",
        .content = "the html output looks wrong", .timestamp = null, .session_id = null,
        .project_name = "validate", .project_dir = "-Users-pmarreck-Code-validate",
    });

    // Baseline (the previously-untested core contract): lexical search finds BOTH across projects.
    const all = try search(allocator, db, null, "html", .{ .mode = .lexical, .top_n = 10 });
    defer freeResults(allocator, all.results);
    try std.testing.expectEqual(@as(usize, 2), all.results.len);

    // Narrow to just codescan using a PARTIAL PATH fragment.
    const scoped = try search(allocator, db, null, "html", .{
        .mode = .lexical, .top_n = 10, .project_filter = "Code/codescan",
    });
    defer freeResults(allocator, scoped.results);
    try std.testing.expectEqual(@as(usize, 1), scoped.results.len);
    try std.testing.expectEqualStrings("codescan", scoped.results[0].message.project_name.?);

    // A non-matching filter yields nothing (and is not an error).
    const none = try search(allocator, db, null, "html", .{
        .mode = .lexical, .top_n = 10, .project_filter = "no-such-project",
    });
    defer freeResults(allocator, none.results);
    try std.testing.expectEqual(@as(usize, 0), none.results.len);
}


test "vector-mode search over an in-memory sqlite-vec index does not crash" {
    const allocator = std.testing.allocator;
    const db = try storage.openMemoryWithVec(allocator);
    defer storage.close(db);
    var schema = try storage.initSchema(allocator, db, .{ .embedding_dim = 1024 });
    defer schema.deinit(allocator);

    // Insert several messages, each with a real 1024-dim embedding, so the
    // KNN MATCH has multiple rows to rank (mirrors the crashing real query).
    var n: usize = 0;
    while (n < 20) : (n += 1) {
        const rowid = try storage.insertMessage(db, .{
            .file_path = "a.jsonl", .line_number = @intCast(n + 1), .role = "user",
            .content = "vector target about html and dirtree", .timestamp = null, .session_id = null,
            .project_name = "alpha", .project_dir = "-x-alpha",
        });
        var vec: [1024]f32 = undefined;
        for (&vec, 0..) |*e, i| e.* = @floatFromInt(@as(i32, @intCast((i + n) % 7)));
        try storage.insertEmbedding(db, allocator, rowid, &vec);
    }

    const MockEmb = struct {
        buf: [1024]f32,
        fn embed(ctx: *anyopaque, alloc: std.mem.Allocator, inputs: []const []const u8) anyerror![][]f32 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const out = try alloc.alloc([]f32, inputs.len);
            for (out) |*o| o.* = try alloc.dupe(f32, &self.buf);
            return out;
        }
        fn free(ctx: *anyopaque, alloc: std.mem.Allocator, embs: [][]f32) void {
            _ = ctx;
            for (embs) |e| alloc.free(e);
            alloc.free(embs);
        }
    };
    var qvec: [1024]f32 = undefined;
    for (&qvec, 0..) |*e, i| e.* = @floatFromInt(@as(i32, @intCast(i % 7)));
    var mock = MockEmb{ .buf = qvec };
    const embedder = embedding.Embedder{ .ctx = @ptrCast(&mock), .embed = MockEmb.embed, .free = MockEmb.free };

    // This is the path that traps under ReleaseFast/ReleaseSafe (sqlite-vec KNN step).
    const sr = try search(allocator, db, embedder, "html", .{ .mode = .vector, .top_n = 10 });
    defer freeResults(allocator, sr.results);
    try std.testing.expect(sr.results.len >= 1);
}


test "dateInRange: since/until as an inclusive day-range classifier over a set" {
    const ts_jun30 = "2026-06-30T23:59:00.000Z";
    const ts_jul01a = "2026-07-01T00:10:00.000Z";
    const ts_jul01b = "2026-07-01T13:45:00.000Z";
    const ts_jul02 = "2026-07-02T08:00:00.000Z";

    // No bounds: everything passes (including null timestamps).
    try std.testing.expect(dateInRange(ts_jul01a, null, null));
    try std.testing.expect(dateInRange(null, null, null));

    // --since 2026-07-01 (inclusive lower bound): drops Jun 30, keeps Jul 1 & 2.
    try std.testing.expect(!dateInRange(ts_jun30, "2026-07-01", null));
    try std.testing.expect(dateInRange(ts_jul01a, "2026-07-01", null));
    try std.testing.expect(dateInRange(ts_jul02, "2026-07-01", null));

    // --until 2026-07-01 (inclusive upper bound): keeps Jun 30 & all of Jul 1, drops Jul 2.
    try std.testing.expect(dateInRange(ts_jun30, null, "2026-07-01"));
    try std.testing.expect(dateInRange(ts_jul01b, null, "2026-07-01"));
    try std.testing.expect(!dateInRange(ts_jul02, null, "2026-07-01"));

    // Range: only Jul 1 (both timestamps that day), excludes the neighbours.
    try std.testing.expect(!dateInRange(ts_jun30, "2026-07-01", "2026-07-01"));
    try std.testing.expect(dateInRange(ts_jul01a, "2026-07-01", "2026-07-01"));
    try std.testing.expect(dateInRange(ts_jul01b, "2026-07-01", "2026-07-01"));
    try std.testing.expect(!dateInRange(ts_jul02, "2026-07-01", "2026-07-01"));

    // A message with no timestamp cannot satisfy an active date filter.
    try std.testing.expect(!dateInRange(null, "2026-07-01", null));
    try std.testing.expect(!dateInRange(null, null, "2026-07-01"));
}


test "filtered search finds a target ranked beyond the FTS candidate limit" {
    // Repro: filters used to run AFTER the top_n*multiplier FTS limit, so a
    // low-bm25 matching row in the target project/date was cut before filtering.
    const allocator = std.testing.allocator;
    const db = try storage.openMemoryWithVec(allocator);
    defer storage.close(db);
    var schema = try storage.initSchema(allocator, db, .{ .embedding_dim = 1024 });
    defer schema.deinit(allocator);

    // 50 strong-matching noise rows (higher bm25) in a different project/day.
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        _ = try storage.insertMessage(db, .{
            .file_path = "noise.jsonl", .line_number = @intCast(i + 1), .role = "user",
            .content = "html html html html html noise", .timestamp = "2026-01-01T00:00:00Z",
            .session_id = null, .project_name = "noise", .project_dir = "-x-noise",
        });
    }
    // 1 weak-matching target row (lower bm25) in the project/day we filter to.
    _ = try storage.insertMessage(db, .{
        .file_path = "target.jsonl", .line_number = 1, .role = "user",
        .content = "a single html mention", .timestamp = "2026-06-01T00:00:00Z",
        .session_id = null, .project_name = "target", .project_dir = "-x-target",
    });

    // top_n=3 -> old FTS limit=15 fills with noise, cutting the target.
    const by_project = try search(allocator, db, null, "html", .{
        .mode = .lexical, .top_n = 3, .project_filter = "target",
    });
    defer freeResults(allocator, by_project.results);
    try std.testing.expectEqual(@as(usize, 1), by_project.results.len);
    try std.testing.expectEqualStrings("target", by_project.results[0].message.project_name.?);

    // Same story for a date filter.
    const by_date = try search(allocator, db, null, "html", .{
        .mode = .lexical, .top_n = 3, .since = "2026-06-01", .until = "2026-06-01",
    });
    defer freeResults(allocator, by_date.results);
    try std.testing.expectEqual(@as(usize, 1), by_date.results.len);
    try std.testing.expectEqualStrings("target", by_date.results[0].message.project_name.?);
}

test "hybrid ranks an exact-term match above recent semantically-adjacent noise" {
    // Repro of the "Ghostty window" complaint: the ONE conversation that
    // actually contains the query terms is old and a weak vector match, while
    // several RECENT, semantically-adjacent-but-textually-irrelevant messages
    // are strong vector hits. Hybrid must still surface the exact-term match
    // first — a term the user typed and KNOWS is in a conversation must win.
    const allocator = std.testing.allocator;
    const db = try storage.openMemoryWithVec(allocator);
    defer storage.close(db);
    var schema = try storage.initSchema(allocator, db, .{ .embedding_dim = 1024 });
    defer schema.deinit(allocator);

    // 8 recent noise rows: no query terms, embedding == query vector (distance 0).
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const rowid = try storage.insertMessage(db, .{
            .file_path = "noise.jsonl", .line_number = @intCast(i + 1), .role = "assistant",
            .content = "quarterly zebra migration patterns across the savanna",
            .timestamp = "2026-07-26T00:00:00Z", .session_id = null,
            .project_name = "noise", .project_dir = "-x-noise",
        });
        var vec: [1024]f32 = undefined;
        for (&vec) |*e| e.* = 1.0; // identical to the query vector -> distance 0
        try storage.insertEmbedding(db, allocator, rowid, &vec);
    }

    // 1 old target row: contains BOTH query terms, embedding far from query.
    const target = try storage.insertMessage(db, .{
        .file_path = "dotfiles.jsonl", .line_number = 1, .role = "assistant",
        .content = "to make the ghostty window start out wider set window-width on startup",
        .timestamp = "2026-01-01T00:00:00Z", .session_id = null,
        .project_name = "dotfiles", .project_dir = "-x-dotfiles",
    });
    var tvec: [1024]f32 = undefined;
    for (&tvec) |*e| e.* = 0.0; // far from the all-ones query vector
    try storage.insertEmbedding(db, allocator, target, &tvec);

    // Mock embedder: query "ghostty window" -> all-ones vector (matches noise).
    const MockEmb = struct {
        buf: [1024]f32,
        fn embed(ctx: *anyopaque, alloc: std.mem.Allocator, inputs: []const []const u8) anyerror![][]f32 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const out = try alloc.alloc([]f32, inputs.len);
            for (out) |*o| o.* = try alloc.dupe(f32, &self.buf);
            return out;
        }
        fn free(ctx: *anyopaque, alloc: std.mem.Allocator, embs: [][]f32) void {
            _ = ctx;
            for (embs) |e| alloc.free(e);
            alloc.free(embs);
        }
    };
    var qvec: [1024]f32 = undefined;
    for (&qvec) |*e| e.* = 1.0;
    var mock = MockEmb{ .buf = qvec };
    const embedder = embedding.Embedder{ .ctx = @ptrCast(&mock), .embed = MockEmb.embed, .free = MockEmb.free };

    const sr = try search(allocator, db, embedder, "ghostty window", .{ .mode = .hybrid, .top_n = 5 });
    defer freeResults(allocator, sr.results);

    try std.testing.expect(sr.results.len >= 1);
    // The exact-term match must be the #1 result, not buried under recent noise.
    try std.testing.expect(std.mem.indexOf(u8, sr.results[0].message.content, "ghostty") != null);
}

test "results are deduped to the best message per conversation" {
    // F1: one conversation with many matching messages must not flood the
    // result list — collapse to the single best-scoring message per session so
    // N slots surface N distinct conversations.
    const allocator = std.testing.allocator;
    const db = try storage.openMemoryWithVec(allocator);
    defer storage.close(db);
    var schema = try storage.initSchema(allocator, db, .{ .embedding_dim = 1024 });
    defer schema.deinit(allocator);

    // Conversation A: 5 matching messages in one file/session.
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        _ = try storage.insertMessage(db, .{
            .file_path = "conv-a.jsonl", .line_number = @intCast(i + 1), .role = "assistant",
            .content = "alpha discussion about the alpha topic in depth", .timestamp = null,
            .session_id = "sess-a", .project_name = "proj", .project_dir = "-x-proj",
        });
    }
    // Conversation B: a single matching message.
    _ = try storage.insertMessage(db, .{
        .file_path = "conv-b.jsonl", .line_number = 1, .role = "assistant",
        .content = "alpha appears here exactly once", .timestamp = null,
        .session_id = "sess-b", .project_name = "proj", .project_dir = "-x-proj",
    });

    const sr = try search(allocator, db, null, "alpha", .{ .mode = .lexical, .top_n = 10 });
    defer freeResults(allocator, sr.results);

    // Two conversations -> exactly two results, not six.
    try std.testing.expectEqual(@as(usize, 2), sr.results.len);
    try std.testing.expect(!std.mem.eql(u8,
        sr.results[0].message.session_id.?, sr.results[1].message.session_id.?));
}
