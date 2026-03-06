const std = @import("std");

pub const ParsedMessage = struct {
    role: []const u8,
    content: []const u8,
    timestamp: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    project_name: ?[]const u8 = null,
    project_dir: ?[]const u8 = null,
    line_number: i64 = 0,

    pub fn deinit(self: *ParsedMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.role);
        allocator.free(self.content);
        if (self.timestamp) |t| allocator.free(t);
        if (self.session_id) |s| allocator.free(s);
        if (self.project_name) |p| allocator.free(p);
        if (self.project_dir) |p| allocator.free(p);
    }
};

/// Parse a single JSONL line and extract a message if it's a user or assistant type.
/// Returns null for non-message types (progress, system, queue-operation, file-history-snapshot).
pub fn parseLine(allocator: std.mem.Allocator, line: []const u8, line_number: i64, project_dir: []const u8) !?ParsedMessage {
    if (line.len == 0) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
        .allocate = .alloc_always,
    }) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    // Check type field
    const type_val = root.object.get("type") orelse return null;
    if (type_val != .string) return null;
    const msg_type = type_val.string;

    if (!std.mem.eql(u8, msg_type, "user") and !std.mem.eql(u8, msg_type, "assistant")) {
        return null;
    }

    // Extract text content from message.content
    const message_obj = root.object.get("message") orelse return null;
    if (message_obj != .object) return null;
    const msg = message_obj.object;

    // For assistant messages, check stop_reason to deduplicate streaming records.
    // Only index the final record (stop_reason != null).
    if (std.mem.eql(u8, msg_type, "assistant")) {
        const stop_reason = msg.get("stop_reason");
        if (stop_reason == null or stop_reason.? == .null) {
            // Streaming record (not final) — skip
            return null;
        }
    }

    const content_val = msg.get("content") orelse return null;
    const content_text = try extractTextContent(allocator, content_val);
    if (content_text.len == 0) {
        allocator.free(content_text);
        return null;
    }

    // Extract metadata
    const timestamp = if (root.object.get("timestamp")) |v| blk: {
        if (v == .string) break :blk try allocator.dupe(u8, v.string);
        break :blk null;
    } else null;

    const session_id = if (root.object.get("sessionId")) |v| blk: {
        if (v == .string) break :blk try allocator.dupe(u8, v.string);
        break :blk null;
    } else null;

    // Detect project name from cwd field
    const proj_name = if (root.object.get("cwd")) |v| blk: {
        if (v == .string) break :blk try detectProjectName(allocator, v.string);
        break :blk null;
    } else null;

    return ParsedMessage{
        .role = try allocator.dupe(u8, msg_type),
        .content = content_text,
        .timestamp = timestamp,
        .session_id = session_id,
        .project_name = proj_name,
        .project_dir = try allocator.dupe(u8, project_dir),
        .line_number = line_number,
    };
}

/// Extract human-readable text from message.content.
/// Handles both array format (main sessions) and string format (subagent prompts).
fn extractTextContent(allocator: std.mem.Allocator, content_val: std.json.Value) ![]u8 {
    switch (content_val) {
        .string => |s| return allocator.dupe(u8, s),
        .array => |arr| {
            var parts = std.ArrayListUnmanaged([]const u8){};
            defer parts.deinit(allocator);

            for (arr.items) |item| {
                if (item != .object) continue;
                const obj = item.object;
                const type_field = obj.get("type") orelse continue;
                if (type_field != .string) continue;

                if (std.mem.eql(u8, type_field.string, "text")) {
                    const text_field = obj.get("text") orelse continue;
                    if (text_field == .string and text_field.string.len > 0) {
                        try parts.append(allocator, text_field.string);
                    }
                }
                // Skip tool_use and tool_result blocks — not human-readable
            }

            if (parts.items.len == 0) return allocator.alloc(u8, 0);

            // Join with newlines
            var total: usize = 0;
            for (parts.items, 0..) |part, idx| {
                total += part.len;
                if (idx < parts.items.len - 1) total += 1;
            }

            var buf = try allocator.alloc(u8, total);
            var pos: usize = 0;
            for (parts.items, 0..) |part, idx| {
                @memcpy(buf[pos..][0..part.len], part);
                pos += part.len;
                if (idx < parts.items.len - 1) {
                    buf[pos] = '\n';
                    pos += 1;
                }
            }
            return buf;
        },
        else => return allocator.alloc(u8, 0),
    }
}

/// Detect project name from the cwd path by walking up to find .git or .jj.
/// Falls back to the last path component of cwd.
fn detectProjectName(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    // Walk up from cwd to find .git or .jj
    var path = cwd;
    while (path.len > 1) {
        // Check for .git
        const git_path = try std.fmt.allocPrint(allocator, "{s}/.git", .{path});
        defer allocator.free(git_path);
        if (pathExists(git_path)) {
            return allocator.dupe(u8, std.fs.path.basename(path));
        }

        // Check for .jj
        const jj_path = try std.fmt.allocPrint(allocator, "{s}/.jj", .{path});
        defer allocator.free(jj_path);
        if (pathExists(jj_path)) {
            return allocator.dupe(u8, std.fs.path.basename(path));
        }

        // Go up
        if (std.fs.path.dirname(path)) |parent| {
            path = parent;
        } else break;
    }

    // Fallback: last component of cwd
    return allocator.dupe(u8, std.fs.path.basename(cwd));
}

fn pathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

/// Extract the project directory name from a .jsonl file path.
/// Given "/home/user/.claude/projects/-Users-foo-bar/abc.jsonl",
/// returns "-Users-foo-bar".
pub fn extractProjectDir(file_path: []const u8) []const u8 {
    // The project dir is the parent directory name
    if (std.fs.path.dirname(file_path)) |dir| {
        return std.fs.path.basename(dir);
    }
    return "";
}

/// Find all .jsonl conversation files in the conversation directory.
pub fn findConversationFiles(allocator: std.mem.Allocator, conversation_dir: []const u8) ![][]u8 {
    var files = std.ArrayListUnmanaged([]u8){};
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    var dir = std.fs.openDirAbsolute(conversation_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return files.toOwnedSlice(allocator),
        else => return err,
    };
    defer dir.close();

    // Walk all project subdirectories
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        var sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
        defer sub_dir.close();

        var sub_iter = sub_dir.iterate();
        while (try sub_iter.next()) |sub_entry| {
            if (sub_entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, sub_entry.name, ".jsonl")) continue;

            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{
                conversation_dir, entry.name, sub_entry.name,
            });
            try files.append(allocator, full_path);
        }

        // Also check subagents/ subdirectories
        // Pattern: <uuid>/subagents/agent-<id>.jsonl
        var uuid_iter = sub_dir.iterate();
        while (try uuid_iter.next()) |uuid_entry| {
            if (uuid_entry.kind != .directory) continue;

            var uuid_dir = sub_dir.openDir(uuid_entry.name, .{}) catch continue;
            defer uuid_dir.close();

            var subagent_dir = uuid_dir.openDir("subagents", .{ .iterate = true }) catch continue;
            defer subagent_dir.close();

            var sa_iter = subagent_dir.iterate();
            while (try sa_iter.next()) |sa_entry| {
                if (sa_entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, sa_entry.name, ".jsonl")) continue;

                const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}/subagents/{s}", .{
                    conversation_dir, entry.name, uuid_entry.name, sa_entry.name,
                });
                try files.append(allocator, full_path);
            }
        }
    }

    return files.toOwnedSlice(allocator);
}

// ── Tests ────────────────────────────────────────────────────────────

test "extractProjectDir" {
    const result = extractProjectDir("/home/user/.claude/projects/-Users-foo-bar/abc.jsonl");
    try std.testing.expectEqualStrings("-Users-foo-bar", result);
}

test "extractTextContent from string" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "\"hello world\"", .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const text = try extractTextContent(allocator, parsed.value);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello world", text);
}

test "extractTextContent from array" {
    const allocator = std.testing.allocator;
    const json = "[{\"type\":\"text\",\"text\":\"hello\"},{\"type\":\"tool_use\",\"id\":\"x\"},{\"type\":\"text\",\"text\":\"world\"}]";
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const text = try extractTextContent(allocator, parsed.value);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello\nworld", text);
}

test "parseLine user message" {
    const allocator = std.testing.allocator;
    const line =
        \\{"type":"user","timestamp":"2026-03-06T12:00:00Z","sessionId":"abc","cwd":"/tmp","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}
    ;
    var msg = (try parseLine(allocator, line, 1, "-tmp")).?;
    defer msg.deinit(allocator);
    try std.testing.expectEqualStrings("user", msg.role);
    try std.testing.expectEqualStrings("hello", msg.content);
}

test "parseLine skips progress" {
    const allocator = std.testing.allocator;
    const line =
        \\{"type":"progress","data":{"type":"bash_progress"}}
    ;
    const msg = try parseLine(allocator, line, 1, "-tmp");
    try std.testing.expect(msg == null);
}

test "parseLine skips streaming assistant" {
    const allocator = std.testing.allocator;
    const line =
        \\{"type":"assistant","message":{"role":"assistant","stop_reason":null,"content":[{"type":"text","text":"partial"}]}}
    ;
    const msg = try parseLine(allocator, line, 1, "-tmp");
    try std.testing.expect(msg == null);
}

test "parseLine accepts final assistant" {
    const allocator = std.testing.allocator;
    const line =
        \\{"type":"assistant","timestamp":"2026-03-06T12:00:00Z","sessionId":"abc","cwd":"/tmp","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}
    ;
    var msg = (try parseLine(allocator, line, 1, "-tmp")).?;
    defer msg.deinit(allocator);
    try std.testing.expectEqualStrings("assistant", msg.role);
    try std.testing.expectEqualStrings("done", msg.content);
}
