const std = @import("std");
const ollama = @import("ollama.zig");

// Reuse Transport interface from ollama.zig — same HTTP shape.
pub const Transport = ollama.Transport;
pub const HttpRequest = ollama.HttpRequest;
pub const HttpResponse = ollama.HttpResponse;

/// POST /v1/embeddings — OpenAI-compatible embedding API.
/// Also supported by oMLX and other local servers running in OpenAI mode.
pub fn embed(
    allocator: std.mem.Allocator,
    transport: Transport,
    base_url: []const u8,
    api_key: ?[]const u8,
    model: []const u8,
    inputs: []const []const u8,
) ![][]f32 {
    const url = try buildEmbedUrl(allocator, base_url);
    defer allocator.free(url);
    const body = try buildEmbedRequest(allocator, model, inputs);
    defer allocator.free(body);

    // Build headers — include Authorization only if api_key is provided
    var auth_header_buf: [512]u8 = undefined;
    const has_auth = api_key != null and api_key.?.len > 0;
    const auth_value = if (has_auth)
        try std.fmt.bufPrint(&auth_header_buf, "Bearer {s}", .{api_key.?})
    else
        "";

    if (has_auth) {
        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "Authorization", .value = auth_value },
        };
        return sendAndParse(allocator, transport, url, &headers, body);
    } else {
        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "application/json" },
        };
        return sendAndParse(allocator, transport, url, &headers, body);
    }
}

fn sendAndParse(
    allocator: std.mem.Allocator,
    transport: Transport,
    url: []const u8,
    headers: []const std.http.Header,
    body: []const u8,
) ![][]f32 {
    const response = try transport.send(transport.ctx, allocator, .{
        .method = "POST",
        .url = url,
        .headers = headers,
        .body = body,
    });
    defer allocator.free(response.body);

    if (response.status != 200) return error.HttpStatus;
    return parseEmbeddings(allocator, response.body);
}

pub fn buildEmbedUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    // Handle both "http://host:port" and "http://host:port/v1" as base_url
    const stripped = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.endsWith(u8, stripped, "/v1")) {
        return std.fmt.allocPrint(allocator, "{s}/embeddings", .{stripped});
    }
    return std.fmt.allocPrint(allocator, "{s}/v1/embeddings", .{stripped});
}

pub fn buildEmbedRequest(
    allocator: std.mem.Allocator,
    model: []const u8,
    inputs: []const []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll("{\"model\":");
    try writeJsonString(w, model);
    try w.writeAll(",\"input\":[");
    for (inputs, 0..) |input, i| {
        if (i > 0) try w.writeAll(",");
        try writeJsonString(w, input);
    }
    try w.writeAll("],\"encoding_format\":\"float\"}");
    return out.toOwnedSlice();
}

fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeAll("\"");
}

/// OpenAI response format:
/// {"data":[{"embedding":[...], "index":0}, ...], ...}
pub fn parseEmbeddings(allocator: std.mem.Allocator, body: []const u8) ![][]f32 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidResponse;
    const data_value = parsed.value.object.get("data") orelse return error.MissingData;
    if (data_value != .array) return error.InvalidData;

    const rows = data_value.array.items;
    var result = try allocator.alloc([]f32, rows.len);
    var filled: usize = 0;
    errdefer {
        for (result[0..filled]) |row| allocator.free(row);
        allocator.free(result);
    }

    for (rows) |row| {
        if (row != .object) return error.InvalidData;
        const embedding_value = row.object.get("embedding") orelse return error.MissingEmbedding;
        if (embedding_value != .array) return error.InvalidEmbedding;

        // Use the "index" field if present to place the vector at the right position
        var idx: usize = filled;
        if (row.object.get("index")) |index_value| {
            if (index_value == .integer) {
                idx = @intCast(index_value.integer);
            }
        }
        if (idx >= rows.len) return error.InvalidIndex;

        const values = embedding_value.array.items;
        var vec = try allocator.alloc(f32, values.len);
        for (values, 0..) |value, col_idx| {
            vec[col_idx] = try parseNumber(value);
        }
        result[idx] = vec;
        filled += 1;
    }

    return result;
}

pub fn freeEmbeddings(allocator: std.mem.Allocator, embeddings: [][]f32) void {
    for (embeddings) |row| allocator.free(row);
    allocator.free(embeddings);
}

fn parseNumber(value: std.json.Value) !f32 {
    switch (value) {
        .integer => |v| return @floatFromInt(v),
        .float => |v| return @floatCast(v),
        else => return error.InvalidEmbedding,
    }
}

// -- Tests -----------------------------------------------------------------

const testing = std.testing;

test "buildEmbedUrl appends /v1/embeddings" {
    const allocator = testing.allocator;
    const url = try buildEmbedUrl(allocator, "http://localhost:8080");
    defer allocator.free(url);
    try testing.expectEqualStrings("http://localhost:8080/v1/embeddings", url);
}

test "buildEmbedUrl preserves existing /v1 prefix" {
    const allocator = testing.allocator;
    const url = try buildEmbedUrl(allocator, "http://localhost:8080/v1");
    defer allocator.free(url);
    try testing.expectEqualStrings("http://localhost:8080/v1/embeddings", url);
}

test "buildEmbedRequest serializes inputs as strings" {
    const allocator = testing.allocator;
    const inputs = [_][]const u8{ "hello", "world" };
    const body = try buildEmbedRequest(allocator, "text-embedding-3-small", &inputs);
    defer allocator.free(body);
    try testing.expectEqualStrings(
        "{\"model\":\"text-embedding-3-small\",\"input\":[\"hello\",\"world\"],\"encoding_format\":\"float\"}",
        body,
    );
}

test "parseEmbeddings reads OpenAI response" {
    const allocator = testing.allocator;
    const body =
        \\{"object":"list","data":[{"object":"embedding","index":0,"embedding":[0.1,0.2]},{"object":"embedding","index":1,"embedding":[0.3,0.4]}]}
    ;
    const embeddings = try parseEmbeddings(allocator, body);
    defer freeEmbeddings(allocator, embeddings);
    try testing.expectEqual(@as(usize, 2), embeddings.len);
    try testing.expectApproxEqAbs(@as(f32, 0.1), embeddings[0][0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.4), embeddings[1][1], 0.0001);
}

test "parseEmbeddings respects out-of-order index field" {
    const allocator = testing.allocator;
    // index=1 appears first, index=0 second
    const body =
        \\{"data":[{"index":1,"embedding":[9.0]},{"index":0,"embedding":[1.0]}]}
    ;
    const embeddings = try parseEmbeddings(allocator, body);
    defer freeEmbeddings(allocator, embeddings);
    try testing.expectEqual(@as(usize, 2), embeddings.len);
    try testing.expectApproxEqAbs(@as(f32, 1.0), embeddings[0][0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 9.0), embeddings[1][0], 0.0001);
}

const MockTransportCtx = struct {
    expected_auth: ?[]const u8 = null,
    response_body: []const u8,
    status: u16 = 200,
    observed_auth: ?[]const u8 = null,
    observed_body: []const u8 = "",
    allocator: std.mem.Allocator,

    fn send(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, req: HttpRequest) !HttpResponse {
        const self: *MockTransportCtx = @ptrCast(@alignCast(ctx_ptr));
        for (req.headers) |h| {
            if (std.mem.eql(u8, h.name, "Authorization")) {
                self.observed_auth = self.allocator.dupe(u8, h.value) catch null;
            }
        }
        self.observed_body = self.allocator.dupe(u8, req.body) catch "";
        return .{ .status = self.status, .body = try allocator.dupe(u8, self.response_body) };
    }

    fn transport(self: *MockTransportCtx) Transport {
        return .{ .ctx = self, .send = send };
    }
};

test "embed sends Authorization header when api_key provided" {
    const allocator = testing.allocator;
    var mock = MockTransportCtx{
        .response_body = "{\"data\":[{\"index\":0,\"embedding\":[1.0]}]}",
        .allocator = allocator,
    };
    defer {
        if (mock.observed_auth) |a| allocator.free(a);
        if (mock.observed_body.len > 0) allocator.free(mock.observed_body);
    }

    const inputs = [_][]const u8{"hello"};
    const embeddings = try embed(allocator, mock.transport(), "http://localhost:8080", "sk-test-123", "test-model", &inputs);
    defer freeEmbeddings(allocator, embeddings);

    try testing.expect(mock.observed_auth != null);
    try testing.expectEqualStrings("Bearer sk-test-123", mock.observed_auth.?);
}

test "embed omits Authorization header when api_key is null" {
    const allocator = testing.allocator;
    var mock = MockTransportCtx{
        .response_body = "{\"data\":[{\"index\":0,\"embedding\":[1.0]}]}",
        .allocator = allocator,
    };
    defer {
        if (mock.observed_auth) |a| allocator.free(a);
        if (mock.observed_body.len > 0) allocator.free(mock.observed_body);
    }

    const inputs = [_][]const u8{"hello"};
    const embeddings = try embed(allocator, mock.transport(), "http://localhost:8080", null, "test-model", &inputs);
    defer freeEmbeddings(allocator, embeddings);

    try testing.expect(mock.observed_auth == null);
}
