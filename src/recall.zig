const std = @import("std");
const config = @import("config.zig");
const conversation = @import("conversation.zig");
const runtime = @import("runtime.zig");

pub const VerifiedHit = struct {
    reference: []const u8,
    role: []const u8,
    content: []const u8,
    timestamp: ?[]const u8,
    source: []const u8,
    session_id: ?[]const u8,
    project: ?[]const u8,
    file_path: []const u8,
    line_number: i64,
    content_sha256: []const u8,
    source_prefix_sha256: []const u8,
    source_prefix_bytes: u64,
    index_freshness: []const u8 = "unknown",
};

pub const RecallRequest = struct {
    query: []const u8,
    project: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    total_index_matches: usize,
    omitted_stale: usize = 0,
    omitted_unverifiable: usize = 0,
};

pub const IndexedClaim = struct {
    file_path: []const u8,
    line_number: i64,
    role: []const u8,
    content: []const u8,
    timestamp: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    project_name: ?[]const u8 = null,
    project_dir: ?[]const u8 = null,
};

pub const RawVerification = struct {
    message: conversation.ParsedMessage,
    canonical_project: ?[]u8,
    source_session_id: ?[]u8,
    content_sha256: [64]u8,
    source_prefix_sha256: [64]u8,
    source_prefix_bytes: usize,
    source_bytes: usize,

    pub fn deinit(self: *RawVerification, allocator: std.mem.Allocator) void {
        self.message.deinit(allocator);
        if (self.canonical_project) |value| allocator.free(value);
        if (self.source_session_id) |value| allocator.free(value);
    }
};

pub fn encodeReference(
    allocator: std.mem.Allocator,
    claim: IndexedClaim,
    source: config.LlmSource,
    verification: RawVerification,
) ![]u8 {
    const Payload = struct {
        version: u8 = 1,
        source: []const u8,
        path: []const u8,
        line: i64,
        prefix_bytes: usize,
        content_sha256: []const u8,
        prefix_sha256: []const u8,
    };
    var json: std.Io.Writer.Allocating = .init(allocator);
    defer json.deinit();
    var stream: std.json.Stringify = .{ .writer = &json.writer, .options = .{} };
    try stream.write(Payload{
        .source = source.label(),
        .path = claim.file_path,
        .line = claim.line_number,
        .prefix_bytes = verification.source_prefix_bytes,
        .content_sha256 = &verification.content_sha256,
        .prefix_sha256 = &verification.source_prefix_sha256,
    });
    const raw = json.written();
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(raw.len);
    const output = try allocator.alloc(u8, "csr1.".len + encoded_len);
    @memcpy(output[0.."csr1.".len], "csr1.");
    _ = std.base64.url_safe_no_pad.Encoder.encode(output["csr1.".len..], raw);
    return output;
}

pub fn verifyReference(
    allocator: std.mem.Allocator,
    io: std.Io,
    reference: []const u8,
) !RawVerification {
    var decoded = try decodeReference(allocator, reference);
    defer decoded.deinit(allocator);

    const bytes = readSource(allocator, io, decoded.file_path) catch |err| return err;
    defer allocator.free(bytes);
    if (bytes.len < decoded.prefix_bytes) return error.ReferenceInvalidated;
    if (!std.mem.eql(u8, &sha256Hex(bytes[0..decoded.prefix_bytes]), &decoded.source_prefix_sha256)) {
        return error.ReferenceInvalidated;
    }

    var parsed_message: conversation.ParsedMessage = undefined;
    var metadata = try extractSourceMetadata(allocator, bytes, decoded.source, decoded.line_number);
    errdefer metadata.deinit(allocator);
    if (decoded.source == .gemini) {
        if (bytes.len != decoded.prefix_bytes) return error.ReferenceInvalidated;
        const messages = conversation.parseGeminiFile(allocator, bytes, "") catch return error.ReferenceInvalidated;
        defer allocator.free(messages);
        var selected: ?usize = null;
        for (messages, 0..) |message, index| {
            if (message.line_number == decoded.line_number and selected == null) {
                selected = index;
            } else {
                var discarded = message;
                discarded.deinit(allocator);
            }
        }
        parsed_message = messages[selected orelse return error.ReferenceInvalidated];
    } else {
        const located = locateJsonlLine(bytes, decoded.line_number) orelse return error.ReferenceInvalidated;
        if (located.prefix_end != decoded.prefix_bytes) return error.ReferenceInvalidated;
        parsed_message = (switch (decoded.source) {
            .claude => conversation.parseLine(allocator, located.line, decoded.line_number, ""),
            .codex => conversation.parseCodexLine(allocator, located.line, decoded.line_number, ""),
            .gemini, .all => unreachable,
        } catch return error.ReferenceInvalidated) orelse return error.ReferenceInvalidated;
    }
    errdefer parsed_message.deinit(allocator);
    const content_hash = sha256Hex(parsed_message.content);
    if (!std.mem.eql(u8, &content_hash, &decoded.content_sha256)) return error.ReferenceInvalidated;

    return .{
        .message = parsed_message,
        .canonical_project = metadata.canonical_project,
        .source_session_id = metadata.session_id,
        .content_sha256 = content_hash,
        .source_prefix_sha256 = decoded.source_prefix_sha256,
        .source_prefix_bytes = decoded.prefix_bytes,
        .source_bytes = bytes.len,
    };
}

/// Expand a verified reference in chronological conversation order. Every
/// page obeys the final JSON byte budget; `cursor` resumes within a message
/// when that single message is larger than a page.
pub fn expandReference(
    allocator: std.mem.Allocator,
    io: std.Io,
    reference: []const u8,
    before: usize,
    after: usize,
    cursor: ?[]const u8,
    max_bytes: usize,
) ![]u8 {
    return expandReferenceWithIndexStatus(allocator, io, reference, before, after, cursor, max_bytes, "unknown");
}

pub fn expandReferenceWithIndexStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    reference: []const u8,
    before: usize,
    after: usize,
    cursor: ?[]const u8,
    max_bytes: usize,
    index_freshness: []const u8,
) ![]u8 {
    var decoded = try decodeReference(allocator, reference);
    defer decoded.deinit(allocator);
    const bytes = try readSource(allocator, io, decoded.file_path);
    defer allocator.free(bytes);
    if (bytes.len < decoded.prefix_bytes) return error.ReferenceInvalidated;
    const current_prefix_hash = sha256Hex(bytes[0..decoded.prefix_bytes]);
    if (!std.mem.eql(u8, &current_prefix_hash, &decoded.source_prefix_sha256)) return error.ReferenceInvalidated;
    if (decoded.source == .gemini and bytes.len != decoded.prefix_bytes) return error.ReferenceInvalidated;
    var source_metadata = try extractSourceMetadata(allocator, bytes, decoded.source, decoded.line_number);
    defer source_metadata.deinit(allocator);

    const messages = try parseSourceMessages(allocator, bytes, decoded.source);
    defer {
        for (messages) |*message| message.deinit(allocator);
        allocator.free(messages);
    }
    var anchor_index: ?usize = null;
    for (messages, 0..) |message, index| {
        if (message.message.line_number != decoded.line_number) continue;
        if (!std.mem.eql(u8, &message.content_sha256, &decoded.content_sha256)) return error.ReferenceInvalidated;
        if (message.prefix_bytes != decoded.prefix_bytes) return error.ReferenceInvalidated;
        anchor_index = index;
        break;
    }
    const anchor = anchor_index orelse return error.ReferenceInvalidated;
    const window_start = anchor -| before;
    const window_end = @min(messages.len, anchor + after + 1);

    var position = PagePosition{ .message_index = window_start, .content_offset = 0 };
    if (cursor) |token| {
        position = try decodeCursor(allocator, token, reference, before, after, messages, window_start, window_end);
    }
    if (position.message_index >= window_end) return error.CursorInvalidated;

    var rows = std.ArrayListUnmanaged(ExpandedMessage).empty;
    defer rows.deinit(allocator);
    var last_good: ?[]u8 = null;
    errdefer if (last_good) |page| allocator.free(page);

    while (position.message_index < window_end) {
        const message = &messages[position.message_index];
        if (position.content_offset >= message.message.content.len) return error.CursorInvalidated;

        const full_row = expandedMessage(decoded.source, source_metadata, message, position.content_offset, message.message.content.len);
        try rows.append(allocator, full_row);
        const after_full = PagePosition{ .message_index = position.message_index + 1, .content_offset = 0 };
        const full_cursor = try cursorForPosition(allocator, reference, before, after, messages, after_full, window_end);
        defer if (full_cursor) |token| allocator.free(token);
        const full_page = try serializeExpansion(allocator, reference, decoded, bytes.len, index_freshness, before, after, window_start, window_end, rows.items, full_cursor);
        if (full_page.len <= max_bytes) {
            if (last_good) |page| allocator.free(page);
            last_good = full_page;
            position = after_full;
            if (position.message_index >= window_end) return last_good.?;
            continue;
        }
        allocator.free(full_page);
        _ = rows.pop();

        var best_partial: ?[]u8 = null;
        errdefer if (best_partial) |page| allocator.free(page);
        var low = position.content_offset + 1;
        var high = message.message.content.len;
        while (low <= high) {
            const midpoint = low + (high - low) / 2;
            const end = utf8EndAtOrBefore(message.message.content, position.content_offset, midpoint);
            if (end <= position.content_offset) {
                low = midpoint + 1;
                continue;
            }
            try rows.append(allocator, expandedMessage(decoded.source, source_metadata, message, position.content_offset, end));
            const partial_position = PagePosition{ .message_index = position.message_index, .content_offset = end };
            const partial_cursor = try cursorForPosition(allocator, reference, before, after, messages, partial_position, window_end);
            defer if (partial_cursor) |token| allocator.free(token);
            const candidate = try serializeExpansion(allocator, reference, decoded, bytes.len, index_freshness, before, after, window_start, window_end, rows.items, partial_cursor);
            _ = rows.pop();
            if (candidate.len <= max_bytes) {
                if (best_partial) |page| allocator.free(page);
                best_partial = candidate;
                low = midpoint + 1;
            } else {
                allocator.free(candidate);
                high = midpoint - 1;
            }
        }
        if (best_partial) |page| {
            if (last_good) |previous| allocator.free(previous);
            return page;
        }
        if (last_good) |page| return page;
        return error.BudgetTooSmall;
    }
    return error.CursorInvalidated;
}

const SourceMessage = struct {
    message: conversation.ParsedMessage,
    prefix_bytes: usize,
    content_sha256: [64]u8,

    fn deinit(self: *SourceMessage, allocator: std.mem.Allocator) void {
        self.message.deinit(allocator);
    }
};

fn parseSourceMessages(allocator: std.mem.Allocator, bytes: []const u8, source: config.LlmSource) ![]SourceMessage {
    var output = std.ArrayListUnmanaged(SourceMessage).empty;
    errdefer {
        for (output.items) |*message| message.deinit(allocator);
        output.deinit(allocator);
    }
    if (source == .gemini) {
        const parsed = try conversation.parseGeminiFile(allocator, bytes, "");
        defer allocator.free(parsed);
        for (parsed) |message| {
            try output.append(allocator, .{
                .message = message,
                .prefix_bytes = bytes.len,
                .content_sha256 = sha256Hex(message.content),
            });
        }
        return output.toOwnedSlice(allocator);
    }

    var line_number: i64 = 1;
    var start: usize = 0;
    while (start < bytes.len) : (line_number += 1) {
        const newline = std.mem.indexOfScalarPos(u8, bytes, start, '\n');
        const raw_end = newline orelse bytes.len;
        const end = if (raw_end > start and bytes[raw_end - 1] == '\r') raw_end - 1 else raw_end;
        const prefix_end = if (newline != null) raw_end + 1 else raw_end;
        if (end > start) {
            var parsed = (switch (source) {
                .claude => conversation.parseLine(allocator, bytes[start..end], line_number, ""),
                .codex => conversation.parseCodexLine(allocator, bytes[start..end], line_number, ""),
                .gemini, .all => unreachable,
            } catch null);
            if (parsed) |*message| {
                try output.append(allocator, .{
                    .message = message.*,
                    .prefix_bytes = prefix_end,
                    .content_sha256 = sha256Hex(message.content),
                });
            }
        }
        if (newline == null) break;
        start = raw_end + 1;
    }
    return output.toOwnedSlice(allocator);
}

const PagePosition = struct {
    message_index: usize,
    content_offset: usize,
};

const Chunk = struct {
    text: []const u8,
    content_start: usize,
    content_end: usize,
    content_bytes: usize,
    complete: bool,
    exact: bool = true,
};

const ExpandedMessage = struct {
    line: i64,
    role: []const u8,
    timestamp: ?[]const u8,
    source: []const u8,
    session_id: ?[]const u8,
    project: ?[]const u8,
    content_sha256: []const u8,
    chunk: Chunk,
};

fn expandedMessage(
    source: config.LlmSource,
    metadata: SourceMetadata,
    message: *const SourceMessage,
    start: usize,
    end: usize,
) ExpandedMessage {
    return .{
        .line = message.message.line_number,
        .role = message.message.role,
        .timestamp = message.message.timestamp,
        .source = source.label(),
        .session_id = message.message.session_id orelse metadata.session_id,
        .project = metadata.canonical_project orelse message.message.project_name,
        .content_sha256 = &message.content_sha256,
        .chunk = .{
            .text = message.message.content[start..end],
            .content_start = start,
            .content_end = end,
            .content_bytes = message.message.content.len,
            .complete = start == 0 and end == message.message.content.len,
        },
    };
}

const ExpansionPayload = struct {
    schema: []const u8 = "chatscan/expand-v1",
    serialized_bytes: usize,
    reference: []const u8,
    source_status: struct {
        raw: []const u8 = "verified",
        index: []const u8,
        source_bytes: usize,
        anchor_prefix_bytes: usize,
        bytes_after_anchor: usize,
    },
    requested: struct { before: usize, after: usize },
    window: struct { first_line: i64, last_line: i64, messages: usize },
    messages: []const ExpandedMessage,
    continuation: ?[]const u8,
};

fn serializeExpansion(
    allocator: std.mem.Allocator,
    reference: []const u8,
    decoded: DecodedReference,
    source_bytes: usize,
    index_freshness: []const u8,
    before: usize,
    after: usize,
    window_start: usize,
    window_end: usize,
    rows: []const ExpandedMessage,
    continuation: ?[]const u8,
) ![]u8 {
    var serialized_bytes: usize = 0;
    for (0..8) |_| {
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        var stream: std.json.Stringify = .{ .writer = &output.writer, .options = .{} };
        const first_line = if (rows.len > 0) rows[0].line else decoded.line_number;
        const last_line = if (rows.len > 0) rows[rows.len - 1].line else decoded.line_number;
        try stream.write(ExpansionPayload{
            .serialized_bytes = serialized_bytes,
            .reference = reference,
            .source_status = .{
                .index = index_freshness,
                .source_bytes = source_bytes,
                .anchor_prefix_bytes = decoded.prefix_bytes,
                .bytes_after_anchor = source_bytes - decoded.prefix_bytes,
            },
            .requested = .{ .before = before, .after = after },
            .window = .{ .first_line = first_line, .last_line = last_line, .messages = window_end - window_start },
            .messages = rows,
            .continuation = continuation,
        });
        try output.writer.writeByte('\n');
        const rendered = try output.toOwnedSlice();
        if (rendered.len == serialized_bytes) return rendered;
        serialized_bytes = rendered.len;
        allocator.free(rendered);
    }
    return error.SerializedSizeDidNotConverge;
}

fn utf8EndAtOrBefore(content: []const u8, start: usize, proposed: usize) usize {
    var end = @min(proposed, content.len);
    while (end > start and end < content.len and isUtf8Continuation(content[end])) end -= 1;
    return end;
}

const CursorPayload = struct {
    version: u8 = 1,
    reference_sha256: []const u8,
    before: usize,
    after: usize,
    line: i64,
    content_offset: usize,
    content_sha256: []const u8,
};

fn cursorForPosition(
    allocator: std.mem.Allocator,
    reference: []const u8,
    before: usize,
    after: usize,
    messages: []const SourceMessage,
    position: PagePosition,
    window_end: usize,
) !?[]u8 {
    if (position.message_index >= window_end) return null;
    const message = messages[position.message_index];
    const reference_hash = sha256Hex(reference);
    var raw: std.Io.Writer.Allocating = .init(allocator);
    defer raw.deinit();
    var stream: std.json.Stringify = .{ .writer = &raw.writer, .options = .{} };
    try stream.write(CursorPayload{
        .reference_sha256 = &reference_hash,
        .before = before,
        .after = after,
        .line = message.message.line_number,
        .content_offset = position.content_offset,
        .content_sha256 = &message.content_sha256,
    });
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(raw.written().len);
    const token = try allocator.alloc(u8, "csc1.".len + encoded_len);
    @memcpy(token[0.."csc1.".len], "csc1.");
    _ = std.base64.url_safe_no_pad.Encoder.encode(token["csc1.".len..], raw.written());
    return token;
}

fn decodeCursor(
    allocator: std.mem.Allocator,
    token: []const u8,
    reference: []const u8,
    before: usize,
    after: usize,
    messages: []const SourceMessage,
    window_start: usize,
    window_end: usize,
) !PagePosition {
    const prefix = "csc1.";
    if (!std.mem.startsWith(u8, token, prefix)) return error.InvalidCursor;
    const encoded = token[prefix.len..];
    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded) catch return error.InvalidCursor;
    const raw = try allocator.alloc(u8, decoded_len);
    defer allocator.free(raw);
    std.base64.url_safe_no_pad.Decoder.decode(raw, encoded) catch return error.InvalidCursor;
    var parsed = std.json.parseFromSlice(CursorPayload, allocator, raw, .{}) catch return error.InvalidCursor;
    defer parsed.deinit();
    const value = parsed.value;
    const reference_hash = sha256Hex(reference);
    if (value.version != 1 or value.before != before or value.after != after or
        !std.mem.eql(u8, value.reference_sha256, &reference_hash) or value.content_sha256.len != 64)
    {
        return error.CursorInvalidated;
    }
    for (messages[window_start..window_end], window_start..) |message, index| {
        if (message.message.line_number != value.line) continue;
        if (!std.mem.eql(u8, value.content_sha256, &message.content_sha256)) return error.CursorInvalidated;
        if (value.content_offset >= message.message.content.len or
            (value.content_offset > 0 and isUtf8Continuation(message.message.content[value.content_offset])))
        {
            return error.CursorInvalidated;
        }
        return .{ .message_index = index, .content_offset = value.content_offset };
    }
    return error.CursorInvalidated;
}

pub const DecodedReference = struct {
    pub const algorithm = "sha256";
    source: config.LlmSource,
    file_path: []u8,
    line_number: i64,
    prefix_bytes: usize,
    content_sha256: [64]u8,
    source_prefix_sha256: [64]u8,

    pub fn deinit(self: *DecodedReference, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
    }
};

pub fn decodeReference(allocator: std.mem.Allocator, reference: []const u8) !DecodedReference {
    const prefix = "csr1.";
    if (!std.mem.startsWith(u8, reference, prefix)) return error.InvalidReference;
    const encoded = reference[prefix.len..];
    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded) catch return error.InvalidReference;
    const raw = try allocator.alloc(u8, decoded_len);
    defer allocator.free(raw);
    std.base64.url_safe_no_pad.Decoder.decode(raw, encoded) catch return error.InvalidReference;

    const Payload = struct {
        version: u8,
        source: []const u8,
        path: []const u8,
        line: i64,
        prefix_bytes: usize,
        content_sha256: []const u8,
        prefix_sha256: []const u8,
    };
    var parsed = std.json.parseFromSlice(Payload, allocator, raw, .{}) catch return error.InvalidReference;
    defer parsed.deinit();
    if (parsed.value.version != 1 or parsed.value.line < 1 or
        parsed.value.content_sha256.len != 64 or parsed.value.prefix_sha256.len != 64)
    {
        return error.InvalidReference;
    }
    const source = config.LlmSource.parse(parsed.value.source) catch return error.InvalidReference;
    if (source == .all) return error.InvalidReference;
    var content_hash: [64]u8 = undefined;
    var prefix_hash: [64]u8 = undefined;
    @memcpy(&content_hash, parsed.value.content_sha256);
    @memcpy(&prefix_hash, parsed.value.prefix_sha256);
    return .{
        .source = source,
        .file_path = try allocator.dupe(u8, parsed.value.path),
        .line_number = parsed.value.line,
        .prefix_bytes = parsed.value.prefix_bytes,
        .content_sha256 = content_hash,
        .source_prefix_sha256 = prefix_hash,
    };
}

fn readSource(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const max_source_bytes: usize = 256 * 1024 * 1024;
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.SourceMissing,
        else => return error.SourceUnreadable,
    };
    defer file.close(io);
    const stat = file.stat(io) catch return error.SourceUnreadable;
    if (stat.size > max_source_bytes) return error.SourceTooLarge;
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(max_source_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => error.SourceTooLarge,
        else => error.SourceUnreadable,
    };
}

/// Reopen and parse the indexed raw record before it can be presented as exact
/// evidence. JSONL verification hashes the prefix through the selected record,
/// so later append-only growth does not invalidate its identity.
pub fn verifyIndexedClaim(
    allocator: std.mem.Allocator,
    io: std.Io,
    claim: IndexedClaim,
    source: config.LlmSource,
) !RawVerification {
    const max_source_bytes: usize = 256 * 1024 * 1024;
    const file = std.Io.Dir.cwd().openFile(io, claim.file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.SourceMissing,
        else => return error.SourceUnreadable,
    };
    defer file.close(io);
    const stat = file.stat(io) catch return error.SourceUnreadable;
    if (stat.size > max_source_bytes) return error.SourceTooLarge;

    var reader_buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    const bytes = reader.interface.allocRemaining(allocator, .limited(max_source_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.SourceTooLarge,
        else => return error.SourceUnreadable,
    };
    defer allocator.free(bytes);

    var parsed_message: conversation.ParsedMessage = undefined;
    var metadata = try extractSourceMetadata(allocator, bytes, source, claim.line_number);
    errdefer metadata.deinit(allocator);
    var prefix_bytes: usize = bytes.len;
    if (source == .gemini) {
        const messages = conversation.parseGeminiFile(allocator, bytes, claim.project_dir orelse "") catch return error.SourceChanged;
        defer allocator.free(messages);
        var selected: ?usize = null;
        for (messages, 0..) |message, index| {
            if (message.line_number == claim.line_number and selected == null) {
                selected = index;
            } else {
                var discarded = message;
                discarded.deinit(allocator);
            }
        }
        const selected_index = selected orelse return error.SourceTruncated;
        parsed_message = messages[selected_index];
    } else {
        const located = locateJsonlLine(bytes, claim.line_number) orelse return error.SourceTruncated;
        prefix_bytes = located.prefix_end;
        parsed_message = (switch (source) {
            .claude => conversation.parseLine(allocator, located.line, claim.line_number, claim.project_dir orelse ""),
            .codex => conversation.parseCodexLine(allocator, located.line, claim.line_number, claim.project_dir orelse ""),
            .gemini, .all => unreachable,
        } catch return error.SourceChanged) orelse return error.SourceChanged;
    }
    errdefer parsed_message.deinit(allocator);

    if (!std.mem.eql(u8, claim.role, parsed_message.role) or
        !std.mem.eql(u8, claim.content, parsed_message.content) or
        !optionalEqual(claim.timestamp, parsed_message.timestamp) or
        !optionalEqual(claim.session_id, parsed_message.session_id orelse metadata.session_id))
    {
        return error.SourceChanged;
    }

    return .{
        .message = parsed_message,
        .canonical_project = metadata.canonical_project,
        .source_session_id = metadata.session_id,
        .content_sha256 = sha256Hex(parsed_message.content),
        .source_prefix_sha256 = sha256Hex(bytes[0..prefix_bytes]),
        .source_prefix_bytes = prefix_bytes,
        .source_bytes = bytes.len,
    };
}

const SourceMetadata = struct {
    canonical_project: ?[]u8 = null,
    session_id: ?[]u8 = null,

    fn deinit(self: *SourceMetadata, allocator: std.mem.Allocator) void {
        if (self.canonical_project) |value| allocator.free(value);
        if (self.session_id) |value| allocator.free(value);
    }
};

/// Extract only source-owned identity metadata. Transcript content remains
/// governed by the source-specific visible-message parsers.
fn extractSourceMetadata(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    source: config.LlmSource,
    target_line: i64,
) !SourceMetadata {
    var metadata = SourceMetadata{};
    errdefer metadata.deinit(allocator);
    if (source == .gemini) {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return metadata;
        defer parsed.deinit();
        if (parsed.value != .object) return metadata;
        metadata.canonical_project = try dupeFirstString(allocator, parsed.value.object, &.{ "project_root", "cwd" });
        metadata.session_id = try dupeFirstString(allocator, parsed.value.object, &.{ "sessionId", "id" });
        return metadata;
    }
    if (source == .claude) {
        const located = locateJsonlLine(bytes, target_line) orelse return metadata;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, located.line, .{}) catch return metadata;
        defer parsed.deinit();
        if (parsed.value != .object) return metadata;
        metadata.canonical_project = try dupeFirstString(allocator, parsed.value.object, &.{"cwd"});
        metadata.session_id = try dupeFirstString(allocator, parsed.value.object, &.{"sessionId"});
        return metadata;
    }

    var line_iter = std.mem.splitScalar(u8, bytes, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const kind = parsed.value.object.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "session_meta")) continue;
        const payload = parsed.value.object.get("payload") orelse continue;
        if (payload != .object) continue;
        metadata.canonical_project = try dupeFirstString(allocator, payload.object, &.{"cwd"});
        metadata.session_id = try dupeFirstString(allocator, payload.object, &.{ "id", "session_id" });
        break;
    }
    return metadata;
}

fn dupeFirstString(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    keys: []const []const u8,
) !?[]u8 {
    for (keys) |key| {
        const value = object.get(key) orelse continue;
        if (value == .string and value.string.len > 0) return try allocator.dupe(u8, value.string);
    }
    return null;
}

const LocatedLine = struct {
    line: []const u8,
    prefix_end: usize,
};

fn locateJsonlLine(bytes: []const u8, requested_line: i64) ?LocatedLine {
    if (requested_line < 1) return null;
    var line_number: i64 = 1;
    var start: usize = 0;
    for (bytes, 0..) |byte, index| {
        if (byte != '\n') continue;
        if (line_number == requested_line) {
            const end = if (index > start and bytes[index - 1] == '\r') index - 1 else index;
            return .{ .line = bytes[start..end], .prefix_end = index + 1 };
        }
        line_number += 1;
        start = index + 1;
    }
    if (line_number == requested_line and start < bytes.len) {
        const end = if (bytes.len > start and bytes[bytes.len - 1] == '\r') bytes.len - 1 else bytes.len;
        return .{ .line = bytes[start..end], .prefix_end = bytes.len };
    }
    return null;
}

fn optionalEqual(expected: ?[]const u8, actual: ?[]const u8) bool {
    if (expected) |value| {
        const candidate = actual orelse return false;
        return std.mem.eql(u8, value, candidate);
    }
    return true;
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const alphabet = "0123456789abcdef";
    var hex: [64]u8 = undefined;
    for (digest, 0..) |byte, index| {
        hex[index * 2] = alphabet[byte >> 4];
        hex[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return hex;
}

const default_excerpt_bytes: usize = 512;

const Excerpt = struct {
    text: []const u8,
    content_start: usize,
    content_end: usize,
    content_bytes: usize,
    omitted_before: usize,
    omitted_after: usize,
    exact: bool = true,
};

const JsonHit = struct {
    ref: []const u8,
    role: []const u8,
    timestamp: ?[]const u8,
    source: []const u8,
    session_id: ?[]const u8,
    project: ?[]const u8,
    locator: struct {
        path: []const u8,
        line: i64,
    },
    identity: struct {
        algorithm: []const u8 = "sha256",
        content_sha256: []const u8,
        source_prefix_sha256: []const u8,
        source_prefix_bytes: u64,
    },
    index_freshness: []const u8,
    excerpt: Excerpt,
};

const Scope = struct {
    project: ?[]const u8,
    session_id: ?[]const u8,
};

const Omissions = struct {
    budget: usize,
    stale: usize,
    unverifiable: usize,
};

const RecallPayload = struct {
    schema: []const u8 = "chatscan/recall-v1",
    serialized_bytes: usize,
    query: []const u8,
    scope: Scope,
    total_index_matches: usize,
    showing: usize,
    omissions: Omissions,
    absence_is_proof: bool = false,
    results: []const JsonHit,
};

/// Render source-verified search hits without exceeding the final serialized
/// stdout byte budget, including JSON escapes and the trailing newline.
pub fn renderRecall(
    allocator: std.mem.Allocator,
    request: RecallRequest,
    hits: []const VerifiedHit,
    max_bytes: usize,
) ![]u8 {
    const minimum = try serializeRecall(allocator, request, &.{}, hits.len, 0);
    if (minimum.len > max_bytes) {
        allocator.free(minimum);
        return error.BudgetTooSmall;
    }
    allocator.free(minimum);

    var showing = hits.len;
    while (showing > 0) : (showing -= 1) {
        const smallest = try serializeRecall(allocator, request, hits[0..showing], hits.len - showing, 0);
        if (smallest.len > max_bytes) {
            allocator.free(smallest);
            continue;
        }

        var best = smallest;
        var low: usize = 1;
        var high: usize = default_excerpt_bytes;
        while (low <= high) {
            const midpoint = low + (high - low) / 2;
            const candidate = try serializeRecall(allocator, request, hits[0..showing], hits.len - showing, midpoint);
            if (candidate.len <= max_bytes) {
                allocator.free(best);
                best = candidate;
                low = midpoint + 1;
            } else {
                allocator.free(candidate);
                if (midpoint == 0) break;
                high = midpoint - 1;
            }
        }
        return best;
    }

    return serializeRecall(allocator, request, &.{}, hits.len, 0);
}

fn serializeRecall(
    allocator: std.mem.Allocator,
    request: RecallRequest,
    hits: []const VerifiedHit,
    omitted_budget: usize,
    excerpt_limit: usize,
) ![]u8 {
    const rows = try allocator.alloc(JsonHit, hits.len);
    defer allocator.free(rows);
    for (hits, 0..) |hit, index| {
        rows[index] = .{
            .ref = hit.reference,
            .role = hit.role,
            .timestamp = hit.timestamp,
            .source = hit.source,
            .session_id = hit.session_id,
            .project = hit.project,
            .locator = .{ .path = hit.file_path, .line = hit.line_number },
            .identity = .{
                .content_sha256 = hit.content_sha256,
                .source_prefix_sha256 = hit.source_prefix_sha256,
                .source_prefix_bytes = hit.source_prefix_bytes,
            },
            .index_freshness = hit.index_freshness,
            .excerpt = excerptAround(hit.content, request.query, excerpt_limit),
        };
    }

    var serialized_bytes: usize = 0;
    var attempts: usize = 0;
    while (attempts < 8) : (attempts += 1) {
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        var stream: std.json.Stringify = .{ .writer = &output.writer, .options = .{} };
        try stream.write(RecallPayload{
            .serialized_bytes = serialized_bytes,
            .query = request.query,
            .scope = .{ .project = request.project, .session_id = request.session_id },
            .total_index_matches = request.total_index_matches,
            .showing = hits.len,
            .omissions = .{
                .budget = omitted_budget,
                .stale = request.omitted_stale,
                .unverifiable = request.omitted_unverifiable,
            },
            .results = rows,
        });
        try output.writer.writeByte('\n');
        const bytes = try output.toOwnedSlice();
        if (bytes.len == serialized_bytes) return bytes;
        serialized_bytes = bytes.len;
        allocator.free(bytes);
    }
    return error.SerializedSizeDidNotConverge;
}

/// Select an exact byte slice around the first ASCII-insensitive query match,
/// moving both bounds to UTF-8 codepoint boundaries.
fn excerptAround(content: []const u8, query: []const u8, requested_limit: usize) Excerpt {
    if (content.len == 0) return .{
        .text = "",
        .content_start = 0,
        .content_end = 0,
        .content_bytes = 0,
        .omitted_before = 0,
        .omitted_after = 0,
    };

    const match_start = indexOfIgnoreCaseAscii(content, query) orelse 0;
    const match_end = @min(content.len, match_start + query.len);
    const minimum = if (query.len > 0 and match_end > match_start) match_end - match_start else 1;
    const limit = @min(content.len, @max(requested_limit, minimum));
    const surrounding = limit - minimum;
    var start = match_start -| surrounding / 2;
    if (start + limit > content.len) start = content.len - limit;
    var end = start + limit;

    while (start > 0 and isUtf8Continuation(content[start])) start -= 1;
    while (end > start and end < content.len and isUtf8Continuation(content[end])) end -= 1;
    if (end < match_end) {
        end = match_end;
        while (end < content.len and isUtf8Continuation(content[end])) end += 1;
    }

    return .{
        .text = content[start..end],
        .content_start = start,
        .content_end = end,
        .content_bytes = content.len,
        .omitted_before = start,
        .omitted_after = content.len - end,
    };
}

fn indexOfIgnoreCaseAscii(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var equal = true;
        for (needle, 0..) |byte, offset| {
            if (std.ascii.toLower(haystack[start + offset]) != std.ascii.toLower(byte)) {
                equal = false;
                break;
            }
        }
        if (equal) return start;
    }
    return null;
}

fn isUtf8Continuation(byte: u8) bool {
    return byte & 0b1100_0000 == 0b1000_0000;
}

fn writeTestFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

test "raw JSONL verification classifies exact appended changed truncated and missing sources" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmpdir = runtime.getEnvVarOwned(allocator, "TMPDIR") catch try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmpdir);
    var namespace: u8 = 0;
    const root = try std.fmt.allocPrint(allocator, "{s}/chatscan-recall-{x}", .{ tmpdir, @intFromPtr(&namespace) });
    defer allocator.free(root);
    const path = try std.fmt.allocPrint(allocator, "{s}/session.jsonl", .{root});
    defer allocator.free(path);

    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const line1 = "{\"type\":\"user\",\"timestamp\":\"2026-09-16T10:00:00Z\",\"sessionId\":\"s1\",\"message\":{\"content\":\"first\"}}\n";
    const line2 = "{\"type\":\"assistant\",\"timestamp\":\"2026-09-16T10:00:01Z\",\"sessionId\":\"s1\",\"message\":{\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"exact évidence\"}]}}\n";
    const appended = "{\"type\":\"user\",\"timestamp\":\"2026-09-16T10:00:02Z\",\"sessionId\":\"s1\",\"message\":{\"content\":\"later\"}}\n";
    const original = try std.mem.concat(allocator, u8, &.{ line1, line2 });
    defer allocator.free(original);
    const with_append = try std.mem.concat(allocator, u8, &.{ line1, line2, appended });
    defer allocator.free(with_append);

    const claim = IndexedClaim{
        .file_path = path,
        .line_number = 2,
        .role = "assistant",
        .content = "exact évidence",
        .timestamp = "2026-09-16T10:00:01Z",
        .session_id = "s1",
    };

    try writeTestFile(io, path, original);
    var exact = try verifyIndexedClaim(allocator, io, claim, .claude);
    defer exact.deinit(allocator);
    try std.testing.expectEqualStrings(claim.content, exact.message.content);
    try std.testing.expectEqual(line1.len + line2.len, exact.source_prefix_bytes);
    try std.testing.expectEqual(original.len, exact.source_bytes);

    try writeTestFile(io, path, with_append);
    var grown = try verifyIndexedClaim(allocator, io, claim, .claude);
    defer grown.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &exact.source_prefix_sha256, &grown.source_prefix_sha256);
    try std.testing.expect(grown.source_bytes > grown.source_prefix_bytes);

    const changed = try std.mem.concat(allocator, u8, &.{ line1, "{\"type\":\"assistant\",\"message\":{\"stop_reason\":\"end_turn\",\"content\":\"changed\"}}\n" });
    defer allocator.free(changed);
    try writeTestFile(io, path, changed);
    try std.testing.expectError(error.SourceChanged, verifyIndexedClaim(allocator, io, claim, .claude));

    try writeTestFile(io, path, line1);
    try std.testing.expectError(error.SourceTruncated, verifyIndexedClaim(allocator, io, claim, .claude));

    try std.Io.Dir.cwd().deleteFile(io, path);
    try std.testing.expectError(error.SourceMissing, verifyIndexedClaim(allocator, io, claim, .claude));
}

test "reference survives append but rejects changed prefix and supports paths with spaces" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmpdir = runtime.getEnvVarOwned(allocator, "TMPDIR") catch try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmpdir);
    var namespace: u8 = 0;
    const root = try std.fmt.allocPrint(allocator, "{s}/chatscan ref λ {x}", .{ tmpdir, @intFromPtr(&namespace) });
    defer allocator.free(root);
    const path = try std.fmt.allocPrint(allocator, "{s}/session file.jsonl", .{root});
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const before = "{\"type\":\"user\",\"sessionId\":\"s1\",\"message\":{\"content\":\"before\"}}\n";
    const target = "{\"type\":\"assistant\",\"sessionId\":\"s1\",\"message\":{\"stop_reason\":\"end_turn\",\"content\":\"target\"}}\n";
    const later = "{\"type\":\"user\",\"sessionId\":\"s1\",\"message\":{\"content\":\"later\"}}\n";
    const original = try std.mem.concat(allocator, u8, &.{ before, target });
    defer allocator.free(original);
    try writeTestFile(io, path, original);
    const claim = IndexedClaim{
        .file_path = path,
        .line_number = 2,
        .role = "assistant",
        .content = "target",
        .session_id = "s1",
    };
    var verified = try verifyIndexedClaim(allocator, io, claim, .claude);
    defer verified.deinit(allocator);
    const reference = try encodeReference(allocator, claim, .claude, verified);
    defer allocator.free(reference);
    try std.testing.expectError(error.BudgetTooSmall, expandReference(allocator, io, reference, 1, 1, null, 10));
    try std.testing.expect(std.mem.startsWith(u8, reference, "csr1."));

    const appended_source = try std.mem.concat(allocator, u8, &.{ before, target, later });
    defer allocator.free(appended_source);
    try writeTestFile(io, path, appended_source);
    var after_append = try verifyReference(allocator, io, reference);
    defer after_append.deinit(allocator);
    try std.testing.expectEqualStrings("target", after_append.message.content);

    const changed_prefix = try std.mem.concat(allocator, u8, &.{
        "{\"type\":\"user\",\"sessionId\":\"s1\",\"message\":{\"content\":\"different before\"}}\n",
        target,
        later,
    });
    defer allocator.free(changed_prefix);
    try writeTestFile(io, path, changed_prefix);
    try std.testing.expectError(error.ReferenceInvalidated, verifyReference(allocator, io, reference));
}

test "Codex expansion uses visible event messages once and source-owned identity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmpdir = runtime.getEnvVarOwned(allocator, "TMPDIR") catch try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmpdir);
    var namespace: u8 = 0;
    const root = try std.fmt.allocPrint(allocator, "{s}/chatscan-codex-recall-{x}", .{ tmpdir, @intFromPtr(&namespace) });
    defer allocator.free(root);
    const path = try std.fmt.allocPrint(allocator, "{s}/rollout-session-42.jsonl", .{root});
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const source =
        "{\"timestamp\":\"2026-09-16T10:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"session-42\",\"cwd\":\"/work/project-real\"}}\n" ++
        "{\"timestamp\":\"2026-09-16T10:00:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"question\"}}\n" ++
        "{\"timestamp\":\"2026-09-16T10:00:01Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":\"question\"}}\n" ++
        "{\"timestamp\":\"2026-09-16T10:00:02Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"answer\"}}\n" ++
        "{\"timestamp\":\"2026-09-16T10:00:02Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":\"answer\"}}\n" ++
        "{\"timestamp\":\"2026-09-16T10:00:03Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"function_call\",\"name\":\"shell\"}}\n";
    try writeTestFile(io, path, source);

    const claim = IndexedClaim{
        .file_path = path,
        .line_number = 4,
        .role = "assistant",
        .content = "answer",
        .timestamp = "2026-09-16T10:00:02Z",
    };
    var verified = try verifyIndexedClaim(allocator, io, claim, .codex);
    defer verified.deinit(allocator);
    try std.testing.expectEqualStrings("session-42", verified.source_session_id.?);
    try std.testing.expectEqualStrings("/work/project-real", verified.canonical_project.?);
    const reference = try encodeReference(allocator, claim, .codex, verified);
    defer allocator.free(reference);
    const page = try expandReference(allocator, io, reference, 1, 1, null, 4096);
    defer allocator.free(page);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, page, .{});
    defer parsed.deinit();
    const messages = parsed.value.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("question", messages[0].object.get("chunk").?.object.get("text").?.string);
    try std.testing.expectEqualStrings("answer", messages[1].object.get("chunk").?.object.get("text").?.string);
    for (messages) |message| {
        try std.testing.expectEqualStrings("session-42", message.object.get("session_id").?.string);
        try std.testing.expectEqualStrings("/work/project-real", message.object.get("project").?.string);
    }
}

test "Gemini expansion verifies whole-file identity and ignores non-conversation records" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmpdir = runtime.getEnvVarOwned(allocator, "TMPDIR") catch try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmpdir);
    var namespace: u8 = 0;
    const root = try std.fmt.allocPrint(allocator, "{s}/chatscan-gemini-recall-{x}", .{ tmpdir, @intFromPtr(&namespace) });
    defer allocator.free(root);
    const path = try std.fmt.allocPrint(allocator, "{s}/session.json", .{root});
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const source =
        "{\"id\":\"gem-session\",\"project_root\":\"/work/gem-project\",\"messages\":[" ++
        "{\"type\":\"system\",\"content\":\"notification\"}," ++
        "{\"type\":\"user\",\"timestamp\":\"2026-09-16T11:00:00Z\",\"content\":[{\"text\":\"gem question\"}]}," ++
        "{\"type\":\"tool\",\"content\":\"tool output\"}," ++
        "{\"type\":\"gemini\",\"timestamp\":\"2026-09-16T11:00:01Z\",\"content\":[{\"text\":\"gem answer\"}]}]}";
    try writeTestFile(io, path, source);
    const claim = IndexedClaim{
        .file_path = path,
        .line_number = 4,
        .role = "assistant",
        .content = "gem answer",
        .timestamp = "2026-09-16T11:00:01Z",
    };
    var verified = try verifyIndexedClaim(allocator, io, claim, .gemini);
    defer verified.deinit(allocator);
    try std.testing.expectEqualStrings("gem-session", verified.source_session_id.?);
    try std.testing.expectEqualStrings("/work/gem-project", verified.canonical_project.?);
    const reference = try encodeReference(allocator, claim, .gemini, verified);
    defer allocator.free(reference);
    const page = try expandReference(allocator, io, reference, 1, 1, null, 4096);
    defer allocator.free(page);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, page, .{});
    defer parsed.deinit();
    const messages = parsed.value.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("gem question", messages[0].object.get("chunk").?.object.get("text").?.string);
    try std.testing.expectEqualStrings("gem answer", messages[1].object.get("chunk").?.object.get("text").?.string);

    const replaced =
        "{\"id\":\"gem-session\",\"project_root\":\"/work/gem-project\",\"messages\":[" ++
        "{\"type\":\"user\",\"content\":\"replacement\"}]}";
    try writeTestFile(io, path, replaced);
    try std.testing.expectError(error.ReferenceInvalidated, verifyReference(allocator, io, reference));
}

test "reference line disambiguates repeated identical message text" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmpdir = runtime.getEnvVarOwned(allocator, "TMPDIR") catch try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmpdir);
    var namespace: u8 = 0;
    const root = try std.fmt.allocPrint(allocator, "{s}/chatscan-repeat-recall-{x}", .{ tmpdir, @intFromPtr(&namespace) });
    defer allocator.free(root);
    const path = try std.fmt.allocPrint(allocator, "{s}/session.jsonl", .{root});
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const source =
        "{\"type\":\"user\",\"sessionId\":\"repeat\",\"message\":{\"content\":\"same words\"}}\n" ++
        "{\"type\":\"assistant\",\"sessionId\":\"repeat\",\"message\":{\"stop_reason\":\"end_turn\",\"content\":\"middle\"}}\n" ++
        "{\"type\":\"user\",\"sessionId\":\"repeat\",\"message\":{\"content\":\"same words\"}}\n" ++
        "{\"type\":\"assistant\",\"sessionId\":\"repeat\",\"message\":{\"stop_reason\":\"end_turn\",\"content\":\"after second\"}}\n";
    try writeTestFile(io, path, source);
    const claim = IndexedClaim{
        .file_path = path,
        .line_number = 3,
        .role = "user",
        .content = "same words",
        .session_id = "repeat",
    };
    var verified = try verifyIndexedClaim(allocator, io, claim, .claude);
    defer verified.deinit(allocator);
    const reference = try encodeReference(allocator, claim, .claude, verified);
    defer allocator.free(reference);
    const page = try expandReference(allocator, io, reference, 0, 1, null, 4096);
    defer allocator.free(page);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, page, .{});
    defer parsed.deinit();
    const messages = parsed.value.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqual(@as(i64, 3), messages[0].object.get("line").?.integer);
    try std.testing.expectEqualStrings("after second", messages[1].object.get("chunk").?.object.get("text").?.string);
}

test "expand pages reconstruct surrounding turns once and continue within an oversized UTF-8 message" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmpdir = runtime.getEnvVarOwned(allocator, "TMPDIR") catch try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmpdir);
    var namespace: u8 = 0;
    const root = try std.fmt.allocPrint(allocator, "{s}/chatscan-expand-{x}", .{ tmpdir, @intFromPtr(&namespace) });
    defer allocator.free(root);
    const path = try std.fmt.allocPrint(allocator, "{s}/session.jsonl", .{root});
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var huge = std.ArrayListUnmanaged(u8).empty;
    defer huge.deinit(allocator);
    for (0..1800) |_| try huge.appendSlice(allocator, "é");
    const before_text = "prior turn";
    const after_text = "following turn";
    const line1 = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"user\",\"timestamp\":\"2026-09-16T10:00:00Z\",\"sessionId\":\"s1\",\"message\":{{\"content\":\"{s}\"}}}}\n",
        .{before_text},
    );
    defer allocator.free(line1);
    const line2 = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"assistant\",\"timestamp\":\"2026-09-16T10:00:01Z\",\"sessionId\":\"s1\",\"message\":{{\"stop_reason\":\"end_turn\",\"content\":\"{s}\"}}}}\n",
        .{huge.items},
    );
    defer allocator.free(line2);
    const line3 = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"user\",\"timestamp\":\"2026-09-16T10:00:02Z\",\"sessionId\":\"s1\",\"message\":{{\"content\":\"{s}\"}}}}\n",
        .{after_text},
    );
    defer allocator.free(line3);
    const source = try std.mem.concat(allocator, u8, &.{ line1, line2, line3 });
    defer allocator.free(source);
    try writeTestFile(io, path, source);

    const claim = IndexedClaim{
        .file_path = path,
        .line_number = 2,
        .role = "assistant",
        .content = huge.items,
        .timestamp = "2026-09-16T10:00:01Z",
        .session_id = "s1",
    };
    var verified = try verifyIndexedClaim(allocator, io, claim, .claude);
    defer verified.deinit(allocator);
    const reference = try encodeReference(allocator, claim, .claude, verified);
    defer allocator.free(reference);

    var reconstructed = std.ArrayListUnmanaged(u8).empty;
    defer reconstructed.deinit(allocator);
    var seen_chunks = std.StringHashMapUnmanaged(void).empty;
    defer {
        var keys = seen_chunks.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        seen_chunks.deinit(allocator);
    }
    var cursor: ?[]u8 = null;
    defer if (cursor) |value| allocator.free(value);
    var pages: usize = 0;
    while (true) {
        const page = try expandReference(allocator, io, reference, 1, 1, cursor, 1800);
        defer allocator.free(page);
        try std.testing.expect(page.len <= 1800);
        _ = try std.unicode.Utf8View.init(page);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, page, .{});
        defer parsed.deinit();
        const root_obj = parsed.value.object;
        try std.testing.expectEqual(@as(i64, @intCast(page.len)), root_obj.get("serialized_bytes").?.integer);
        for (root_obj.get("messages").?.array.items) |item| {
            const obj = item.object;
            const chunk = obj.get("chunk").?.object;
            const key = try std.fmt.allocPrint(allocator, "{d}:{d}", .{
                obj.get("line").?.integer,
                chunk.get("content_start").?.integer,
            });
            if (seen_chunks.contains(key)) {
                allocator.free(key);
                return error.DuplicateExpansionChunk;
            }
            try seen_chunks.put(allocator, key, {});
            try reconstructed.appendSlice(allocator, chunk.get("text").?.string);
        }
        if (cursor) |value| allocator.free(value);
        cursor = null;
        const next = root_obj.get("continuation").?;
        if (next == .null) break;
        cursor = try allocator.dupe(u8, next.string);
        pages += 1;
        if (pages > 20) return error.ExpansionDidNotTerminate;
    }

    const expected = try std.mem.concat(allocator, u8, &.{ before_text, huge.items, after_text });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, reconstructed.items);
    try std.testing.expect(pages >= 2);
}

test "continuation invalidates when its next raw message changes after the anchor" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmpdir = runtime.getEnvVarOwned(allocator, "TMPDIR") catch try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmpdir);
    var namespace: u8 = 0;
    const root = try std.fmt.allocPrint(allocator, "{s}/chatscan-cursor-change-{x}", .{ tmpdir, @intFromPtr(&namespace) });
    defer allocator.free(root);
    const path = try std.fmt.allocPrint(allocator, "{s}/session.jsonl", .{root});
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var large = std.ArrayListUnmanaged(u8).empty;
    defer large.deinit(allocator);
    for (0..2400) |_| try large.append(allocator, 'a');
    const anchor_line = "{\"type\":\"user\",\"sessionId\":\"cursor-session\",\"message\":{\"content\":\"anchor\"}}\n";
    const later_line = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"assistant\",\"sessionId\":\"cursor-session\",\"message\":{{\"stop_reason\":\"end_turn\",\"content\":\"{s}\"}}}}\n",
        .{large.items},
    );
    defer allocator.free(later_line);
    const source = try std.mem.concat(allocator, u8, &.{ anchor_line, later_line });
    defer allocator.free(source);
    try writeTestFile(io, path, source);
    const claim = IndexedClaim{
        .file_path = path,
        .line_number = 1,
        .role = "user",
        .content = "anchor",
        .session_id = "cursor-session",
    };
    var verified = try verifyIndexedClaim(allocator, io, claim, .claude);
    defer verified.deinit(allocator);
    const reference = try encodeReference(allocator, claim, .claude, verified);
    defer allocator.free(reference);

    const first_page = try expandReference(allocator, io, reference, 0, 1, null, 1400);
    defer allocator.free(first_page);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, first_page, .{});
    defer parsed.deinit();
    const cursor = parsed.value.object.get("continuation").?.string;
    try std.testing.expect(cursor.len > 0);

    large.items[0] = 'b';
    const changed_line = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"assistant\",\"sessionId\":\"cursor-session\",\"message\":{{\"stop_reason\":\"end_turn\",\"content\":\"{s}\"}}}}\n",
        .{large.items},
    );
    defer allocator.free(changed_line);
    const changed_source = try std.mem.concat(allocator, u8, &.{ anchor_line, changed_line });
    defer allocator.free(changed_source);
    try writeTestFile(io, path, changed_source);
    try std.testing.expectError(error.CursorInvalidated, expandReference(allocator, io, reference, 0, 1, cursor, 1400));
}

test "recall JSON is valid UTF-8 and its final serialized bytes stay within budget" {
    const allocator = std.testing.allocator;
    var oversized: [4096]u8 = undefined;
    @memset(&oversized, 'x');
    const marked = "prefix é ◆ \\\"quoted\\\" needle 漢字 ";
    @memcpy(oversized[0..marked.len], marked);

    const hits = [_]VerifiedHit{.{
        .reference = "csr1:test-reference",
        .role = "assistant",
        .content = &oversized,
        .timestamp = "2026-09-16T17:00:00-04:00",
        .source = "codex",
        .session_id = "session-1",
        .project = "/home/p/Code/example",
        .file_path = "/home/p/.codex/sessions/2026/09/16/session.jsonl",
        .line_number = 42,
        .content_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .source_prefix_sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .source_prefix_bytes = 9001,
    }};

    const max_bytes = 1200;
    const rendered = try renderRecall(allocator, .{
        .query = "needle",
        .project = "/home/p/Code/example",
        .session_id = "session-1",
        .total_index_matches = 1,
    }, &hits, max_bytes);
    defer allocator.free(rendered);

    try std.testing.expect(rendered.len <= max_bytes);
    try std.testing.expectEqual(@as(u8, '\n'), rendered[rendered.len - 1]);
    _ = try std.unicode.Utf8View.init(rendered);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("chatscan/recall-v1", root.get("schema").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(rendered.len)), root.get("serialized_bytes").?.integer);
    const results = root.get("results").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), results.len);
    const excerpt = results[0].object.get("excerpt").?.object;
    const text = excerpt.get("text").?.string;
    try std.testing.expect(std.mem.indexOf(u8, text, "needle") != null);
    try std.testing.expect(text.len < oversized.len);
    try std.testing.expectEqual(@as(i64, oversized.len), excerpt.get("content_bytes").?.integer);
}
