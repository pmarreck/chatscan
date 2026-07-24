const std = @import("std");
const runtime = @import("runtime.zig");

const c = @cImport({
    @cDefine("SQLITE_VEC_STATIC", "1");
    @cInclude("sqlite3.h");
    @cInclude("sqlite-vec.h");
});

pub const sqlite = c;
pub const Db = *c.sqlite3;
const current_schema_version = 1;

pub const Schema = struct {
    embedding_dim: usize,
    embedding_model: []const u8 = "",
};

pub const InitSchemaResult = struct {
    did_schema_upgrade: bool = false,
    embedding_model_mismatch: bool = false,
    embedding_dim_mismatch: bool = false,
    stored_embedding_model: ?[]u8 = null,
    stored_embedding_dim: ?usize = null,

    pub fn deinit(self: *InitSchemaResult, allocator: std.mem.Allocator) void {
        if (self.stored_embedding_model) |m| allocator.free(m);
        self.stored_embedding_model = null;
    }
};

pub const IndexedFile = struct {
    file_path: []const u8,
    mtime_ns: i64,
    last_line: i64,

    pub fn deinit(self: *IndexedFile, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
    }
};

pub const PendingEmbedding = struct {
    rowid: i64,
    content: []const u8,

    pub fn deinit(self: *PendingEmbedding, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

pub const Message = struct {
    id: i64 = 0,
    file_path: []const u8 = "",
    line_number: i64 = 0,
    role: []const u8 = "",
    content: []const u8 = "",
    timestamp: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    project_name: ?[]const u8 = null,
    project_dir: ?[]const u8 = null,

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        if (self.file_path.len > 0) allocator.free(self.file_path);
        if (self.role.len > 0) allocator.free(self.role);
        if (self.content.len > 0) allocator.free(self.content);
        if (self.timestamp) |t| allocator.free(t);
        if (self.session_id) |s| allocator.free(s);
        if (self.project_name) |p| allocator.free(p);
        if (self.project_dir) |p| allocator.free(p);
    }
};

pub fn openMemoryWithVec(allocator: std.mem.Allocator) !Db {
    _ = allocator;
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) {
        return error.OpenFailed;
    }
    const handle = db orelse return error.OpenFailed;
    errdefer _ = c.sqlite3_close(handle);
    try initVecStatic(handle);
    return handle;
}

pub fn openFileWithVec(allocator: std.mem.Allocator, path: []const u8) !Db {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(path_z, &db) != c.SQLITE_OK) {
        return error.OpenFailed;
    }
    const handle = db orelse return error.OpenFailed;
    errdefer _ = c.sqlite3_close(handle);

    try initVecStatic(handle);

    // WAL mode for concurrent access
    exec(handle, "PRAGMA journal_mode=WAL") catch {};
    exec(handle, "PRAGMA busy_timeout=5000") catch {};

    return handle;
}

pub fn close(db: Db) void {
    _ = c.sqlite3_close(db);
}

pub fn initSchema(allocator: std.mem.Allocator, db: Db, schema: Schema) !InitSchemaResult {
    const result = InitSchemaResult{};

    // Create base tables
    try exec(db,
        \\CREATE TABLE IF NOT EXISTS meta (
        \\    key TEXT PRIMARY KEY,
        \\    value TEXT NOT NULL
        \\)
    );

    try exec(db,
        \\CREATE TABLE IF NOT EXISTS indexed_files (
        \\    file_path TEXT PRIMARY KEY,
        \\    mtime_ns INTEGER NOT NULL,
        \\    last_line INTEGER NOT NULL DEFAULT 0
        \\)
    );

    try exec(db,
        \\CREATE TABLE IF NOT EXISTS messages (
        \\    id INTEGER PRIMARY KEY,
        \\    file_path TEXT NOT NULL,
        \\    line_number INTEGER NOT NULL,
        \\    role TEXT NOT NULL,
        \\    content TEXT NOT NULL,
        \\    timestamp TEXT,
        \\    session_id TEXT,
        \\    project_name TEXT,
        \\    project_dir TEXT,
        \\    UNIQUE(file_path, line_number)
        \\)
    );

    // FTS5 for full-text search
    const fts_ok = execMaybe(db,
        \\CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
        \\    content,
        \\    content='messages',
        \\    content_rowid='id'
        \\)
    );

    // sqlite-vec for embeddings
    const dim_str = try allocPrintZ(allocator, "{d}", .{schema.embedding_dim});
    defer allocator.free(dim_str);
    const vec_sql = try allocPrintZ(
        allocator,
        "CREATE VIRTUAL TABLE IF NOT EXISTS embeddings USING vec0(embedding float[{d}])",
        .{schema.embedding_dim},
    );
    defer allocator.free(vec_sql);
    execMaybe2(db, vec_sql);

    // Store metadata
    const version_str = try allocPrintZ(allocator, "{d}", .{current_schema_version});
    defer allocator.free(version_str);
    try upsertMeta(db, "schema_version", version_str);
    try upsertMeta(db, "fts_enabled", if (fts_ok) "1" else "0");
    if (schema.embedding_model.len > 0) {
        try upsertMeta(db, "embedding_model", schema.embedding_model);
    }
    try upsertMeta(db, "embedding_dim", dim_str);

    return result;
}

pub fn insertMessage(db: Db, msg: Message) !i64 {
    const sql =
        \\INSERT OR REPLACE INTO messages (file_path, line_number, role, content, timestamp, session_id, project_name, project_dir)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
    ;
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        logSqliteError(db, "prepare insertMessage");
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);
    const s = stmt.?;

    bindText(s, 1, msg.file_path);
    bindInt(s, 2, msg.line_number);
    bindText(s, 3, msg.role);
    bindText(s, 4, msg.content);
    if (msg.timestamp) |t| bindText(s, 5, t) else _ = c.sqlite3_bind_null(s, 5);
    if (msg.session_id) |sid| bindText(s, 6, sid) else _ = c.sqlite3_bind_null(s, 6);
    if (msg.project_name) |pn| bindText(s, 7, pn) else _ = c.sqlite3_bind_null(s, 7);
    if (msg.project_dir) |pd| bindText(s, 8, pd) else _ = c.sqlite3_bind_null(s, 8);

    if (c.sqlite3_step(s) != c.SQLITE_DONE) {
        logSqliteError(db, "step insertMessage");
        return error.InsertFailed;
    }

    const rowid = c.sqlite3_last_insert_rowid(db);

    // Insert into FTS
    insertMessageFts(db, rowid, msg.content);

    return rowid;
}

fn insertMessageFts(db: Db, rowid: i64, content: []const u8) void {
    const sql = "INSERT OR REPLACE INTO messages_fts(rowid, content) VALUES (?1, ?2)";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return;
    defer _ = c.sqlite3_finalize(stmt);
    const s = stmt.?;
    _ = c.sqlite3_bind_int64(s, 1, rowid);
    bindText(s, 2, content);
    _ = c.sqlite3_step(s);
}

pub fn insertEmbedding(db: Db, allocator: std.mem.Allocator, rowid: i64, vector: []const f32) !void {
    const json = try vectorToJson(allocator, vector);
    defer allocator.free(json);

    const sql = "INSERT OR REPLACE INTO embeddings(rowid, embedding) VALUES (?1, vec_f32(?2))";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        logSqliteError(db, "prepare insertEmbedding");
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);
    const s = stmt.?;

    _ = c.sqlite3_bind_int64(s, 1, rowid);
    bindText(s, 2, json);

    if (c.sqlite3_step(s) != c.SQLITE_DONE) {
        logSqliteError(db, "step insertEmbedding");
        return error.InsertFailed;
    }
}

pub fn upsertIndexedFile(db: Db, file_path: []const u8, mtime_ns: i64, last_line: i64) !void {
    const sql =
        \\INSERT INTO indexed_files (file_path, mtime_ns, last_line)
        \\VALUES (?1, ?2, ?3)
        \\ON CONFLICT(file_path) DO UPDATE SET mtime_ns=?2, last_line=?3
    ;
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        logSqliteError(db, "prepare upsertIndexedFile");
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);
    const s = stmt.?;

    bindText(s, 1, file_path);
    bindInt(s, 2, mtime_ns);
    bindInt(s, 3, last_line);

    if (c.sqlite3_step(s) != c.SQLITE_DONE) {
        logSqliteError(db, "step upsertIndexedFile");
        return error.InsertFailed;
    }
}

pub fn getIndexedFile(db: Db, allocator: std.mem.Allocator, file_path: []const u8) !?IndexedFile {
    const sql = "SELECT file_path, mtime_ns, last_line FROM indexed_files WHERE file_path = ?1";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return null;
    defer _ = c.sqlite3_finalize(stmt);
    const s = stmt.?;

    bindText(s, 1, file_path);

    if (c.sqlite3_step(s) != c.SQLITE_ROW) return null;

    return IndexedFile{
        .file_path = try allocator.dupe(u8, columnText(s, 0)),
        .mtime_ns = c.sqlite3_column_int64(s, 1),
        .last_line = c.sqlite3_column_int64(s, 2),
    };
}

pub fn getAllIndexedFiles(db: Db, allocator: std.mem.Allocator) ![]IndexedFile {
    const sql = "SELECT file_path, mtime_ns, last_line FROM indexed_files";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        return allocator.alloc(IndexedFile, 0);
    }
    defer _ = c.sqlite3_finalize(stmt);
    const s = stmt.?;

    var list = std.ArrayListUnmanaged(IndexedFile).empty;
    errdefer {
        for (list.items) |*item| item.deinit(allocator);
        list.deinit(allocator);
    }

    while (c.sqlite3_step(s) == c.SQLITE_ROW) {
        try list.append(allocator, .{
            .file_path = try allocator.dupe(u8, columnText(s, 0)),
            .mtime_ns = c.sqlite3_column_int64(s, 1),
            .last_line = c.sqlite3_column_int64(s, 2),
        });
    }

    return list.toOwnedSlice(allocator);
}

pub fn deleteIndexedFile(db: Db, file_path: []const u8) !void {
    const sql = "DELETE FROM indexed_files WHERE file_path = ?1";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt.?, 1, file_path);
    _ = c.sqlite3_step(stmt.?);
}

pub fn deleteMessagesByFile(db: Db, file_path: []const u8) !void {
    // Delete from FTS first (we need the rowids)
    {
        const sql = "DELETE FROM messages_fts WHERE rowid IN (SELECT id FROM messages WHERE file_path = ?1)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(stmt);
            bindText(stmt.?, 1, file_path);
            _ = c.sqlite3_step(stmt.?);
        }
    }
    // Delete embeddings
    {
        const sql = "DELETE FROM embeddings WHERE rowid IN (SELECT id FROM messages WHERE file_path = ?1)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(stmt);
            bindText(stmt.?, 1, file_path);
            _ = c.sqlite3_step(stmt.?);
        }
    }
    // Delete messages
    {
        const sql = "DELETE FROM messages WHERE file_path = ?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt.?, 1, file_path);
        _ = c.sqlite3_step(stmt.?);
    }
}

pub fn resetIndex(db: Db) !void {
    exec(db, "DELETE FROM messages") catch {};
    exec(db, "DELETE FROM messages_fts") catch {};
    exec(db, "DELETE FROM embeddings") catch {};
    exec(db, "DELETE FROM indexed_files") catch {};
}

pub fn isIndexPopulated(db: Db) bool {
    const sql = "SELECT COUNT(*) FROM indexed_files";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return false;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt.?) != c.SQLITE_ROW) return false;
    return c.sqlite3_column_int64(stmt.?, 0) > 0;
}

pub fn getMessageCount(db: Db) i64 {
    const sql = "SELECT COUNT(*) FROM messages";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return 0;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt.?) != c.SQLITE_ROW) return 0;
    return c.sqlite3_column_int64(stmt.?, 0);
}

/// Return the next ordered batch of lexical-only messages so semantic indexing
/// can repair interrupted or previously unavailable embedding runs in O(n).
pub fn getMessagesMissingEmbeddings(
    db: Db,
    allocator: std.mem.Allocator,
    after_rowid: i64,
    limit: usize,
) ![]PendingEmbedding {
    const sql =
        \\SELECT m.id, m.content
        \\FROM messages AS m
        \\WHERE m.id > ?1
        \\  AND NOT EXISTS (SELECT 1 FROM embeddings AS e WHERE e.rowid = m.id)
        \\ORDER BY m.id
        \\LIMIT ?2
    ;
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        logSqliteError(db, "prepare getMessagesMissingEmbeddings");
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);
    const s = stmt.?;
    bindInt(s, 1, after_rowid);
    bindInt(s, 2, @intCast(limit));

    var pending = std.ArrayListUnmanaged(PendingEmbedding).empty;
    errdefer {
        for (pending.items) |*item| item.deinit(allocator);
        pending.deinit(allocator);
    }
    while (true) {
        const step_result = c.sqlite3_step(s);
        if (step_result == c.SQLITE_DONE) break;
        if (step_result != c.SQLITE_ROW) {
            logSqliteError(db, "step getMessagesMissingEmbeddings");
            return error.QueryFailed;
        }
        const content = try allocator.dupe(u8, columnText(s, 1));
        errdefer allocator.free(content);
        try pending.append(allocator, .{
            .rowid = c.sqlite3_column_int64(s, 0),
            .content = content,
        });
    }
    return pending.toOwnedSlice(allocator);
}

/// Get the message at line N±offset in the same file, for sandwich context display.
pub fn getAdjacentMessage(db: Db, allocator: std.mem.Allocator, file_path: []const u8, line_number: i64, direction: enum { prev, next }) !?Message {
    const sql = switch (direction) {
        .prev =>
        \\SELECT id, file_path, line_number, role, content, timestamp, session_id, project_name, project_dir
        \\FROM messages WHERE file_path = ?1 AND line_number < ?2
        \\ORDER BY line_number DESC LIMIT 1
        ,
        .next =>
        \\SELECT id, file_path, line_number, role, content, timestamp, session_id, project_name, project_dir
        \\FROM messages WHERE file_path = ?1 AND line_number > ?2
        \\ORDER BY line_number ASC LIMIT 1
        ,
    };

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return null;
    defer _ = c.sqlite3_finalize(stmt);
    const s = stmt.?;

    bindText(s, 1, file_path);
    bindInt(s, 2, line_number);

    if (c.sqlite3_step(s) != c.SQLITE_ROW) return null;

    return Message{
        .id = c.sqlite3_column_int64(s, 0),
        .file_path = try allocator.dupe(u8, columnText(s, 1)),
        .line_number = c.sqlite3_column_int64(s, 2),
        .role = try allocator.dupe(u8, columnText(s, 3)),
        .content = try allocator.dupe(u8, columnText(s, 4)),
        .timestamp = if (columnTextOpt(s, 5)) |t| try allocator.dupe(u8, t) else null,
        .session_id = if (columnTextOpt(s, 6)) |t| try allocator.dupe(u8, t) else null,
        .project_name = if (columnTextOpt(s, 7)) |t| try allocator.dupe(u8, t) else null,
        .project_dir = if (columnTextOpt(s, 8)) |t| try allocator.dupe(u8, t) else null,
    };
}

// ── Internal helpers ─────────────────────────────────────────────────

fn initVecStatic(db: *c.sqlite3) !void {
    var err_msg: [*c]u8 = null;
    const rc = c.sqlite3_vec_init(db, &err_msg, null);
    if (rc != c.SQLITE_OK) {
        if (err_msg) |msg| {
            _ = c.sqlite3_free(msg);
        }
        return error.VecInitFailed;
    }
}

fn exec(db: *c.sqlite3, sql: [*:0]const u8) !void {
    if (c.sqlite3_exec(db, sql, null, null, null) != c.SQLITE_OK) {
        logSqliteError(db, "exec");
        return error.ExecFailed;
    }
}

fn execMaybe(db: *c.sqlite3, sql: [*:0]const u8) bool {
    return c.sqlite3_exec(db, sql, null, null, null) == c.SQLITE_OK;
}

fn execMaybe2(db: *c.sqlite3, sql: [:0]const u8) void {
    _ = c.sqlite3_exec(db, sql.ptr, null, null, null);
}

pub fn bindTextPub(stmt: *c.sqlite3_stmt, index: c_int, text: []const u8) void {
    bindText(stmt, index, text);
}

fn bindText(stmt: *c.sqlite3_stmt, index: c_int, text: []const u8) void {
    if (c.sqlite3_bind_text(stmt, index, text.ptr, @intCast(text.len), null) != c.SQLITE_OK) {}
}

fn bindInt(stmt: *c.sqlite3_stmt, index: c_int, value: i64) void {
    _ = c.sqlite3_bind_int64(stmt, index, value);
}

pub fn columnText(stmt: *c.sqlite3_stmt, col: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, col);
    if (ptr == null) return "";
    const len = c.sqlite3_column_bytes(stmt, col);
    return ptr[0..@intCast(len)];
}

pub fn columnTextOpt(stmt: *c.sqlite3_stmt, col: c_int) ?[]const u8 {
    const ptr = c.sqlite3_column_text(stmt, col);
    if (ptr == null) return null;
    const len = c.sqlite3_column_bytes(stmt, col);
    if (len == 0) return null;
    return ptr[0..@intCast(len)];
}

fn allocPrintZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    const tmp = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(tmp);
    return allocator.dupeZ(u8, tmp);
}

fn upsertMeta(db: Db, key: []const u8, value: []const u8) !void {
    const sql = "INSERT OR REPLACE INTO meta(key, value) VALUES (?1, ?2)";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt.?, 1, key);
    bindText(stmt.?, 2, value);
    _ = c.sqlite3_step(stmt.?);
}

pub fn vectorToJson(allocator: std.mem.Allocator, vector: []const f32) ![:0]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("[");
    for (vector, 0..) |v, i| {
        if (i > 0) try out.writer.writeAll(",");
        try out.writer.print("{d}", .{v});
    }
    try out.writer.writeAll("]");
    const slice = try out.toOwnedSlice();
    // Need null-terminated version
    const result = try allocator.allocSentinel(u8, slice.len, 0);
    @memcpy(result, slice);
    allocator.free(slice);
    return result;
}

fn logSqliteError(db: *c.sqlite3, context: []const u8) void {
    const msg = c.sqlite3_errmsg(db);
    if (msg != null) {
        const msg_slice = std.mem.span(msg);
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writer(runtime.io(), &buf);
        const stderr = &w.interface;
        _ = stderr.print("sqlite error ({s}): {s}\n", .{ context, msg_slice }) catch {};
        _ = stderr.flush() catch {};
    }
}

// ── Tests ────────────────────────────────────────────────────────────

/// Test helper: count rows in sqlite_master matching a given object name.
fn objectCount(db: Db, name: [:0]const u8) i64 {
    const sql = "SELECT COUNT(*) FROM sqlite_master WHERE name = ?";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return -1;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt.?, 1, name.ptr, -1, null);
    if (c.sqlite3_step(stmt.?) != c.SQLITE_ROW) return -1;
    return c.sqlite3_column_int64(stmt.?, 0);
}

test "open in-memory db and init schema" {
    const allocator = std.testing.allocator;
    const db = try openMemoryWithVec(allocator);
    defer close(db);

    var result = try initSchema(allocator, db, .{ .embedding_dim = 1024, .embedding_model = "bge-large" });
    defer result.deinit(allocator);

    // The schema must actually exist — not merely have returned without error.
    try std.testing.expectEqual(@as(i64, 1), objectCount(db, "messages"));
    try std.testing.expectEqual(@as(i64, 1), objectCount(db, "indexed_files"));
    try std.testing.expectEqual(@as(i64, 1), objectCount(db, "meta"));
    try std.testing.expectEqual(@as(i64, 1), objectCount(db, "messages_fts"));
    try std.testing.expectEqual(@as(i64, 1), objectCount(db, "embeddings"));

    // Metadata rows should be populated from the Schema args.
    const sql = "SELECT value FROM meta WHERE key = 'embedding_dim'";
    var stmt: ?*c.sqlite3_stmt = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db, sql, -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt.?));
    const dim_text = c.sqlite3_column_text(stmt.?, 0);
    try std.testing.expectEqualStrings("1024", std.mem.span(dim_text));
}

test "insert and retrieve message" {
    const allocator = std.testing.allocator;
    const db = try openMemoryWithVec(allocator);
    defer close(db);

    var result = try initSchema(allocator, db, .{ .embedding_dim = 1024 });
    defer result.deinit(allocator);

    const rowid = try insertMessage(db, .{
        .file_path = "test.jsonl",
        .line_number = 1,
        .role = "user",
        .content = "Hello world",
        .timestamp = "2026-03-06T12:00:00Z",
        .session_id = "abc-123",
        .project_name = "test-project",
        .project_dir = "-Users-test",
    });
    try std.testing.expect(rowid > 0);
    try std.testing.expectEqual(@as(i64, 1), getMessageCount(db));
}

test "missing embedding query classifies a mixed message set and paginates" {
    const allocator = std.testing.allocator;
    const db = try openMemoryWithVec(allocator);
    defer close(db);

    var result = try initSchema(allocator, db, .{ .embedding_dim = 2 });
    defer result.deinit(allocator);

    var rowids: [3]i64 = undefined;
    const contents = [_][]const u8{ "missing first", "already embedded", "missing last" };
    for (contents, 0..) |content, index| {
        rowids[index] = try insertMessage(db, .{
            .file_path = "mixed.jsonl",
            .line_number = @intCast(index + 1),
            .role = "user",
            .content = content,
        });
    }
    try insertEmbedding(db, allocator, rowids[1], &.{ 0.1, 0.2 });

    const first_page = try getMessagesMissingEmbeddings(db, allocator, 0, 1);
    defer {
        for (first_page) |*item| item.deinit(allocator);
        allocator.free(first_page);
    }
    try std.testing.expectEqual(@as(usize, 1), first_page.len);
    try std.testing.expectEqual(rowids[0], first_page[0].rowid);
    try std.testing.expectEqualStrings("missing first", first_page[0].content);

    const second_page = try getMessagesMissingEmbeddings(db, allocator, first_page[0].rowid, 10);
    defer {
        for (second_page) |*item| item.deinit(allocator);
        allocator.free(second_page);
    }
    try std.testing.expectEqual(@as(usize, 1), second_page.len);
    try std.testing.expectEqual(rowids[2], second_page[0].rowid);
    try std.testing.expectEqualStrings("missing last", second_page[0].content);
}

test "upsert and get indexed file" {
    const allocator = std.testing.allocator;
    const db = try openMemoryWithVec(allocator);
    defer close(db);

    var result = try initSchema(allocator, db, .{ .embedding_dim = 1024 });
    defer result.deinit(allocator);

    try upsertIndexedFile(db, "test.jsonl", 12345, 10);
    const info = try getIndexedFile(db, allocator, "test.jsonl");
    try std.testing.expect(info != null);
    var f = info.?;
    defer f.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 12345), f.mtime_ns);
    try std.testing.expectEqual(@as(i64, 10), f.last_line);
}

test "adjacent message retrieval" {
    const allocator = std.testing.allocator;
    const db = try openMemoryWithVec(allocator);
    defer close(db);

    var result = try initSchema(allocator, db, .{ .embedding_dim = 1024 });
    defer result.deinit(allocator);

    _ = try insertMessage(db, .{ .file_path = "t.jsonl", .line_number = 1, .role = "user", .content = "first" });
    _ = try insertMessage(db, .{ .file_path = "t.jsonl", .line_number = 5, .role = "assistant", .content = "second" });
    _ = try insertMessage(db, .{ .file_path = "t.jsonl", .line_number = 10, .role = "user", .content = "third" });

    var prev = (try getAdjacentMessage(db, allocator, "t.jsonl", 5, .prev)).?;
    defer prev.deinit(allocator);
    try std.testing.expectEqualStrings("first", prev.content);

    var next = (try getAdjacentMessage(db, allocator, "t.jsonl", 5, .next)).?;
    defer next.deinit(allocator);
    try std.testing.expectEqualStrings("third", next.content);
}
