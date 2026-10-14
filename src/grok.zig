const std = @import("std");
const conversation = @import("conversation.zig");
const runtime = @import("runtime.zig");

pub const Session = struct {
    id: []u8,
    cwd: []u8,
    summary_path: []u8,
    updates_path: []u8,

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.cwd);
        allocator.free(self.summary_path);
        allocator.free(self.updates_path);
    }
};

pub const DuplicateSession = struct {
    id: []const u8,
    first_summary_path: []const u8,
    second_summary_path: []const u8,
};

pub fn findSessions(allocator: std.mem.Allocator, sessions_root: []const u8) ![]Session {
    var sessions = std.ArrayListUnmanaged(Session).empty;
    errdefer {
        for (sessions.items) |*session| session.deinit(allocator);
        sessions.deinit(allocator);
    }

    var root = std.Io.Dir.cwd().openDir(runtime.io(), sessions_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return sessions.toOwnedSlice(allocator),
        else => return err,
    };
    defer root.close(runtime.io());

    var group_iterator = root.iterate();
    while (try group_iterator.next(runtime.io())) |group_entry| {
        if (group_entry.kind != .directory) continue;
        var group = root.openDir(runtime.io(), group_entry.name, .{ .iterate = true }) catch continue;
        defer group.close(runtime.io());

        var session_iterator = group.iterate();
        while (try session_iterator.next(runtime.io())) |session_entry| {
            if (session_entry.kind != .directory) continue;
            const summary_path = try std.fmt.allocPrint(
                allocator,
                "{s}/{s}/{s}/summary.json",
                .{ sessions_root, group_entry.name, session_entry.name },
            );
            defer allocator.free(summary_path);

            const summary = readSmallFile(allocator, summary_path) catch continue;
            defer allocator.free(summary);
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, summary, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const info = parsed.value.object.get("info") orelse continue;
            if (info != .object) continue;
            const id = info.object.get("id") orelse continue;
            const cwd = info.object.get("cwd") orelse continue;
            if (id != .string or id.string.len == 0 or cwd != .string or cwd.string.len == 0) continue;

            var session = Session{
                .id = try allocator.dupe(u8, id.string),
                .cwd = undefined,
                .summary_path = undefined,
                .updates_path = undefined,
            };
            errdefer allocator.free(session.id);
            session.cwd = try allocator.dupe(u8, cwd.string);
            errdefer allocator.free(session.cwd);
            session.summary_path = try allocator.dupe(u8, summary_path);
            errdefer allocator.free(session.summary_path);
            session.updates_path = try std.fmt.allocPrint(
                allocator,
                "{s}/{s}/{s}/updates.jsonl",
                .{ sessions_root, group_entry.name, session_entry.name },
            );
            errdefer allocator.free(session.updates_path);
            try sessions.append(allocator, session);
        }
    }

    std.mem.sortUnstable(Session, sessions.items, {}, struct {
        fn lessThan(_: void, left: Session, right: Session) bool {
            const id_order = std.mem.order(u8, left.id, right.id);
            if (id_order != .eq) return id_order == .lt;
            return std.mem.lessThan(u8, left.summary_path, right.summary_path);
        }
    }.lessThan);
    return sessions.toOwnedSlice(allocator);
}

pub fn findDuplicateSession(sessions: []const Session) ?DuplicateSession {
    if (sessions.len < 2) return null;
    for (sessions[0 .. sessions.len - 1], sessions[1..]) |first, second| {
        if (std.mem.eql(u8, first.id, second.id)) {
            return .{
                .id = first.id,
                .first_summary_path = first.summary_path,
                .second_summary_path = second.summary_path,
            };
        }
    }
    return null;
}

fn readSmallFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(runtime.io(), path, .{});
    defer file.close(runtime.io());
    const stat = try file.stat(runtime.io());
    if (stat.size > 1024 * 1024) return error.FileTooLarge;
    return runtime.readToEndAlloc(file, allocator, 1024 * 1024);
}

const MessageBuilder = struct {
    role: ?[]const u8 = null,
    content: std.ArrayListUnmanaged(u8) = .empty,
    timestamp: ?[]u8 = null,
    line_number: i64 = 0,

    fn deinit(self: *MessageBuilder, allocator: std.mem.Allocator) void {
        self.content.deinit(allocator);
        if (self.timestamp) |timestamp| allocator.free(timestamp);
    }
};

pub fn parseUpdates(
    allocator: std.mem.Allocator,
    content: []const u8,
    session_id: []const u8,
    project_dir: []const u8,
) ![]conversation.ParsedMessage {
    var messages = std.ArrayListUnmanaged(conversation.ParsedMessage).empty;
    errdefer {
        for (messages.items) |*message| message.deinit(allocator);
        messages.deinit(allocator);
    }

    var current = MessageBuilder{};
    defer current.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_number: i64 = 0;
    while (lines.next()) |line| {
        line_number += 1;
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const root = parsed.value.object;

        const method = root.get("method") orelse continue;
        if (method != .string or !std.mem.eql(u8, method.string, "session/update")) continue;
        const params = root.get("params") orelse continue;
        if (params != .object) continue;
        const update_value = params.object.get("update") orelse continue;
        if (update_value != .object) continue;
        const update = update_value.object;

        if (update.get("_meta")) |meta| {
            if (meta == .object) {
                if (meta.object.get("hideFromScrollback")) |hidden| {
                    if (hidden == .bool and hidden.bool) continue;
                }
            }
        }

        const kind = update.get("sessionUpdate") orelse continue;
        if (kind != .string) continue;
        const role: []const u8 = if (std.mem.eql(u8, kind.string, "user_message_chunk"))
            "user"
        else if (std.mem.eql(u8, kind.string, "agent_message_chunk"))
            "assistant"
        else
            continue;

        const chunk = update.get("content") orelse continue;
        if (chunk != .object) continue;
        const chunk_type = chunk.object.get("type") orelse continue;
        if (chunk_type != .string or !std.mem.eql(u8, chunk_type.string, "text")) continue;
        const text = chunk.object.get("text") orelse continue;
        if (text != .string or text.string.len == 0) continue;

        if (current.role) |current_role| {
            if (!std.mem.eql(u8, current_role, role)) {
                try flushMessage(allocator, &messages, &current, session_id, project_dir);
            }
        }
        if (current.role == null) {
            current.role = role;
            current.line_number = line_number;
            if (root.get("timestamp")) |timestamp| {
                if (timestamp == .string) current.timestamp = try allocator.dupe(u8, timestamp.string);
            }
        }
        try current.content.appendSlice(allocator, text.string);
    }

    try flushMessage(allocator, &messages, &current, session_id, project_dir);
    return messages.toOwnedSlice(allocator);
}

pub fn lastCompleteRecordLine(allocator: std.mem.Allocator, content: []const u8) i64 {
    var last_complete: i64 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_number: i64 = 0;
    while (lines.next()) |line| {
        line_number += 1;
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        parsed.deinit();
        last_complete = line_number;
    }
    return last_complete;
}

fn flushMessage(
    allocator: std.mem.Allocator,
    messages: *std.ArrayListUnmanaged(conversation.ParsedMessage),
    current: *MessageBuilder,
    session_id: []const u8,
    project_dir: []const u8,
) !void {
    const role = current.role orelse return;
    if (current.content.items.len == 0) return;

    const owned_role = try allocator.dupe(u8, role);
    errdefer allocator.free(owned_role);
    const owned_content = try current.content.toOwnedSlice(allocator);
    errdefer allocator.free(owned_content);
    const owned_session_id = try allocator.dupe(u8, session_id);
    errdefer allocator.free(owned_session_id);
    const project_name = try allocator.dupe(u8, std.fs.path.basename(project_dir));
    errdefer allocator.free(project_name);
    const owned_project_dir = try allocator.dupe(u8, project_dir);
    errdefer allocator.free(owned_project_dir);

    try messages.append(allocator, .{
        .role = owned_role,
        .content = owned_content,
        .timestamp = current.timestamp,
        .session_id = owned_session_id,
        .project_name = project_name,
        .project_dir = owned_project_dir,
        .line_number = current.line_number,
    });
    current.role = null;
    current.timestamp = null;
    current.line_number = 0;
}

fn deinitMessages(allocator: std.mem.Allocator, messages: []conversation.ParsedMessage) void {
    for (messages) |*message| message.deinit(allocator);
    allocator.free(messages);
}

test "ACP update classifier reconstructs only visible user and agent messages" {
    const allocator = std.testing.allocator;
    const updates =
        \\{"method":"session/update","timestamp":"2026-09-02T12:00:00Z","params":{"update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Plan "}}}}
        \\{"method":"_x.ai/session/update","params":{"update":{"sessionUpdate":"hook_execution","content":{"type":"text","text":"hook noise"}}}}
        \\{"method":"session/update","params":{"update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"carefully"}}}}
        \\{"method":"session/update","params":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"private reasoning"}}}}
        \\{"method":"session/update","params":{"update":{"sessionUpdate":"tool_call","content":{"type":"text","text":"tool request"}}}}
        \\{"method":"session/update","params":{"update":{"sessionUpdate":"tool_call_update","content":{"type":"text","text":"tool result"}}}}
        \\{"method":"_x.ai/session/update","params":{"update":{"sessionUpdate":"hooks_changed","content":{"type":"text","text":"hook state"}}}}
        \\{"method":"_x.ai/session/update","params":{"update":{"sessionUpdate":"plugins_changed","content":{"type":"text","text":"plugin state"}}}}
        \\{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","_meta":{"hideFromScrollback":true},"content":{"type":"text","text":"hidden text"}}}}
        \\{"method":"session/update","timestamp":"2026-09-02T12:00:01Z","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Done"}}}}
        \\{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"."}}}}
        \\{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"image","text":"not text"}}}}
        \\{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"truncated"}}}
    ;

    const messages = try parseUpdates(allocator, updates, "session-alpha", "/work/alpha");
    defer deinitMessages(allocator, messages);

    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("user", messages[0].role);
    try std.testing.expectEqualStrings("Plan carefully", messages[0].content);
    try std.testing.expectEqualStrings("2026-09-02T12:00:00Z", messages[0].timestamp.?);
    try std.testing.expectEqual(@as(i64, 1), messages[0].line_number);
    try std.testing.expectEqualStrings("assistant", messages[1].role);
    try std.testing.expectEqualStrings("Done.", messages[1].content);
    try std.testing.expectEqualStrings("2026-09-02T12:00:01Z", messages[1].timestamp.?);
    try std.testing.expectEqualStrings("session-alpha", messages[1].session_id.?);
    try std.testing.expectEqualStrings("alpha", messages[1].project_name.?);
    try std.testing.expectEqualStrings("/work/alpha", messages[1].project_dir.?);
}

fn writeFixture(path: []const u8, content: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.Io.Dir.cwd().createDirPath(runtime.io(), parent);
    const file = try std.Io.Dir.cwd().createFile(runtime.io(), path, .{});
    defer file.close(runtime.io());
    try file.writeStreamingAll(runtime.io(), content);
}

fn deinitSessions(allocator: std.mem.Allocator, sessions: []Session) void {
    for (sessions) |*session| session.deinit(allocator);
    allocator.free(sessions);
}

test "Grok discovery trusts summary metadata across encoded and long-cwd groups" {
    const allocator = std.testing.allocator;
    const tmpdir = runtime.getEnvVarOwned(allocator, "TMPDIR") catch try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmpdir);
    var namespace: u8 = 0;
    const root = try std.fmt.allocPrint(allocator, "{s}/chatscan-grok-discovery-{x}", .{ tmpdir, @intFromPtr(&namespace) });
    defer allocator.free(root);
    std.Io.Dir.cwd().deleteTree(runtime.io(), root) catch {};
    defer std.Io.Dir.cwd().deleteTree(runtime.io(), root) catch {};

    const alpha_summary = try std.fmt.allocPrint(allocator, "{s}/%2Fworkspace%2Falpha/session-alpha/summary.json", .{root});
    defer allocator.free(alpha_summary);
    try writeFixture(alpha_summary, "{\"info\":{\"id\":\"session-alpha\",\"cwd\":\"/workspace/alpha\"},\"generated_title\":\"Synthetic alpha\"}\n");

    const long_summary = try std.fmt.allocPrint(allocator, "{s}/long-slug-deadbeef/session-long/summary.json", .{root});
    defer allocator.free(long_summary);
    try writeFixture(long_summary, "{\"info\":{\"id\":\"session-long\",\"cwd\":\"/workspace/canonical-long\"}}\n");
    const sidecar = try std.fmt.allocPrint(allocator, "{s}/long-slug-deadbeef/.cwd", .{root});
    defer allocator.free(sidecar);
    try writeFixture(sidecar, "/workspace/decoy-sidecar\n");

    const invalid_summary = try std.fmt.allocPrint(allocator, "{s}/invalid/session-invalid/summary.json", .{root});
    defer allocator.free(invalid_summary);
    try writeFixture(invalid_summary, "{\"info\":{\"id\":\"session-invalid\"}}\n");

    const sessions = try findSessions(allocator, root);
    defer deinitSessions(allocator, sessions);

    try std.testing.expectEqual(@as(usize, 2), sessions.len);
    try std.testing.expectEqualStrings("session-alpha", sessions[0].id);
    try std.testing.expectEqualStrings("/workspace/alpha", sessions[0].cwd);
    try std.testing.expectEqualStrings("session-long", sessions[1].id);
    try std.testing.expectEqualStrings("/workspace/canonical-long", sessions[1].cwd);
    try std.testing.expect(std.mem.endsWith(u8, sessions[1].updates_path, "/long-slug-deadbeef/session-long/updates.jsonl"));

    const missing = try findSessions(allocator, "/synthetic/missing-grok-sessions");
    defer deinitSessions(allocator, missing);
    try std.testing.expectEqual(@as(usize, 0), missing.len);
}

test "duplicate Grok session identity reports deterministically ordered summaries" {
    const allocator = std.testing.allocator;
    const tmpdir = runtime.getEnvVarOwned(allocator, "TMPDIR") catch try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmpdir);
    var namespace: u8 = 0;
    const root = try std.fmt.allocPrint(allocator, "{s}/chatscan-grok-duplicate-{x}", .{ tmpdir, @intFromPtr(&namespace) });
    defer allocator.free(root);
    std.Io.Dir.cwd().deleteTree(runtime.io(), root) catch {};
    defer std.Io.Dir.cwd().deleteTree(runtime.io(), root) catch {};

    const z_summary = try std.fmt.allocPrint(allocator, "{s}/z-group/shared-id/summary.json", .{root});
    defer allocator.free(z_summary);
    try writeFixture(z_summary, "{\"info\":{\"id\":\"shared-id\",\"cwd\":\"/workspace/z\"}}\n");
    const a_summary = try std.fmt.allocPrint(allocator, "{s}/a-group/shared-id/summary.json", .{root});
    defer allocator.free(a_summary);
    try writeFixture(a_summary, "{\"info\":{\"id\":\"shared-id\",\"cwd\":\"/workspace/a\"}}\n");

    const sessions = try findSessions(allocator, root);
    defer deinitSessions(allocator, sessions);
    const duplicate = findDuplicateSession(sessions).?;

    try std.testing.expectEqualStrings("shared-id", duplicate.id);
    try std.testing.expect(std.mem.endsWith(u8, duplicate.first_summary_path, "/a-group/shared-id/summary.json"));
    try std.testing.expect(std.mem.endsWith(u8, duplicate.second_summary_path, "/z-group/shared-id/summary.json"));
}
