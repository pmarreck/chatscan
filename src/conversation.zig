const std = @import("std");
const config = @import("config.zig");
const runtime = @import("runtime.zig");

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
            var parts = std.ArrayListUnmanaged([]const u8).empty;
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

/// Extract text from Gemini content arrays: [{text: "..."}, ...]
fn extractGeminiTextContent(allocator: std.mem.Allocator, content_val: std.json.Value) ![]u8 {
    if (content_val != .array) return allocator.alloc(u8, 0);

    var parts = std.ArrayListUnmanaged([]const u8).empty;
    defer parts.deinit(allocator);

    for (content_val.array.items) |item_val| {
        if (item_val != .object) continue;
        const text_field = item_val.object.get("text") orelse continue;
        if (text_field == .string and text_field.string.len > 0) {
            try parts.append(allocator, text_field.string);
        }
    }

    if (parts.items.len == 0) return allocator.alloc(u8, 0);

    var total: usize = 0;
    for (parts.items, 0..) |part, i| {
        total += part.len;
        if (i < parts.items.len - 1) total += 1;
    }
    var buf = try allocator.alloc(u8, total);
    var pos: usize = 0;
    for (parts.items, 0..) |part, i| {
        @memcpy(buf[pos..][0..part.len], part);
        pos += part.len;
        if (i < parts.items.len - 1) {
            buf[pos] = '\n';
            pos += 1;
        }
    }
    return buf;
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
    std.Io.Dir.cwd().access(runtime.io(), path, .{}) catch return false;
    return true;
}

/// Parse a Codex JSONL line. Codex wraps messages in event_msg payloads.
pub fn parseCodexLine(allocator: std.mem.Allocator, line: []const u8, line_number: i64, project_dir: []const u8) !?ParsedMessage {
    if (line.len == 0) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
        .allocate = .alloc_always,
    }) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    // Codex has two formats:
    // 1. {type: "event_msg", payload: {type: "user_message"|"agent_message", message: "..."}}
    // 2. {type: "session_meta", payload: {cwd: "..."}}
    const type_val = root.object.get("type") orelse return null;
    if (type_val != .string) return null;
    if (!std.mem.eql(u8, type_val.string, "event_msg")) return null;

    const payload = root.object.get("payload") orelse return null;
    if (payload != .object) return null;
    const payload_type = payload.object.get("type") orelse return null;
    if (payload_type != .string) return null;

    var role: []const u8 = undefined;
    if (std.mem.eql(u8, payload_type.string, "user_message")) {
        role = "user";
    } else if (std.mem.eql(u8, payload_type.string, "agent_message")) {
        role = "assistant";
    } else return null;

    const msg_val = payload.object.get("message") orelse return null;
    if (msg_val != .string or msg_val.string.len == 0) return null;

    const timestamp = if (root.object.get("timestamp")) |v| blk: {
        if (v == .string) break :blk try allocator.dupe(u8, v.string);
        break :blk null;
    } else null;
    errdefer if (timestamp) |t| allocator.free(t);

    return ParsedMessage{
        .role = try allocator.dupe(u8, role),
        .content = try allocator.dupe(u8, msg_val.string),
        .timestamp = timestamp,
        .session_id = null,
        .project_name = null,
        .project_dir = try allocator.dupe(u8, project_dir),
        .line_number = line_number,
    };
}

/// Parse Gemini messages from a JSON session file.
/// Returns all user/gemini messages from the file.
pub fn parseGeminiFile(allocator: std.mem.Allocator, content: []const u8, project_dir: []const u8) ![]ParsedMessage {
    var messages = std.ArrayListUnmanaged(ParsedMessage).empty;
    errdefer {
        for (messages.items) |*m| m.deinit(allocator);
        messages.deinit(allocator);
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{
        .allocate = .alloc_always,
    }) catch return messages.toOwnedSlice(allocator);
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return messages.toOwnedSlice(allocator);

    const msgs_val = root.object.get("messages") orelse return messages.toOwnedSlice(allocator);
    if (msgs_val != .array) return messages.toOwnedSlice(allocator);

    for (msgs_val.array.items, 0..) |item, idx| {
        if (item != .object) continue;
        const msg_type = item.object.get("type") orelse continue;
        if (msg_type != .string) continue;

        var role: []const u8 = undefined;
        if (std.mem.eql(u8, msg_type.string, "user")) {
            role = "user";
        } else if (std.mem.eql(u8, msg_type.string, "gemini")) {
            role = "assistant";
        } else continue;

        // Extract content
        var text: []u8 = undefined;
        if (item.object.get("content")) |content_val| {
            if (content_val == .string) {
                if (content_val.string.len == 0) continue;
                text = try allocator.dupe(u8, content_val.string);
            } else if (content_val == .array) {
                // Gemini uses [{text: "..."}] without a type field
                text = try extractGeminiTextContent(allocator, content_val);
                if (text.len == 0) {
                    allocator.free(text);
                    continue;
                }
            } else continue;
        } else continue;

        const timestamp = if (item.object.get("timestamp")) |v| blk: {
            if (v == .string) break :blk try allocator.dupe(u8, v.string);
            break :blk null;
        } else null;

        try messages.append(allocator, .{
            .role = try allocator.dupe(u8, role),
            .content = text,
            .timestamp = timestamp,
            .session_id = null,
            .project_name = null,
            .project_dir = try allocator.dupe(u8, project_dir),
            .line_number = @intCast(idx + 1),
        });
    }

    return messages.toOwnedSlice(allocator);
}

/// Find conversation files for a given LLM source.
pub fn findConversationFilesForLlm(allocator: std.mem.Allocator, conversation_dir: []const u8, llm: config.LlmSource) ![][]u8 {
    return switch (llm) {
        .claude => findConversationFiles(allocator, conversation_dir),
        .codex => findCodexFiles(allocator, conversation_dir),
        .gemini => findGeminiFiles(allocator, conversation_dir),
        .all => unreachable, // caller handles .all by iterating sources
    };
}

/// Find Codex session files: ~/.codex/sessions/YYYY/MM/DD/*.jsonl
fn findCodexFiles(allocator: std.mem.Allocator, sessions_dir: []const u8) ![][]u8 {
    var files = std.ArrayListUnmanaged([]u8).empty;
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    var year_dir = std.Io.Dir.cwd().openDir(runtime.io(), sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return files.toOwnedSlice(allocator),
        else => return err,
    };
    defer year_dir.close(runtime.io());

    var year_iter = year_dir.iterate();
    while (try year_iter.next(runtime.io())) |year_entry| {
        if (year_entry.kind != .directory) continue;
        var month_dir = year_dir.openDir(runtime.io(), year_entry.name, .{ .iterate = true }) catch continue;
        defer month_dir.close(runtime.io());

        var month_iter = month_dir.iterate();
        while (try month_iter.next(runtime.io())) |month_entry| {
            if (month_entry.kind != .directory) continue;
            var day_dir = month_dir.openDir(runtime.io(), month_entry.name, .{ .iterate = true }) catch continue;
            defer day_dir.close(runtime.io());

            var day_iter = day_dir.iterate();
            while (try day_iter.next(runtime.io())) |day_entry| {
                if (day_entry.kind != .directory) continue;

                var file_dir = day_dir.openDir(runtime.io(), day_entry.name, .{ .iterate = true }) catch continue;
                defer file_dir.close(runtime.io());

                var file_iter = file_dir.iterate();
                while (try file_iter.next(runtime.io())) |file_entry| {
                    if (file_entry.kind != .file) continue;
                    if (!std.mem.endsWith(u8, file_entry.name, ".jsonl")) continue;

                    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}/{s}/{s}", .{
                        sessions_dir, year_entry.name, month_entry.name, day_entry.name, file_entry.name,
                    });
                    try files.append(allocator, full_path);
                }
            }
        }
    }

    return files.toOwnedSlice(allocator);
}

/// Find Gemini chat files: ~/.gemini/tmp/*/chats/session-*.json
fn findGeminiFiles(allocator: std.mem.Allocator, gemini_dir: []const u8) ![][]u8 {
    var files = std.ArrayListUnmanaged([]u8).empty;
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    var top_dir = std.Io.Dir.cwd().openDir(runtime.io(), gemini_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return files.toOwnedSlice(allocator),
        else => return err,
    };
    defer top_dir.close(runtime.io());

    var top_iter = top_dir.iterate();
    while (try top_iter.next(runtime.io())) |entry| {
        if (entry.kind != .directory) continue;

        // Look for chats/ subdirectory
        const chats_path = std.fmt.allocPrint(allocator, "{s}/{s}/chats", .{ gemini_dir, entry.name }) catch continue;
        defer allocator.free(chats_path);

        var chats_dir = std.Io.Dir.cwd().openDir(runtime.io(), chats_path, .{ .iterate = true }) catch continue;
        defer chats_dir.close(runtime.io());

        var chat_iter = chats_dir.iterate();
        while (try chat_iter.next(runtime.io())) |chat_entry| {
            if (chat_entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, chat_entry.name, ".json")) continue;

            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{
                chats_path, chat_entry.name,
            });
            try files.append(allocator, full_path);
        }
    }

    return files.toOwnedSlice(allocator);
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
    var files = std.ArrayListUnmanaged([]u8).empty;
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    var dir = std.Io.Dir.cwd().openDir(runtime.io(), conversation_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return files.toOwnedSlice(allocator),
        else => return err,
    };
    defer dir.close(runtime.io());

    // Walk all project subdirectories
    var iter = dir.iterate();
    while (try iter.next(runtime.io())) |entry| {
        if (entry.kind != .directory) continue;

        var sub_dir = dir.openDir(runtime.io(), entry.name, .{ .iterate = true }) catch continue;
        defer sub_dir.close(runtime.io());

        var sub_iter = sub_dir.iterate();
        while (try sub_iter.next(runtime.io())) |sub_entry| {
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
        while (try uuid_iter.next(runtime.io())) |uuid_entry| {
            if (uuid_entry.kind != .directory) continue;

            var uuid_dir = sub_dir.openDir(runtime.io(), uuid_entry.name, .{}) catch continue;
            defer uuid_dir.close(runtime.io());

            var subagent_dir = uuid_dir.openDir(runtime.io(), "subagents", .{ .iterate = true }) catch continue;
            defer subagent_dir.close(runtime.io());

            var sa_iter = subagent_dir.iterate();
            while (try sa_iter.next(runtime.io())) |sa_entry| {
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

test "parseCodexLine user message" {
    const allocator = std.testing.allocator;
    const line =
        \\{"timestamp":"2026-03-06T23:05:09.185Z","type":"event_msg","payload":{"type":"user_message","message":"please read AGENTS.md","images":[]}}
    ;
    var msg = (try parseCodexLine(allocator, line, 1, "-codex")).?;
    defer msg.deinit(allocator);
    try std.testing.expectEqualStrings("user", msg.role);
    try std.testing.expectEqualStrings("please read AGENTS.md", msg.content);
    try std.testing.expectEqualStrings("2026-03-06T23:05:09.185Z", msg.timestamp.?);
}

test "parseCodexLine agent message" {
    const allocator = std.testing.allocator;
    const line =
        \\{"timestamp":"2026-03-06T23:05:14.241Z","type":"event_msg","payload":{"type":"agent_message","message":"I'll load those files now.","phase":"commentary"}}
    ;
    var msg = (try parseCodexLine(allocator, line, 2, "-codex")).?;
    defer msg.deinit(allocator);
    try std.testing.expectEqualStrings("assistant", msg.role);
    try std.testing.expectEqualStrings("I'll load those files now.", msg.content);
}

test "parseCodexLine skips non-message types" {
    const allocator = std.testing.allocator;
    const line =
        \\{"timestamp":"2026-03-06T23:05:09.185Z","type":"event_msg","payload":{"type":"function_call","name":"read_file"}}
    ;
    const msg = try parseCodexLine(allocator, line, 1, "-codex");
    try std.testing.expect(msg == null);
}

test "parseCodexLine skips session_meta" {
    const allocator = std.testing.allocator;
    const line =
        \\{"timestamp":"2026-03-06T23:05:09.184Z","type":"session_meta","payload":{"id":"abc","cwd":"/tmp"}}
    ;
    const msg = try parseCodexLine(allocator, line, 1, "-codex");
    try std.testing.expect(msg == null);
}

test "parseGeminiFile basic" {
    const allocator = std.testing.allocator;
    const json =
        \\{"sessionId":"abc","messages":[
        \\  {"id":"1","timestamp":"2026-02-21T22:38:46.224Z","type":"user","content":[{"text":"Hello from Gemini"}]},
        \\  {"id":"2","timestamp":"2026-02-21T22:38:50.000Z","type":"gemini","content":"I will help you."},
        \\  {"id":"3","timestamp":"2026-02-21T22:39:00.000Z","type":"info","content":"some info"}
        \\]}
    ;
    const messages = try parseGeminiFile(allocator, json, "-gemini");
    defer {
        for (messages) |*m| {
            var msg = m.*;
            msg.deinit(allocator);
        }
        allocator.free(messages);
    }
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("user", messages[0].role);
    try std.testing.expectEqualStrings("Hello from Gemini", messages[0].content);
    try std.testing.expectEqualStrings("assistant", messages[1].role);
    try std.testing.expectEqualStrings("I will help you.", messages[1].content);
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
