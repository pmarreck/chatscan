const std = @import("std");

pub const RgMatch = struct {
    file_path: []const u8,
    line_number: usize,
    line_text: []const u8,

    pub fn deinit(self: *RgMatch, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
        allocator.free(self.line_text);
    }
};

/// Run ripgrep against the conversation directory and return matches.
pub fn searchRegex(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    conversation_dir: []const u8,
    max_results: usize,
) ![]RgMatch {
    var args = std.ArrayListUnmanaged([]const u8){};
    defer args.deinit(allocator);

    try args.append(allocator, "rg");
    try args.append(allocator, "--no-heading");
    try args.append(allocator, "--line-number");
    try args.append(allocator, "--color=never");
    try args.append(allocator, "--glob=*.jsonl");

    // Limit total matches to keep output manageable
    // --max-count is per-file, so we use a generous multiplier
    const max_count_str = try std.fmt.allocPrint(allocator, "--max-count={d}", .{max_results});
    defer allocator.free(max_count_str);
    try args.append(allocator, max_count_str);

    // Also limit line length to avoid huge JSONL lines blowing up memory
    try args.append(allocator, "--max-columns=500");
    try args.append(allocator, "--max-columns-preview");

    try args.append(allocator, pattern);
    try args.append(allocator, conversation_dir);

    var child = std.process.Child.init(args.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    // Allow up to 100MB
    const output = try child.stdout.?.readToEndAlloc(allocator, 100 * 1024 * 1024);
    defer allocator.free(output);

    const term = try child.wait();
    // rg returns 1 for no matches, 2+ for errors
    switch (term) {
        .Exited => |code| if (code > 1) return error.RipgrepFailed,
        else => return error.RipgrepFailed,
    }

    return parseRgOutput(allocator, output, max_results);
}

fn parseRgOutput(allocator: std.mem.Allocator, output: []const u8, max_results: usize) ![]RgMatch {
    var matches = std.ArrayListUnmanaged(RgMatch){};
    errdefer {
        for (matches.items) |*m| m.deinit(allocator);
        matches.deinit(allocator);
    }

    var line_iter = std.mem.splitScalar(u8, output, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        if (matches.items.len >= max_results) break;

        // Format: file_path:line_number:line_text
        const first_colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const rest = line[first_colon + 1 ..];
        const second_colon = std.mem.indexOfScalar(u8, rest, ':') orelse continue;

        const file_path = line[0..first_colon];
        const line_num_str = rest[0..second_colon];
        const line_text = rest[second_colon + 1 ..];

        const line_num = std.fmt.parseInt(usize, line_num_str, 10) catch continue;

        try matches.append(allocator, .{
            .file_path = try allocator.dupe(u8, file_path),
            .line_number = line_num,
            .line_text = try allocator.dupe(u8, line_text),
        });
    }

    return matches.toOwnedSlice(allocator);
}

test "parseRgOutput" {
    const allocator = std.testing.allocator;
    const output = "/home/user/.claude/projects/foo/abc.jsonl:42:some matching line\n/home/user/.claude/projects/foo/abc.jsonl:99:another match\n";
    const matches = try parseRgOutput(allocator, output, 100);
    defer {
        for (matches) |*m| m.deinit(allocator);
        allocator.free(matches);
    }
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqual(@as(usize, 42), matches[0].line_number);
    try std.testing.expectEqualStrings("some matching line", matches[0].line_text);
}
