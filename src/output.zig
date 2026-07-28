const std = @import("std");
const cli = @import("cli.zig");
const search = @import("search.zig");
const storage = @import("storage.zig");
const config = @import("config.zig");

pub const OutputOptions = struct {
    use_color: bool = true,
    total_relevant: usize = 0,
    top_n: usize = 10,
    context_lines: usize = 4,
    show_sandwich: bool = true,
};

pub fn writeResults(
    allocator: std.mem.Allocator,
    db: ?storage.Db,
    writer: *std.Io.Writer,
    format: cli.OutputFormat,
    results: []const search.Result,
    options: OutputOptions,
) !void {
    switch (format) {
        .human => try writeHuman(allocator, db, writer, results, options),
        .json => try writeJson(allocator, writer, results, options),
    }
}

fn writeHuman(
    allocator: std.mem.Allocator,
    db: ?storage.Db,
    writer: *std.Io.Writer,
    results: []const search.Result,
    options: OutputOptions,
) !void {
    if (results.len == 0) {
        try writer.writeAll("No results found.\n");
        return;
    }

    if (options.total_relevant > results.len) {
        try writer.print("Showing {d} of {d} results (use --top {d} to see all)\n\n", .{
            results.len, options.total_relevant, options.total_relevant,
        });
    }

    for (results, 0..) |res, idx| {
        if (idx > 0) try writer.writeAll("\n");

        // Header line: index, project, score
        if (options.use_color) try writer.writeAll("\x1b[1m");
        try writer.print("{d}.", .{idx + 1});
        if (options.use_color) try writer.writeAll("\x1b[0m");

        if (res.message.project_name) |pn| {
            try writer.writeAll(" ");
            try writeColored(writer, options.use_color, "\x1b[36m", pn);
        }
        // LLM provenance tag (derived from the file path).
        const src = config.LlmSource.fromPath(res.message.file_path).label();
        if (options.use_color) try writer.writeAll("\x1b[2m");
        try writer.print(" [{s}]", .{src});
        if (options.use_color) try writer.writeAll("\x1b[0m");

        if (options.use_color) try writer.writeAll("\x1b[2m");
        try writer.print("  score {d:.3}", .{res.score});
        if (options.use_color) try writer.writeAll("\x1b[0m");
        try writer.writeAll("\n");

        // Sandwich display: prev (dim) | match (bright) | next (dim)
        if (options.show_sandwich) {
            if (db) |the_db| {
                var prev = storage.getAdjacentMessage(the_db, allocator, res.message.file_path, res.message.line_number, .prev) catch null;
                if (prev) |*p| {
                    defer p.deinit(allocator);
                    try writeMessageDim(writer, options, p.*);
                }
            }
        }

        // Matched message (bright)
        try writeMessageBright(writer, options, res.message);

        if (options.show_sandwich) {
            if (db) |the_db| {
                var next = storage.getAdjacentMessage(the_db, allocator, res.message.file_path, res.message.line_number, .next) catch null;
                if (next) |*n| {
                    defer n.deinit(allocator);
                    try writeMessageDim(writer, options, n.*);
                }
            }
        }
    }
}

fn writeMessageDim(writer: *std.Io.Writer, options: OutputOptions, msg: storage.Message) !void {
    if (options.use_color) try writer.writeAll("\x1b[2m");
    try writeMessageLine(writer, msg, options.context_lines);
    if (options.use_color) try writer.writeAll("\x1b[0m");
}

fn writeMessageBright(writer: *std.Io.Writer, options: OutputOptions, msg: storage.Message) !void {
    if (options.use_color) try writer.writeAll("\x1b[1m");
    try writeMessageLine(writer, msg, options.context_lines);
    if (options.use_color) try writer.writeAll("\x1b[0m");
}

fn writeMessageLine(writer: *std.Io.Writer, msg: storage.Message, max_lines: usize) !void {
    // Role and timestamp
    try writer.print("  {s}", .{msg.role});
    if (msg.timestamp) |ts| {
        // Show just date + time (truncate fractional seconds and Z)
        const display_ts = if (ts.len > 19) ts[0..19] else ts;
        // Replace T with space for readability
        try writer.writeAll(" (");
        for (display_ts) |ch| {
            if (ch == 'T') {
                try writer.writeAll(" ");
            } else {
                try writer.print("{c}", .{ch});
            }
        }
        try writer.writeAll(")");
    }
    try writer.writeAll(": ");

    // Content, truncated to max_lines
    const truncated = truncateContent(msg.content, max_lines);
    try writer.writeAll(truncated);
    if (truncated.len < msg.content.len) {
        try writer.writeAll("...");
    }
    try writer.writeAll("\n");
}

fn truncateContent(content: []const u8, max_lines: usize) []const u8 {
    if (max_lines == 0) return content;

    var lines: usize = 0;
    for (content, 0..) |ch, idx| {
        if (ch == '\n') {
            lines += 1;
            if (lines >= max_lines) {
                return content[0..idx];
            }
        }
    }
    return content;
}

fn writeJson(allocator: std.mem.Allocator, writer: *std.Io.Writer, results: []const search.Result, options: OutputOptions) !void {
    const JsonResult = struct {
        file_path: []const u8,
        line_number: i64,
        role: []const u8,
        content: []const u8,
        timestamp: ?[]const u8,
        session_id: ?[]const u8,
        project_name: ?[]const u8,
        project_dir: ?[]const u8,
        source: []const u8,
        score: f32,
        distance: f32,
        lexical: f32,
        bm25: f32,
    };

    const Payload = struct {
        total_relevant: usize,
        showing: usize,
        results: []const JsonResult,
    };

    var rows = try allocator.alloc(JsonResult, results.len);
    defer allocator.free(rows);

    for (results, 0..) |res, idx| {
        rows[idx] = .{
            .file_path = res.message.file_path,
            .line_number = res.message.line_number,
            .role = res.message.role,
            .content = res.message.content,
            .timestamp = res.message.timestamp,
            .session_id = res.message.session_id,
            .project_name = res.message.project_name,
            .project_dir = res.message.project_dir,
            .source = config.LlmSource.fromPath(res.message.file_path).label(),
            .score = res.score,
            .distance = res.distance,
            .lexical = res.lexical,
            .bm25 = res.bm25,
        };
    }

    var stream: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try stream.write(Payload{
        .total_relevant = options.total_relevant,
        .showing = results.len,
        .results = rows,
    });
    try writer.writeAll("\n");
}

fn writeColored(writer: *std.Io.Writer, use_color: bool, color: []const u8, text: []const u8) !void {
    if (use_color) try writer.writeAll(color);
    try writer.writeAll(text);
    if (use_color) try writer.writeAll("\x1b[0m");
}

test "truncateContent" {
    const content = "line 1\nline 2\nline 3\nline 4\nline 5";
    const result = truncateContent(content, 2);
    try std.testing.expectEqualStrings("line 1\nline 2", result);
}

test "truncateContent short content" {
    const content = "one liner";
    const result = truncateContent(content, 4);
    try std.testing.expectEqualStrings("one liner", result);
}
