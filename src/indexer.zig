const std = @import("std");
const storage = @import("storage.zig");
const conversation = @import("conversation.zig");
const embedding = @import("embedding.zig");
const config = @import("config.zig");
const runtime = @import("runtime.zig");

pub const IndexStats = struct {
    files_scanned: usize = 0,
    files_indexed: usize = 0,
    messages_indexed: usize = 0,
    files_deleted: usize = 0,
    embedding_failures: usize = 0,
};

pub fn indexAll(
    allocator: std.mem.Allocator,
    db: storage.Db,
    conversation_dir: []const u8,
    embedder: ?embedding.Embedder,
    batch_size: usize,
    force: bool,
    stderr: *std.Io.Writer,
) !IndexStats {
    return indexAllForLlm(allocator, db, conversation_dir, .claude, embedder, batch_size, force, stderr);
}

pub fn indexAllForLlm(
    allocator: std.mem.Allocator,
    db: storage.Db,
    conversation_dir: []const u8,
    llm: config.LlmSource,
    embedder: ?embedding.Embedder,
    batch_size: usize,
    force: bool,
    stderr: *std.Io.Writer,
) !IndexStats {
    var stats = IndexStats{};

    // Find all conversation files
    const files = try conversation.findConversationFilesForLlm(allocator, conversation_dir, llm);
    defer {
        for (files) |f| allocator.free(f);
        allocator.free(files);
    }

    stats.files_scanned = files.len;

    if (files.len == 0) {
        _ = stderr.print("No conversation files found in {s}\n", .{conversation_dir}) catch {};
        _ = stderr.flush() catch {};
        return stats;
    }

    _ = stderr.print("Scanning {d} {s} conversation files...\n", .{ files.len, @tagName(llm) }) catch {};
    _ = stderr.flush() catch {};

    // Get existing indexed files for incremental detection
    const indexed = try storage.getAllIndexedFiles(db, allocator);
    defer {
        for (indexed) |*item| {
            var m = item.*;
            m.deinit(allocator);
        }
        allocator.free(indexed);
    }

    // Build lookup set for indexed files
    var indexed_map = std.StringHashMap(storage.IndexedFile).init(allocator);
    defer indexed_map.deinit();
    for (indexed) |item| {
        try indexed_map.put(item.file_path, item);
    }

    // Track which files are still on disk (for deletion detection)
    var on_disk = std.StringHashMap(void).init(allocator);
    defer on_disk.deinit();

    // Embedding batch buffers
    var embed_texts = std.ArrayListUnmanaged([]const u8).empty;
    defer embed_texts.deinit(allocator);
    var embed_rowids = std.ArrayListUnmanaged(i64).empty;
    defer embed_rowids.deinit(allocator);

    for (files) |file_path| {
        try on_disk.put(file_path, {});

        // Get file mtime
        const file = std.Io.Dir.cwd().openFile(runtime.io(), file_path, .{}) catch continue;
        defer file.close(runtime.io());
        const stat = file.stat(runtime.io()) catch continue;
        const mtime: i64 = @intCast(@divFloor(stat.mtime.nanoseconds, std.time.ns_per_s));

        // Check if file needs indexing
        var start_line: i64 = 0;
        if (!force) {
            if (indexed_map.get(file_path)) |info| {
                if (info.mtime_ns == mtime) continue; // Unchanged
                start_line = info.last_line;
            }
        }

        // Read and parse the file
        const project_dir = conversation.extractProjectDir(file_path);

        const content = readFile(allocator, file_path) catch continue;
        defer allocator.free(content);

        var file_messages: usize = 0;
        var max_line: i64 = start_line;

        if (llm == .gemini) {
            // Gemini: JSON file with messages array
            const messages = conversation.parseGeminiFile(allocator, content, project_dir) catch continue;
            defer {
                for (messages) |*m| {
                    var msg = m.*;
                    msg.deinit(allocator);
                }
                allocator.free(messages);
            }

            for (messages) |msg| {
                const rowid = storage.insertMessage(db, .{
                    .file_path = file_path,
                    .line_number = msg.line_number,
                    .role = msg.role,
                    .content = msg.content,
                    .timestamp = msg.timestamp,
                    .session_id = msg.session_id,
                    .project_name = msg.project_name,
                    .project_dir = msg.project_dir,
                }) catch continue;

                if (embedder != null) {
                    const embed_text = if (msg.content.len > 1600)
                        try allocator.dupe(u8, msg.content[0..1600])
                    else
                        try allocator.dupe(u8, msg.content);
                    try embed_texts.append(allocator, embed_text);
                    try embed_rowids.append(allocator, rowid);

                    if (embed_texts.items.len >= batch_size) {
                        stats.embedding_failures += try flushEmbeddingBatch(allocator, db, embedder.?, &embed_texts, &embed_rowids);
                    }
                }

                file_messages += 1;
                max_line = @max(max_line, msg.line_number);
            }
        } else {
            // JSONL format (Claude or Codex)
            var line_number: i64 = 0;
            var line_iter = std.mem.splitScalar(u8, content, '\n');

            while (line_iter.next()) |line| {
                line_number += 1;
                if (line_number <= start_line) continue;
                if (line.len == 0) continue;

                var msg = (switch (llm) {
                    .claude => conversation.parseLine(allocator, line, line_number, project_dir),
                    .codex => conversation.parseCodexLine(allocator, line, line_number, project_dir),
                    else => unreachable,
                }) catch continue orelse continue;

                // Insert into storage
                const rowid = storage.insertMessage(db, .{
                    .file_path = file_path,
                    .line_number = msg.line_number,
                    .role = msg.role,
                    .content = msg.content,
                    .timestamp = msg.timestamp,
                    .session_id = msg.session_id,
                    .project_name = msg.project_name,
                    .project_dir = msg.project_dir,
                }) catch {
                    msg.deinit(allocator);
                    continue;
                };

                // Queue for embedding
                if (embedder != null) {
                    const embed_text = if (msg.content.len > 1600)
                        try allocator.dupe(u8, msg.content[0..1600])
                    else
                        try allocator.dupe(u8, msg.content);
                    try embed_texts.append(allocator, embed_text);
                    try embed_rowids.append(allocator, rowid);

                    if (embed_texts.items.len >= batch_size) {
                        stats.embedding_failures += try flushEmbeddingBatch(allocator, db, embedder.?, &embed_texts, &embed_rowids);
                    }
                }

                msg.deinit(allocator);
                file_messages += 1;
                max_line = @max(max_line, line_number);
            }
        }

        if (file_messages > 0) {
            try storage.upsertIndexedFile(db, file_path, mtime, max_line);
            stats.files_indexed += 1;
            stats.messages_indexed += file_messages;
        } else {
            // File scanned but no new messages — still update mtime
            try storage.upsertIndexedFile(db, file_path, mtime, max_line);
        }

        // Progress
        if (stats.files_indexed > 0 and stats.files_indexed % 50 == 0) {
            _ = stderr.print("  indexed {d} files, {d} messages...\n", .{ stats.files_indexed, stats.messages_indexed }) catch {};
            _ = stderr.flush() catch {};
        }
    }

    // Flush remaining embeddings
    if (embedder != null and embed_texts.items.len > 0) {
        stats.embedding_failures += try flushEmbeddingBatch(allocator, db, embedder.?, &embed_texts, &embed_rowids);
    }

    // Detect deleted files
    for (indexed) |item| {
        if (!on_disk.contains(item.file_path)) {
            storage.deleteMessagesByFile(db, item.file_path) catch |err| {
                _ = stderr.print("warning: could not remove stale messages for {s}: {s}\n", .{ item.file_path, @errorName(err) }) catch {};
                _ = stderr.flush() catch {};
                continue;
            };
            storage.deleteIndexedFile(db, item.file_path) catch |err| {
                _ = stderr.print("warning: could not remove stale index entry for {s}: {s}\n", .{ item.file_path, @errorName(err) }) catch {};
                _ = stderr.flush() catch {};
                continue;
            };
            stats.files_deleted += 1;
        }
    }

    _ = stderr.print("Done: {d} files indexed, {d} messages, {d} files removed\n", .{
        stats.files_indexed, stats.messages_indexed, stats.files_deleted,
    }) catch {};
    if (stats.embedding_failures > 0) {
        _ = stderr.print("Warning: {d} embeddings failed to index; semantic search may miss these messages (keyword search unaffected)\n", .{stats.embedding_failures}) catch {};
    }
    _ = stderr.flush() catch {};

    return stats;
}

fn flushEmbeddingBatch(
    allocator: std.mem.Allocator,
    db: storage.Db,
    embedder: embedding.Embedder,
    texts: *std.ArrayListUnmanaged([]const u8),
    rowids: *std.ArrayListUnmanaged(i64),
) !usize {
    if (texts.items.len == 0) return 0;

    // Number of inputs that ended up with no stored embedding (failed embed or insert).
    var failures: usize = 0;

    const embeddings = embedder.embed(embedder.ctx, allocator, texts.items) catch {
        // Batch failed (e.g. one input exceeds context length) — retry individually
        for (texts.items, 0..) |text, idx| {
            const single = [_][]const u8{text};
            const single_emb = embedder.embed(embedder.ctx, allocator, &single) catch {
                failures += 1; // Skip this input
                continue;
            };
            defer embedder.free(embedder.ctx, allocator, single_emb);
            if (single_emb.len > 0) {
                storage.insertEmbedding(db, allocator, rowids.items[idx], single_emb[0]) catch {
                    failures += 1;
                };
            } else {
                failures += 1;
            }
        }
        for (texts.items) |t| allocator.free(t);
        texts.clearRetainingCapacity();
        rowids.clearRetainingCapacity();
        return failures;
    };
    defer embedder.free(embedder.ctx, allocator, embeddings);

    for (embeddings, 0..) |vec, idx| {
        storage.insertEmbedding(db, allocator, rowids.items[idx], vec) catch {
            failures += 1;
        };
    }
    // If the provider returned fewer vectors than inputs, the tail rows got nothing.
    if (embeddings.len < rowids.items.len) failures += rowids.items.len - embeddings.len;

    for (texts.items) |t| allocator.free(t);
    texts.clearRetainingCapacity();
    rowids.clearRetainingCapacity();
    return failures;
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(runtime.io(), path, .{});
    defer file.close(runtime.io());
    const stat = try file.stat(runtime.io());
    if (stat.size > 100 * 1024 * 1024) return error.FileTooLarge; // 100MB cap
    return runtime.readToEndAlloc(file, allocator, 100 * 1024 * 1024);
}

test "indexAll with empty dir" {
    const allocator = std.testing.allocator;
    const db = try storage.openMemoryWithVec(allocator);
    defer storage.close(db);

    var result = try storage.initSchema(allocator, db, .{ .embedding_dim = 1024 });
    defer result.deinit(allocator);

    var buf: [256]u8 = undefined;
    var w = std.Io.File.stderr().writer(runtime.io(), &buf);

    const stats = try indexAll(allocator, db, "/tmp/nonexistent-chatscan-test-dir", null, 16, false, &w.interface);
    try std.testing.expectEqual(@as(usize, 0), stats.files_scanned);
}

// An embedder that always fails, to exercise the embedding-failure accounting path.
const AlwaysFailEmbedder = struct {
    fn embed(ctx: *anyopaque, allocator: std.mem.Allocator, inputs: []const []const u8) anyerror![][]f32 {
        _ = ctx;
        _ = allocator;
        _ = inputs;
        return error.EmbedUnavailable;
    }
    fn free(ctx: *anyopaque, allocator: std.mem.Allocator, embeddings: [][]f32) void {
        _ = ctx;
        _ = allocator;
        _ = embeddings;
    }
};

test "indexAll counts embedding failures without losing FTS indexing" {
    const allocator = std.testing.allocator;

    const tmpdir = runtime.getEnvVarOwned(allocator, "TMPDIR") catch try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmpdir);

    const conv_dir = try std.fmt.allocPrint(allocator, "{s}/chatscan-idx-embedfail", .{tmpdir});
    defer allocator.free(conv_dir);
    const proj_dir = try std.fmt.allocPrint(allocator, "{s}/-Users-test-proj", .{conv_dir});
    defer allocator.free(proj_dir);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/session.jsonl", .{proj_dir});
    defer allocator.free(file_path);

    std.Io.Dir.cwd().deleteTree(runtime.io(), conv_dir) catch {};
    std.Io.Dir.cwd().createDirPath(runtime.io(), proj_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(runtime.io(), conv_dir) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(runtime.io(), file_path, .{});
        defer f.close(runtime.io());
        try f.writeStreamingAll(runtime.io(),
            \\{"type":"user","timestamp":"2026-03-06T12:00:00Z","sessionId":"s1","cwd":"/tmp","message":{"role":"user","content":[{"type":"text","text":"hello world"}]}}
            \\{"type":"user","timestamp":"2026-03-06T12:00:01Z","sessionId":"s1","cwd":"/tmp","message":{"role":"user","content":[{"type":"text","text":"second message"}]}}
            \\
        );
    }

    const db = try storage.openMemoryWithVec(allocator);
    defer storage.close(db);
    var result = try storage.initSchema(allocator, db, .{ .embedding_dim = 1024 });
    defer result.deinit(allocator);

    var dummy: u8 = 0;
    const embedder = embedding.Embedder{
        .ctx = @ptrCast(&dummy),
        .embed = AlwaysFailEmbedder.embed,
        .free = AlwaysFailEmbedder.free,
    };

    var buf: [256]u8 = undefined;
    var w = std.Io.File.stderr().writer(runtime.io(), &buf);

    const stats = try indexAll(allocator, db, conv_dir, embedder, 16, false, &w.interface);
    // Both messages are still indexed for keyword search...
    try std.testing.expectEqual(@as(usize, 2), stats.messages_indexed);
    // ...but every embedding failed, and the user is told so via the counter.
    try std.testing.expectEqual(@as(usize, 2), stats.embedding_failures);
}


// An embedder that returns correctly-sized vectors, to exercise the success path.
const OkEmbedder = struct {
    fn embed(ctx: *anyopaque, allocator: std.mem.Allocator, inputs: []const []const u8) anyerror![][]f32 {
        _ = ctx;
        const out = try allocator.alloc([]f32, inputs.len);
        errdefer allocator.free(out);
        for (out) |*v| {
            v.* = try allocator.alloc(f32, 1024);
            @memset(v.*, 0);
            v.*[0] = 0.1;
        }
        return out;
    }
    fn free(ctx: *anyopaque, allocator: std.mem.Allocator, embeddings: [][]f32) void {
        _ = ctx;
        for (embeddings) |v| allocator.free(v);
        allocator.free(embeddings);
    }
};

test "indexAll indexes files across batch boundary and skips unchanged on reindex" {
    const allocator = std.testing.allocator;

    const tmpdir = runtime.getEnvVarOwned(allocator, "TMPDIR") catch try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmpdir);

    const conv_dir = try std.fmt.allocPrint(allocator, "{s}/chatscan-idx-success", .{tmpdir});
    defer allocator.free(conv_dir);
    const proj_dir = try std.fmt.allocPrint(allocator, "{s}/-Users-test-proj", .{conv_dir});
    defer allocator.free(proj_dir);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/session.jsonl", .{proj_dir});
    defer allocator.free(file_path);

    std.Io.Dir.cwd().deleteTree(runtime.io(), conv_dir) catch {};
    std.Io.Dir.cwd().createDirPath(runtime.io(), proj_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(runtime.io(), conv_dir) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(runtime.io(), file_path, .{});
        defer f.close(runtime.io());
        try f.writeStreamingAll(runtime.io(),
            \\{"type":"user","timestamp":"2026-03-06T12:00:00Z","sessionId":"s1","cwd":"/tmp","message":{"role":"user","content":[{"type":"text","text":"hello world"}]}}
            \\{"type":"user","timestamp":"2026-03-06T12:00:01Z","sessionId":"s1","cwd":"/tmp","message":{"role":"user","content":[{"type":"text","text":"second message"}]}}
            \\
        );
    }

    const db = try storage.openMemoryWithVec(allocator);
    defer storage.close(db);
    var result = try storage.initSchema(allocator, db, .{ .embedding_dim = 1024 });
    defer result.deinit(allocator);

    var dummy: u8 = 0;
    const embedder = embedding.Embedder{
        .ctx = @ptrCast(&dummy),
        .embed = OkEmbedder.embed,
        .free = OkEmbedder.free,
    };

    var buf: [256]u8 = undefined;
    var w = std.Io.File.stderr().writer(runtime.io(), &buf);

    // batch_size of 1 forces a flush after every message — exercises the flush boundary.
    const stats = try indexAll(allocator, db, conv_dir, embedder, 1, false, &w.interface);
    try std.testing.expectEqual(@as(usize, 1), stats.files_scanned);
    try std.testing.expectEqual(@as(usize, 1), stats.files_indexed);
    try std.testing.expectEqual(@as(usize, 2), stats.messages_indexed);
    try std.testing.expectEqual(@as(usize, 0), stats.embedding_failures);
    try std.testing.expectEqual(@as(i64, 2), storage.getMessageCount(db));

    // Reindex with the file unchanged: it should be scanned but not re-indexed.
    const stats2 = try indexAll(allocator, db, conv_dir, embedder, 1, false, &w.interface);
    try std.testing.expectEqual(@as(usize, 1), stats2.files_scanned);
    try std.testing.expectEqual(@as(usize, 0), stats2.files_indexed);
    try std.testing.expectEqual(@as(usize, 0), stats2.messages_indexed);
}
