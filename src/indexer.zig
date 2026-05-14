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
                        try flushEmbeddingBatch(allocator, db, embedder.?, &embed_texts, &embed_rowids);
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
                        try flushEmbeddingBatch(allocator, db, embedder.?, &embed_texts, &embed_rowids);
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
        try flushEmbeddingBatch(allocator, db, embedder.?, &embed_texts, &embed_rowids);
    }

    // Detect deleted files
    for (indexed) |item| {
        if (!on_disk.contains(item.file_path)) {
            storage.deleteMessagesByFile(db, item.file_path) catch {};
            storage.deleteIndexedFile(db, item.file_path) catch {};
            stats.files_deleted += 1;
        }
    }

    _ = stderr.print("Done: {d} files indexed, {d} messages, {d} files removed\n", .{
        stats.files_indexed, stats.messages_indexed, stats.files_deleted,
    }) catch {};
    _ = stderr.flush() catch {};

    return stats;
}

fn flushEmbeddingBatch(
    allocator: std.mem.Allocator,
    db: storage.Db,
    embedder: embedding.Embedder,
    texts: *std.ArrayListUnmanaged([]const u8),
    rowids: *std.ArrayListUnmanaged(i64),
) !void {
    if (texts.items.len == 0) return;

    const embeddings = embedder.embed(embedder.ctx, allocator, texts.items) catch {
        // Batch failed (e.g. one input exceeds context length) — retry individually
        for (texts.items, 0..) |text, idx| {
            const single = [_][]const u8{text};
            const single_emb = embedder.embed(embedder.ctx, allocator, &single) catch {
                continue; // Skip this input
            };
            defer embedder.free(embedder.ctx, allocator, single_emb);
            if (single_emb.len > 0) {
                storage.insertEmbedding(db, allocator, rowids.items[idx], single_emb[0]) catch {};
            }
        }
        for (texts.items) |t| allocator.free(t);
        texts.clearRetainingCapacity();
        rowids.clearRetainingCapacity();
        return;
    };
    defer embedder.free(embedder.ctx, allocator, embeddings);

    for (embeddings, 0..) |vec, idx| {
        storage.insertEmbedding(db, allocator, rowids.items[idx], vec) catch {};
    }

    for (texts.items) |t| allocator.free(t);
    texts.clearRetainingCapacity();
    rowids.clearRetainingCapacity();
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
