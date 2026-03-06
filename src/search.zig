const std = @import("std");
const storage = @import("storage.zig");
const embedding = @import("embedding.zig");
const simd = @import("simd.zig");

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
    weight_vector: f32 = 0.7,
    weight_lexical: f32 = 0.3,
    score_dropoff: f32 = 0.3,
    role_filter: ?[]const u8 = null,
    project_filter: ?[]const u8 = null,
    project_dir_filter: ?[]const u8 = null,
};

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
    if (options.mode == .hybrid) {
        const sum = weight_vector + weight_lexical;
        if (sum <= 0) return error.InvalidWeights;
        weight_vector /= sum;
        weight_lexical /= sum;
    }

    var results = std.ArrayListUnmanaged(Result){};
    errdefer {
        for (results.items) |*res| res.deinit(allocator);
        results.deinit(allocator);
    }

    const limit = options.top_n * options.candidate_multiplier;

    if (options.mode == .lexical) {
        const lexical = try lexicalCandidates(allocator, db, query, limit);
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
            for (vector_results) |res| try results.append(allocator, res);
            allocator.free(vector_results);

            if (options.mode == .hybrid) {
                var seen = std.AutoHashMap(i64, void).init(allocator);
                defer seen.deinit();
                for (results.items) |res| try seen.put(res.id, {});

                const lexical = try lexicalCandidates(allocator, db, query, limit);
                defer allocator.free(lexical);

                for (lexical) |res| {
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
            const lexical = try lexicalCandidates(allocator, db, query, limit);
            for (lexical) |res| try results.append(allocator, res);
            allocator.free(lexical);
        }
    }

    // Apply filters
    if (options.role_filter != null or options.project_filter != null or options.project_dir_filter != null) {
        var filtered = std.ArrayListUnmanaged(Result){};
        for (results.items) |res| {
            var keep = true;
            if (options.role_filter) |role| {
                if (!std.mem.eql(u8, res.message.role, role)) keep = false;
            }
            if (options.project_filter) |proj| {
                if (res.message.project_name) |pn| {
                    if (!simd.eqlIgnoreCase(pn, proj)) keep = false;
                } else keep = false;
            }
            if (options.project_dir_filter) |pd| {
                if (res.message.project_dir) |mpd| {
                    if (!std.mem.eql(u8, mpd, pd)) keep = false;
                } else keep = false;
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
    for (results.items) |*res| {
        const vec_score: f32 = if (res.distance >= 0) 1.0 / (1.0 + res.distance) else 0;
        const lex_score: f32 = res.lexical;
        res.score = switch (options.mode) {
            .lexical => lex_score,
            .vector => vec_score,
            .hybrid => weight_vector * vec_score + weight_lexical * lex_score,
        };
    }

    // Sort by score descending
    std.mem.sortUnstable(Result, results.items, {}, struct {
        fn lessThan(_: void, a: Result, b: Result) bool {
            return a.score > b.score;
        }
    }.lessThan);

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
    const json = try vectorToJson(allocator, query_vec);
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

    var results = std.ArrayListUnmanaged(Result){};
    errdefer {
        for (results.items) |*res| res.deinit(allocator);
        results.deinit(allocator);
    }

    while (sqlite.sqlite3_step(s) == sqlite.SQLITE_ROW) {
        try results.append(allocator, .{
            .id = sqlite.sqlite3_column_int64(s, 0),
            .message = .{
                .id = sqlite.sqlite3_column_int64(s, 0),
                .file_path = try allocator.dupe(u8, columnText(s, 1)),
                .line_number = sqlite.sqlite3_column_int64(s, 2),
                .role = try allocator.dupe(u8, columnText(s, 3)),
                .content = try allocator.dupe(u8, columnText(s, 4)),
                .timestamp = if (columnTextOpt(s, 5)) |t| try allocator.dupe(u8, t) else null,
                .session_id = if (columnTextOpt(s, 6)) |t| try allocator.dupe(u8, t) else null,
                .project_name = if (columnTextOpt(s, 7)) |t| try allocator.dupe(u8, t) else null,
                .project_dir = if (columnTextOpt(s, 8)) |t| try allocator.dupe(u8, t) else null,
            },
            .score = 0,
            .distance = @floatCast(sqlite.sqlite3_column_double(s, 9)),
            .lexical = 0,
            .bm25 = 0,
        });
    }

    return results.toOwnedSlice(allocator);
}

fn lexicalCandidates(
    allocator: std.mem.Allocator,
    db: storage.Db,
    query: []const u8,
    limit: usize,
) ![]Result {
    // Try FTS5 first
    const fts_results = try ftsCandidates(allocator, db, query, limit);
    if (fts_results.len > 0) return fts_results;
    allocator.free(fts_results);

    // Fall back to LIKE
    return likeCandidates(allocator, db, query, limit);
}

fn ftsCandidates(
    allocator: std.mem.Allocator,
    db: storage.Db,
    query: []const u8,
    limit: usize,
) ![]Result {
    const sql =
        \\SELECT m.id, m.file_path, m.line_number, m.role, m.content,
        \\       m.timestamp, m.session_id, m.project_name, m.project_dir,
        \\       bm25(messages_fts, 1.0)
        \\FROM messages_fts AS fts
        \\JOIN messages AS m ON fts.rowid = m.id
        \\WHERE messages_fts MATCH ?1
        \\ORDER BY bm25(messages_fts, 1.0)
        \\LIMIT ?2
    ;

    var stmt: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != sqlite.SQLITE_OK) {
        return allocator.alloc(Result, 0);
    }
    defer _ = sqlite.sqlite3_finalize(stmt);
    const s = stmt.?;

    // Build FTS query: OR all tokens for broad matching
    const fts_query = try buildFtsQuery(allocator, query);
    defer allocator.free(fts_query);

    storage.bindTextPub(s, 1, fts_query);
    _ = sqlite.sqlite3_bind_int(s, 2, @intCast(limit));

    var results = std.ArrayListUnmanaged(Result){};
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
                .file_path = try allocator.dupe(u8, columnText(s, 1)),
                .line_number = sqlite.sqlite3_column_int64(s, 2),
                .role = try allocator.dupe(u8, columnText(s, 3)),
                .content = try allocator.dupe(u8, columnText(s, 4)),
                .timestamp = if (columnTextOpt(s, 5)) |t| try allocator.dupe(u8, t) else null,
                .session_id = if (columnTextOpt(s, 6)) |t| try allocator.dupe(u8, t) else null,
                .project_name = if (columnTextOpt(s, 7)) |t| try allocator.dupe(u8, t) else null,
                .project_dir = if (columnTextOpt(s, 8)) |t| try allocator.dupe(u8, t) else null,
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
) ![]Result {
    const like_pattern = try allocPrintZ(allocator, "%{s}%", .{query});
    defer allocator.free(like_pattern);

    const sql =
        \\SELECT id, file_path, line_number, role, content,
        \\       timestamp, session_id, project_name, project_dir
        \\FROM messages
        \\WHERE content LIKE ?1 COLLATE NOCASE
        \\LIMIT ?2
    ;

    var stmt: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != sqlite.SQLITE_OK) {
        return allocator.alloc(Result, 0);
    }
    defer _ = sqlite.sqlite3_finalize(stmt);
    const s = stmt.?;

    storage.bindTextPub(s, 1, like_pattern);
    _ = sqlite.sqlite3_bind_int(s, 2, @intCast(limit));

    var results = std.ArrayListUnmanaged(Result){};
    errdefer {
        for (results.items) |*res| res.deinit(allocator);
        results.deinit(allocator);
    }

    while (sqlite.sqlite3_step(s) == sqlite.SQLITE_ROW) {
        try results.append(allocator, .{
            .id = sqlite.sqlite3_column_int64(s, 0),
            .message = .{
                .id = sqlite.sqlite3_column_int64(s, 0),
                .file_path = try allocator.dupe(u8, columnText(s, 1)),
                .line_number = sqlite.sqlite3_column_int64(s, 2),
                .role = try allocator.dupe(u8, columnText(s, 3)),
                .content = try allocator.dupe(u8, columnText(s, 4)),
                .timestamp = if (columnTextOpt(s, 5)) |t| try allocator.dupe(u8, t) else null,
                .session_id = if (columnTextOpt(s, 6)) |t| try allocator.dupe(u8, t) else null,
                .project_name = if (columnTextOpt(s, 7)) |t| try allocator.dupe(u8, t) else null,
                .project_dir = if (columnTextOpt(s, 8)) |t| try allocator.dupe(u8, t) else null,
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
    var tokens = std.ArrayListUnmanaged([]const u8){};
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

    var out: std.io.Writer.Allocating = .init(allocator);
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

fn vectorToJson(allocator: std.mem.Allocator, vector: []const f32) ![:0]u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("[");
    for (vector, 0..) |v, i| {
        if (i > 0) try out.writer.writeAll(",");
        try out.writer.print("{d}", .{v});
    }
    try out.writer.writeAll("]");
    const slice = try out.toOwnedSlice();
    const result = try allocator.allocSentinel(u8, slice.len, 0);
    @memcpy(result, slice);
    allocator.free(slice);
    return result;
}

fn columnText(stmt: *sqlite.sqlite3_stmt, col: c_int) []const u8 {
    const ptr = sqlite.sqlite3_column_text(stmt, col);
    if (ptr == null) return "";
    const len = sqlite.sqlite3_column_bytes(stmt, col);
    return ptr[0..@intCast(len)];
}

fn columnTextOpt(stmt: *sqlite.sqlite3_stmt, col: c_int) ?[]const u8 {
    const ptr = sqlite.sqlite3_column_text(stmt, col);
    if (ptr == null) return null;
    const len = sqlite.sqlite3_column_bytes(stmt, col);
    if (len == 0) return null;
    return ptr[0..@intCast(len)];
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
