const std = @import("std");
const config = @import("config.zig");
const conversation = @import("conversation.zig");
const storage = @import("storage.zig");
const runtime = @import("runtime.zig");

/// Summary of what the rename will do, for confirmation display.
pub const RenamePlan = struct {
    old_path: []const u8,
    new_path: []const u8,
    cwd_inside: bool,

    // Claude
    claude_old_slug: ?[]u8,
    claude_new_slug: ?[]u8,
    claude_old_dir: ?[]u8,
    claude_new_dir: ?[]u8,
    claude_file_count: usize,

    // Codex
    codex_files: [][]u8,

    // Gemini
    gemini_dirs: [][]u8,

    // Index
    index_message_count: i64,

    // Warnings
    has_lock_files: bool,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *RenamePlan) void {
        if (self.claude_old_slug) |s| self.allocator.free(s);
        if (self.claude_new_slug) |s| self.allocator.free(s);
        if (self.claude_old_dir) |s| self.allocator.free(s);
        if (self.claude_new_dir) |s| self.allocator.free(s);
        for (self.codex_files) |f| self.allocator.free(f);
        self.allocator.free(self.codex_files);
        for (self.gemini_dirs) |d| self.allocator.free(d);
        self.allocator.free(self.gemini_dirs);
    }
};

/// Resolve a path argument to absolute, normalizing `.` and `..` components.
/// If it starts with '/', it's absolute but still normalized.
/// Otherwise, resolve relative to cwd first.
pub fn resolvePath(allocator: std.mem.Allocator, path: []const u8, cwd: []const u8) ![]u8 {
    const joined = if (path.len > 0 and path[0] == '/')
        try allocator.dupe(u8, path)
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, path });
    defer allocator.free(joined);

    return normalizePath(allocator, joined);
}

/// Normalize a path by resolving `.` and `..` components.
fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var components = std.ArrayListUnmanaged([]const u8).empty;
    defer components.deinit(allocator);

    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) {
            continue;
        } else if (std.mem.eql(u8, component, "..")) {
            if (components.items.len > 0) {
                _ = components.pop();
            }
        } else {
            try components.append(allocator, component);
        }
    }

    // Rebuild path
    var total: usize = 0;
    for (components.items) |c| {
        total += 1 + c.len; // leading '/' + component
    }
    if (total == 0) total = 1; // root "/"

    var result = try allocator.alloc(u8, total);
    if (components.items.len == 0) {
        result[0] = '/';
        return result;
    }
    var pos: usize = 0;
    for (components.items) |c| {
        result[pos] = '/';
        pos += 1;
        @memcpy(result[pos..][0..c.len], c);
        pos += c.len;
    }
    return result;
}

/// Convert a path to Claude's current project-directory slug format.
/// e.g., /Users/pmarreck/Documents-CloudManaged/codescan -> -Users-pmarreck-Documents-CloudManaged-codescan
fn pathToSlug(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var slug = try allocator.alloc(u8, path.len);
    for (path, 0..) |ch, i| {
        slug[i] = if (std.ascii.isAlphanumeric(ch) or ch == '-') ch else '-';
    }
    return slug;
}

/// Build the rename plan by discovering all affected resources.
pub fn buildPlan(
    allocator: std.mem.Allocator,
    old_path: []const u8,
    new_path: []const u8,
    db: ?storage.Db,
) !RenamePlan {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(runtime.io(), ".", allocator);
    defer allocator.free(cwd);

    // Check if cwd is inside old_path
    const cwd_inside = std.mem.startsWith(u8, cwd, old_path);

    // Claude discovery
    const old_slug = try pathToSlug(allocator, old_path);
    const new_slug = try pathToSlug(allocator, new_path);

    const home = runtime.getEnvVarOwned(allocator, "HOME") catch null;
    defer if (home) |h| allocator.free(h);

    var claude_old_dir: ?[]u8 = null;
    var claude_new_dir: ?[]u8 = null;
    var claude_file_count: usize = 0;
    var has_lock_files = false;

    if (home) |h| {
        const old_dir = try std.fmt.allocPrint(allocator, "{s}/.claude/projects/{s}", .{ h, old_slug });
        if (dirExists(old_dir)) {
            claude_old_dir = old_dir;
            claude_new_dir = try std.fmt.allocPrint(allocator, "{s}/.claude/projects/{s}", .{ h, new_slug });
            claude_file_count = countFilesInDir(old_dir);
            has_lock_files = checkLockFiles(allocator, old_dir);
        } else {
            allocator.free(old_dir);
        }
    }

    // Codex discovery
    var codex_files_list = std.ArrayListUnmanaged([]u8).empty;
    if (home) |h| {
        const sessions_dir = try std.fmt.allocPrint(allocator, "{s}/.codex/sessions", .{h});
        defer allocator.free(sessions_dir);
        try findCodexFilesWithCwd(allocator, sessions_dir, old_path, &codex_files_list);
    }

    // Gemini discovery
    var gemini_dirs_list = std.ArrayListUnmanaged([]u8).empty;
    if (home) |h| {
        const gemini_dir = try std.fmt.allocPrint(allocator, "{s}/.gemini/tmp", .{h});
        defer allocator.free(gemini_dir);
        try findGeminiDirsWithPath(allocator, gemini_dir, old_path, &gemini_dirs_list);
    }

    // Index discovery
    var index_count: i64 = 0;
    if (db) |the_db| {
        index_count = countMessagesWithSlug(the_db, old_slug);
    }

    return RenamePlan{
        .old_path = old_path,
        .new_path = new_path,
        .cwd_inside = cwd_inside,
        .claude_old_slug = old_slug,
        .claude_new_slug = new_slug,
        .claude_old_dir = claude_old_dir,
        .claude_new_dir = claude_new_dir,
        .claude_file_count = claude_file_count,
        .codex_files = try codex_files_list.toOwnedSlice(allocator),
        .gemini_dirs = try gemini_dirs_list.toOwnedSlice(allocator),
        .index_message_count = index_count,
        .has_lock_files = has_lock_files,
        .allocator = allocator,
    };
}

/// Print the plan to the writer.
pub fn printPlan(plan: *const RenamePlan, writer: *std.Io.Writer) !void {
    try writer.writeAll("chatscan rename: the following changes will be made:\n\n");

    try writer.writeAll("  Project directory:\n");
    try writer.print("    mv {s}\n", .{plan.old_path});
    try writer.print("     → {s}\n\n", .{plan.new_path});

    if (plan.claude_old_dir != null) {
        try writer.writeAll("  Claude conversations:\n");
        try writer.print("    rename {s}/\n", .{plan.claude_old_dir.?});
        try writer.print("         → {s}/\n", .{plan.claude_new_dir.?});
        try writer.print("    ({d} files)\n\n", .{plan.claude_file_count});
    } else {
        try writer.writeAll("  Claude conversations: none found\n\n");
    }

    if (plan.codex_files.len > 0) {
        try writer.writeAll("  Codex sessions:\n");
        try writer.print("    update cwd in {d} session files\n\n", .{plan.codex_files.len});
    } else {
        try writer.writeAll("  Codex sessions: none found\n\n");
    }

    if (plan.gemini_dirs.len > 0) {
        try writer.writeAll("  Gemini:\n");
        try writer.print("    update .project_root in {d} project dirs\n\n", .{plan.gemini_dirs.len});
    } else {
        try writer.writeAll("  Gemini projects: none found\n\n");
    }

    if (plan.index_message_count > 0) {
        try writer.writeAll("  chatscan index:\n");
        try writer.print("    update {d} indexed messages\n\n", .{plan.index_message_count});
    } else {
        try writer.writeAll("  chatscan index: no matching messages\n\n");
    }

    if (plan.has_lock_files) {
        try writer.writeAll("  ⚠ WARNING: Lock files detected — an LLM agent may be running.\n");
        try writer.writeAll("  Stop any running agents before proceeding.\n\n");
    }

    if (plan.cwd_inside) {
        try writer.writeAll("  ⚠ WARNING: You are inside the directory being renamed.\n");
        try writer.print("  After completion, run: cd {s}\n\n", .{plan.new_path});
    }
}

/// Execute the rename plan.
pub fn executePlan(
    allocator: std.mem.Allocator,
    plan: *const RenamePlan,
    db: ?storage.Db,
    writer: *std.Io.Writer,
) !void {
    // Step 1: Move the project directory
    try writer.writeAll("Moving project directory...\n");
    try writer.flush();
    const old_z = try allocator.dupeZ(u8, plan.old_path);
    defer allocator.free(old_z);
    const new_z = try allocator.dupeZ(u8, plan.new_path);
    defer allocator.free(new_z);

    const rc = std.c.rename(old_z, new_z);
    if (rc != 0) {
        try writer.writeAll("ERROR: Failed to move project directory.\n");
        try writer.flush();
        return error.RenameFailed;
    }
    try writer.writeAll("  done.\n");

    // Step 2: Rename Claude conversation directory
    if (plan.claude_old_dir) |old_dir| {
        try writer.writeAll("Renaming Claude conversation directory...\n");
        try writer.flush();
        const claude_old_z = try allocator.dupeZ(u8, old_dir);
        defer allocator.free(claude_old_z);
        const claude_new_z = try allocator.dupeZ(u8, plan.claude_new_dir.?);
        defer allocator.free(claude_new_z);

        const rc2 = std.c.rename(claude_old_z, claude_new_z);
        if (rc2 != 0) {
            try writer.writeAll("  WARNING: Failed to rename Claude directory. Continuing.\n");
        } else {
            try writer.writeAll("  done.\n");
        }
    }

    // Step 3: Update Codex session files
    if (plan.codex_files.len > 0) {
        try writer.print("Updating {d} Codex session files...\n", .{plan.codex_files.len});
        try writer.flush();
        var updated: usize = 0;
        for (plan.codex_files) |file_path| {
            if (updateCodexFile(allocator, file_path, plan.old_path, plan.new_path)) {
                updated += 1;
            } else |_| {}
        }
        try writer.print("  done ({d}/{d} updated).\n", .{ updated, plan.codex_files.len });
    }

    // Step 4: Update Gemini .project_root files
    if (plan.gemini_dirs.len > 0) {
        try writer.print("Updating {d} Gemini project roots...\n", .{plan.gemini_dirs.len});
        try writer.flush();
        var updated: usize = 0;
        for (plan.gemini_dirs) |dir_path| {
            if (updateGeminiProjectRoot(allocator, dir_path, plan.new_path)) {
                updated += 1;
            } else |_| {}
        }
        try writer.print("  done ({d}/{d} updated).\n", .{ updated, plan.gemini_dirs.len });
    }

    // Step 5: Update chatscan index
    if (db) |the_db| {
        if (plan.index_message_count > 0) {
            try writer.print("Updating {d} chatscan index entries...\n", .{plan.index_message_count});
            try writer.flush();
            updateIndex(allocator, the_db, plan.claude_old_slug.?, plan.claude_new_slug.?, plan.claude_old_dir, plan.claude_new_dir);
            try writer.writeAll("  done.\n");
        }
    }

    try writer.writeAll("\nRename complete.\n");
    if (plan.cwd_inside) {
        try writer.print("Run: cd {s}\n", .{plan.new_path});
    }
    try writer.flush();
}

/// Read y/N confirmation from stdin. Returns true if user confirms.
pub fn confirmPrompt(writer: *std.Io.Writer) !bool {
    try writer.writeAll("Proceed? [y/N] ");
    try writer.flush();

    const stdin = std.Io.File.stdin();
    var buf: [16]u8 = undefined;
    var stdin_reader = stdin.reader(runtime.io(), &buf);
    const n = stdin_reader.interface.readSliceShort(&buf) catch return false;
    if (n == 0) return false;
    const input = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return input.len == 1 and (input[0] == 'y' or input[0] == 'Y');
}

// ── Internal helpers ─────────────────────────────────────────────────

fn dirExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(runtime.io(), path, .{}) catch return false;
    return true;
}

fn countFilesInDir(path: []const u8) usize {
    var dir = std.Io.Dir.cwd().openDir(runtime.io(), path, .{ .iterate = true }) catch return 0;
    defer dir.close(runtime.io());
    var count: usize = 0;
    var iter = dir.iterate();
    while (iter.next(runtime.io()) catch null) |entry| {
        if (entry.kind == .file) count += 1;
    }
    return count;
}

fn checkLockFiles(allocator: std.mem.Allocator, claude_dir: []const u8) bool {
    // Check for any .lock files in the claude project dir
    var dir = std.Io.Dir.cwd().openDir(runtime.io(), claude_dir, .{ .iterate = true }) catch return false;
    defer dir.close(runtime.io());
    var iter = dir.iterate();
    while (iter.next(runtime.io()) catch null) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".lock")) return true;
    }
    _ = allocator;
    return false;
}

fn findCodexFilesWithCwd(
    allocator: std.mem.Allocator,
    sessions_dir: []const u8,
    old_path: []const u8,
    result: *std.ArrayListUnmanaged([]u8),
) !void {
    const files = try conversation.findCodexFiles(allocator, sessions_dir);
    defer {
        for (files) |path| allocator.free(path);
        allocator.free(files);
    }
    for (files) |path| {
        if (fileContainsCwd(allocator, path, old_path)) {
            try result.append(allocator, try allocator.dupe(u8, path));
        }
    }
}

/// Match only the authoritative session metadata cwd, never incidental path text.
fn sessionMetaMatchesCwd(allocator: std.mem.Allocator, line: []const u8, target_cwd: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
        .allocate = .alloc_always,
    }) catch return false;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return false;
    const record_type = root.object.get("type") orelse return false;
    if (record_type != .string or !std.mem.eql(u8, record_type.string, "session_meta")) return false;
    const payload = root.object.get("payload") orelse return false;
    if (payload != .object) return false;
    const cwd = payload.object.get("cwd") orelse return false;
    return cwd == .string and std.mem.eql(u8, cwd.string, target_cwd);
}

fn fileContainsCwd(allocator: std.mem.Allocator, file_path: []const u8, target_cwd: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(runtime.io(), file_path, .{}) catch return false;
    defer file.close(runtime.io());
    var buf: [8192]u8 = undefined;
    var freader = file.reader(runtime.io(), &buf);
    const n = freader.interface.readSliceShort(&buf) catch return false;
    if (n == 0) return false;

    const first_line_end = std.mem.indexOfScalar(u8, buf[0..n], '\n') orelse n;
    return sessionMetaMatchesCwd(allocator, buf[0..first_line_end], target_cwd);
}

fn findGeminiDirsWithPath(
    allocator: std.mem.Allocator,
    gemini_dir: []const u8,
    old_path: []const u8,
    result: *std.ArrayListUnmanaged([]u8),
) !void {
    var dir = std.Io.Dir.cwd().openDir(runtime.io(), gemini_dir, .{ .iterate = true }) catch return;
    defer dir.close(runtime.io());

    var iter = dir.iterate();
    while (try iter.next(runtime.io())) |entry| {
        if (entry.kind != .directory) continue;

        const project_root_path = try std.fmt.allocPrint(allocator, "{s}/{s}/.project_root", .{ gemini_dir, entry.name });
        defer allocator.free(project_root_path);

        const file = std.Io.Dir.cwd().openFile(runtime.io(), project_root_path, .{}) catch continue;
        defer file.close(runtime.io());

        var buf: [4096]u8 = undefined;
        var freader = file.reader(runtime.io(), &buf);
        const n = freader.interface.readSliceShort(&buf) catch continue;
        const content = std.mem.trim(u8, buf[0..n], " \t\r\n");

        if (std.mem.eql(u8, content, old_path)) {
            const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ gemini_dir, entry.name });
            try result.append(allocator, dir_path);
        }
    }
}

fn updateCodexFile(allocator: std.mem.Allocator, file_path: []const u8, old_path: []const u8, new_path: []const u8) !void {
    const content = blk: {
        const file = try std.Io.Dir.cwd().openFile(runtime.io(), file_path, .{});
        defer file.close(runtime.io());
        const stat = try file.stat(runtime.io());
        if (stat.size > 200 * 1024 * 1024) return error.FileTooLarge;
        break :blk try runtime.readToEndAlloc(file, allocator, 200 * 1024 * 1024);
    };
    defer allocator.free(content);

    // Replace all occurrences of old_path with new_path in the content
    // This handles cwd fields in session_meta and any other path references
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, content, pos, old_path)) |found| {
        try output.writer.writeAll(content[pos..found]);
        try output.writer.writeAll(new_path);
        pos = found + old_path.len;
    }
    try output.writer.writeAll(content[pos..]);

    const new_content = try output.toOwnedSlice();
    defer allocator.free(new_content);

    // Write back
    const file = try std.Io.Dir.cwd().createFile(runtime.io(), file_path, .{});
    defer file.close(runtime.io());
    try file.writeStreamingAll(runtime.io(), new_content);
}

fn updateGeminiProjectRoot(allocator: std.mem.Allocator, dir_path: []const u8, new_path: []const u8) !void {
    const pr_path = try std.fmt.allocPrint(allocator, "{s}/.project_root", .{dir_path});
    defer allocator.free(pr_path);

    const file = try std.Io.Dir.cwd().createFile(runtime.io(), pr_path, .{});
    defer file.close(runtime.io());
    try file.writeStreamingAll(runtime.io(), new_path);
}

fn countMessagesWithSlug(db: storage.Db, slug: []const u8) i64 {
    const sql = "SELECT COUNT(*) FROM messages WHERE project_dir = ?1";
    var stmt: ?*storage.sqlite.sqlite3_stmt = null;
    if (storage.sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != storage.sqlite.SQLITE_OK) return 0;
    defer _ = storage.sqlite.sqlite3_finalize(stmt);
    storage.bindTextPub(stmt.?, 1, slug);
    if (storage.sqlite.sqlite3_step(stmt.?) != storage.sqlite.SQLITE_ROW) return 0;
    return storage.sqlite.sqlite3_column_int64(stmt.?, 0);
}

fn updateIndex(
    allocator: std.mem.Allocator,
    db: storage.Db,
    old_slug: []const u8,
    new_slug: []const u8,
    old_claude_dir: ?[]const u8,
    new_claude_dir: ?[]const u8,
) void {
    // Update project_dir
    {
        const sql = "UPDATE messages SET project_dir = ?1 WHERE project_dir = ?2";
        var stmt: ?*storage.sqlite.sqlite3_stmt = null;
        if (storage.sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null) == storage.sqlite.SQLITE_OK) {
            defer _ = storage.sqlite.sqlite3_finalize(stmt);
            storage.bindTextPub(stmt.?, 1, new_slug);
            storage.bindTextPub(stmt.?, 2, old_slug);
            _ = storage.sqlite.sqlite3_step(stmt.?);
        }
    }

    // Update file_path: replace old claude dir with new claude dir
    if (old_claude_dir) |old_dir| {
        if (new_claude_dir) |new_dir| {
            // Get all file_paths that start with old_dir and update them
            const select_sql = "SELECT DISTINCT file_path FROM messages WHERE file_path LIKE ?1";
            var sel_stmt: ?*storage.sqlite.sqlite3_stmt = null;
            const like_pattern = std.fmt.allocPrint(allocator, "{s}%", .{old_dir}) catch return;
            defer allocator.free(like_pattern);

            if (storage.sqlite.sqlite3_prepare_v2(db, select_sql, -1, &sel_stmt, null) == storage.sqlite.SQLITE_OK) {
                defer _ = storage.sqlite.sqlite3_finalize(sel_stmt);
                storage.bindTextPub(sel_stmt.?, 1, like_pattern);

                while (storage.sqlite.sqlite3_step(sel_stmt.?) == storage.sqlite.SQLITE_ROW) {
                    const old_fp_ptr = storage.sqlite.sqlite3_column_text(sel_stmt.?, 0);
                    if (old_fp_ptr == null) continue;
                    const old_fp_len = storage.sqlite.sqlite3_column_bytes(sel_stmt.?, 0);
                    const old_fp = old_fp_ptr[0..@intCast(old_fp_len)];

                    // Build new file_path
                    if (old_fp.len >= old_dir.len) {
                        const new_fp = std.fmt.allocPrint(allocator, "{s}{s}", .{ new_dir, old_fp[old_dir.len..] }) catch continue;
                        defer allocator.free(new_fp);

                        const update_sql = "UPDATE messages SET file_path = ?1 WHERE file_path = ?2";
                        var upd_stmt: ?*storage.sqlite.sqlite3_stmt = null;
                        if (storage.sqlite.sqlite3_prepare_v2(db, update_sql, -1, &upd_stmt, null) == storage.sqlite.SQLITE_OK) {
                            defer _ = storage.sqlite.sqlite3_finalize(upd_stmt);
                            storage.bindTextPub(upd_stmt.?, 1, new_fp);
                            storage.bindTextPub(upd_stmt.?, 2, old_fp);
                            _ = storage.sqlite.sqlite3_step(upd_stmt.?);
                        }

                        // Also update indexed_files
                        const idx_sql = "UPDATE indexed_files SET file_path = ?1 WHERE file_path = ?2";
                        var idx_stmt: ?*storage.sqlite.sqlite3_stmt = null;
                        if (storage.sqlite.sqlite3_prepare_v2(db, idx_sql, -1, &idx_stmt, null) == storage.sqlite.SQLITE_OK) {
                            defer _ = storage.sqlite.sqlite3_finalize(idx_stmt);
                            storage.bindTextPub(idx_stmt.?, 1, new_fp);
                            storage.bindTextPub(idx_stmt.?, 2, old_fp);
                            _ = storage.sqlite.sqlite3_step(idx_stmt.?);
                        }
                    }
                }
            }
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────

test "pathToSlug" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { path: []const u8, slug: []const u8 }{
        .{
            .path = "/Users/pmarreck/Documents-CloudManaged/codescan",
            .slug = "-Users-pmarreck-Documents-CloudManaged-codescan",
        },
        .{
            .path = "/home/pmarreck/Code/collation_mf_do_you_speak_it",
            .slug = "-home-pmarreck-Code-collation-mf-do-you-speak-it",
        },
        .{
            .path = "/home/pmarreck/Code/project.with spaces",
            .slug = "-home-pmarreck-Code-project-with-spaces",
        },
    };
    for (cases) |case| {
        const slug = try pathToSlug(allocator, case.path);
        defer allocator.free(slug);
        try std.testing.expectEqualStrings(case.slug, slug);
    }
}

test "resolvePath absolute" {
    const allocator = std.testing.allocator;
    const path = try resolvePath(allocator, "/absolute/path", "/some/cwd");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/absolute/path", path);
}

test "resolvePath relative" {
    const allocator = std.testing.allocator;
    const path = try resolvePath(allocator, "relative/path", "/some/cwd");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/some/cwd/relative/path", path);
}

test "resolvePath basename only" {
    const allocator = std.testing.allocator;
    const path = try resolvePath(allocator, "new-name", "/some/cwd");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/some/cwd/new-name", path);
}

test "resolvePath with dotdot" {
    const allocator = std.testing.allocator;
    const path = try resolvePath(allocator, "../cur_name", "/Users/pmarreck/Documents/cur_name");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/Users/pmarreck/Documents/cur_name", path);
}

test "resolvePath with dotdot from inside project" {
    const allocator = std.testing.allocator;
    // Inside /a/b/old, rename ../old ../new
    const old = try resolvePath(allocator, "../old", "/a/b/old");
    defer allocator.free(old);
    try std.testing.expectEqualStrings("/a/b/old", old);

    const new = try resolvePath(allocator, "../new", "/a/b/old");
    defer allocator.free(new);
    try std.testing.expectEqualStrings("/a/b/new", new);
}

test "resolvePath absolute with dotdot" {
    const allocator = std.testing.allocator;
    const path = try resolvePath(allocator, "/a/b/../c", "/ignored");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/a/c", path);
}

fn getTmpDir(allocator: std.mem.Allocator) []const u8 {
    return runtime.getEnvVarOwned(allocator, "TMPDIR") catch
        runtime.getEnvVarOwned(allocator, "TMP") catch "/tmp";
}

fn freeTmpDir(allocator: std.mem.Allocator, dir: []const u8) void {
    if (!std.mem.eql(u8, dir, "/tmp")) allocator.free(@constCast(dir));
}

test "updateCodexFile replaces cwd" {
    const allocator = std.testing.allocator;
    const tmpdir = getTmpDir(allocator);
    defer freeTmpDir(allocator, tmpdir);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}/chatscan-test-codex-rename.jsonl", .{tmpdir});
    defer allocator.free(tmp_path);
    {
        const f = try std.Io.Dir.cwd().createFile(runtime.io(), tmp_path, .{});
        defer f.close(runtime.io());
        try f.writeStreamingAll(runtime.io(), 
            \\{"timestamp":"2026-03-06T23:05:09.184Z","type":"session_meta","payload":{"cwd":"/Users/test/old-project"}}
            \\{"timestamp":"2026-03-06T23:05:14.241Z","type":"event_msg","payload":{"type":"user_message","message":"hello"}}
            \\
        );
    }
    defer std.Io.Dir.cwd().deleteFile(runtime.io(), tmp_path) catch {};

    try updateCodexFile(allocator, tmp_path, "/Users/test/old-project", "/Users/test/new-project");

    const f = try std.Io.Dir.cwd().openFile(runtime.io(), tmp_path, .{});
    defer f.close(runtime.io());
    const content = try runtime.readToEndAlloc(f, allocator, 1024 * 1024);
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "/Users/test/new-project") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "/Users/test/old-project") == null);
}

test "Codex rename discovery classifies exact session cwd over a set" {
    const allocator = std.testing.allocator;
    const tmpdir = getTmpDir(allocator);
    defer freeTmpDir(allocator, tmpdir);

    const sessions_dir = try std.fmt.allocPrint(allocator, "{s}/chatscan-test-codex-rename-discovery", .{tmpdir});
    defer allocator.free(sessions_dir);
    const day_dir = try std.fmt.allocPrint(allocator, "{s}/2026/08/05", .{sessions_dir});
    defer allocator.free(day_dir);
    const direct_match = try std.fmt.allocPrint(allocator, "{s}/direct-match.jsonl", .{day_dir});
    defer allocator.free(direct_match);
    const direct_other = try std.fmt.allocPrint(allocator, "{s}/direct-other.jsonl", .{day_dir});
    defer allocator.free(direct_other);
    const sibling_cwd = try std.fmt.allocPrint(allocator, "{s}/sibling-cwd.jsonl", .{day_dir});
    defer allocator.free(sibling_cwd);
    const incidental_text = try std.fmt.allocPrint(allocator, "{s}/incidental-text.jsonl", .{day_dir});
    defer allocator.free(incidental_text);

    std.Io.Dir.cwd().deleteTree(runtime.io(), sessions_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(runtime.io(), day_dir);
    defer std.Io.Dir.cwd().deleteTree(runtime.io(), sessions_dir) catch {};

    const fixtures = [_]struct { path: []const u8, line: []const u8 }{
        .{ .path = direct_match, .line = "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/home/test/old-project\"}}\n" },
        .{ .path = direct_other, .line = "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/home/test/other\"}}\n" },
        .{ .path = sibling_cwd, .line = "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/home/test/old-project-copy\"}}\n" },
        .{ .path = incidental_text, .line = "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/home/test/other\",\"note\":\"/home/test/old-project\"}}\n" },
    };
    for (fixtures) |fixture| {
        const file = try std.Io.Dir.cwd().createFile(runtime.io(), fixture.path, .{});
        defer file.close(runtime.io());
        try file.writeStreamingAll(runtime.io(), fixture.line);
    }

    var matches = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (matches.items) |path| allocator.free(path);
        matches.deinit(allocator);
    }
    try findCodexFilesWithCwd(allocator, sessions_dir, "/home/test/old-project", &matches);

    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    try std.testing.expectEqualStrings(direct_match, matches.items[0]);
}

test "updateGeminiProjectRoot writes new path" {
    const allocator = std.testing.allocator;
    const tmpdir = getTmpDir(allocator);
    defer freeTmpDir(allocator, tmpdir);

    const tmp_dir = try std.fmt.allocPrint(allocator, "{s}/chatscan-test-gemini-rename", .{tmpdir});
    defer allocator.free(tmp_dir);
    std.Io.Dir.cwd().createDirPath(runtime.io(), tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(runtime.io(), tmp_dir) catch {};

    const pr_path = try std.fmt.allocPrint(allocator, "{s}/.project_root", .{tmp_dir});
    defer allocator.free(pr_path);
    {
        const f = try std.Io.Dir.cwd().createFile(runtime.io(), pr_path, .{});
        defer f.close(runtime.io());
        try f.writeStreamingAll(runtime.io(), "/Users/test/old-project");
    }

    try updateGeminiProjectRoot(allocator, tmp_dir, "/Users/test/new-project");

    const f = try std.Io.Dir.cwd().openFile(runtime.io(), pr_path, .{});
    defer f.close(runtime.io());
    var buf: [1024]u8 = undefined;
    var fr = f.reader(runtime.io(), &buf);
    const n = try fr.interface.readSliceShort(&buf);
    try std.testing.expectEqualStrings("/Users/test/new-project", buf[0..n]);
}

test "full rename flow with temp dirs" {
    const allocator = std.testing.allocator;
    const tmpdir = getTmpDir(allocator);
    defer freeTmpDir(allocator, tmpdir);

    const old_dir = try std.fmt.allocPrint(allocator, "{s}/chatscan-test-old-project", .{tmpdir});
    defer allocator.free(old_dir);
    const new_dir = try std.fmt.allocPrint(allocator, "{s}/chatscan-test-new-project", .{tmpdir});
    defer allocator.free(new_dir);
    const test_file = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{old_dir});
    defer allocator.free(test_file);
    const new_test_file = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{new_dir});
    defer allocator.free(new_test_file);

    std.Io.Dir.cwd().createDirPath(runtime.io(), old_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(runtime.io(), old_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(runtime.io(), new_dir) catch {};

    {
        const f = try std.Io.Dir.cwd().createFile(runtime.io(), test_file, .{});
        defer f.close(runtime.io());
        try f.writeStreamingAll(runtime.io(), "hello");
    }

    var plan = try buildPlan(allocator, old_dir, new_dir, null);
    defer plan.deinit();

    try std.testing.expectEqualStrings(old_dir, plan.old_path);
    try std.testing.expectEqualStrings(new_dir, plan.new_path);

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(runtime.io(), &buf);
    try executePlan(allocator, &plan, null, &w.interface);

    // Verify old dir is gone and new dir exists with the file
    std.Io.Dir.cwd().access(runtime.io(), old_dir, .{}) catch |err| {
        try std.testing.expect(err == error.FileNotFound);
    };
    std.Io.Dir.cwd().access(runtime.io(), new_dir, .{}) catch {
        return error.TestUnexpectedResult;
    };
    const f = try std.Io.Dir.cwd().openFile(runtime.io(), new_test_file, .{});
    defer f.close(runtime.io());
    var read_buf: [64]u8 = undefined;
    var fr2 = f.reader(runtime.io(), &read_buf);
    const n = try fr2.interface.readSliceShort(&read_buf);
    try std.testing.expectEqualStrings("hello", read_buf[0..n]);
}
