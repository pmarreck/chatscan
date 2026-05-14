const std = @import("std");

pub const MAX_EXPANSION_DEPTH: u8 = 10;

/// Expand environment-variable references in `input`.
///
/// Supported forms:
///   $$            literal $
///   $VAR          simple reference ([A-Za-z_][A-Za-z0-9_]*)
///   ${VAR}        braced reference
///   ${VAR:-DEF}   default on unset OR empty
///   ${VAR-DEF}    default on unset only (empty is kept)
///
/// DEF may itself contain nested references up to MAX_EXPANSION_DEPTH.
/// Undefined references without a default expand to empty string.
/// Unterminated `${` passes through literally.
///
/// Returns an owned slice. Caller frees.
pub fn expandEnvVars(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try expandInto(allocator, &out, input, 0);
    return out.toOwnedSlice(allocator);
}

const ExpandError = error{OutOfMemory};

fn expandInto(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    input: []const u8,
    depth: u8,
) ExpandError!void {
    if (depth > MAX_EXPANSION_DEPTH) return; // Runaway recursion guard

    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c != '$') {
            try out.append(allocator, c);
            i += 1;
            continue;
        }

        // Look at next char
        if (i + 1 >= input.len) {
            try out.append(allocator, c);
            i += 1;
            continue;
        }

        const next = input[i + 1];

        if (next == '$') {
            try out.append(allocator, '$');
            i += 2;
            continue;
        }

        if (next == '{') {
            const close = findMatchingBrace(input, i) orelse {
                // Unterminated ${ — pass through literally
                try out.append(allocator, c);
                i += 1;
                continue;
            };

            const body_start = i + 2;
            const body = input[body_start..close];
            try expandBracedRef(allocator, out, body, depth);
            i = close + 1;
            continue;
        }

        if (isNameStart(next)) {
            var j = i + 1;
            while (j < input.len and isNameChar(input[j])) : (j += 1) {}
            const name = input[i + 1 .. j];
            if (getEnvVar(allocator, name)) |val| {
                defer allocator.free(val);
                try out.appendSlice(allocator, val);
            } else |_| {}
            i = j;
            continue;
        }

        // Bare $ followed by something else (digit, symbol) — pass through literally
        try out.append(allocator, c);
        i += 1;
    }
}

fn expandBracedRef(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    body: []const u8,
    depth: u8,
) ExpandError!void {
    // Find `:-` or `-` separator at brace-depth 0
    var sep_idx: ?usize = null;
    var has_colon: bool = false;
    {
        var bd: isize = 0;
        var k: usize = 0;
        while (k < body.len) : (k += 1) {
            const c = body[k];
            if (c == '$' and k + 1 < body.len and body[k + 1] == '{') {
                bd += 1;
                k += 1;
                continue;
            }
            if (c == '}') {
                bd -= 1;
                continue;
            }
            if (bd != 0) continue;
            if (c == ':' and k + 1 < body.len and body[k + 1] == '-') {
                sep_idx = k;
                has_colon = true;
                break;
            }
            if (c == '-' and k > 0) {
                sep_idx = k;
                has_colon = false;
                break;
            }
        }
    }

    const name_end = sep_idx orelse body.len;
    const name = body[0..name_end];

    const val_opt = getEnvVar(allocator, name) catch null;
    defer if (val_opt) |v| allocator.free(v);

    const use_default = if (sep_idx == null) blk: {
        // No default specified
        if (val_opt) |v| {
            try out.appendSlice(allocator, v);
        }
        break :blk false;
    } else blk: {
        if (has_colon) {
            // ${VAR:-DEF} — default fires on unset OR empty
            break :blk (val_opt == null or val_opt.?.len == 0);
        } else {
            // ${VAR-DEF} — default fires on unset only
            break :blk (val_opt == null);
        }
    };

    if (sep_idx == null) return;

    if (!use_default) {
        if (val_opt) |v| try out.appendSlice(allocator, v);
        return;
    }

    const def_offset = if (has_colon) sep_idx.? + 2 else sep_idx.? + 1;
    const def_raw = body[def_offset..];
    // Recursively expand default
    try expandInto(allocator, out, def_raw, depth + 1);
}

fn findMatchingBrace(input: []const u8, start: usize) ?usize {
    // input[start] == '$' and input[start+1] == '{'
    var depth: usize = 1;
    var j = start + 2;
    while (j < input.len) : (j += 1) {
        if (input[j] == '$' and j + 1 < input.len and input[j + 1] == '{') {
            depth += 1;
            j += 1;
        } else if (input[j] == '}') {
            depth -= 1;
            if (depth == 0) return j;
        }
    }
    return null;
}

fn isNameStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}

fn isNameChar(c: u8) bool {
    return isNameStart(c) or (c >= '0' and c <= '9');
}

fn getEnvVar(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const runtime = @import("runtime.zig");
    return runtime.getEnvVarOwned(allocator, name);
}

/// Returns true if the string contains any `$VAR` or `${VAR}` reference
/// (ignoring escaped `$$`).
pub fn hasEnvRef(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '$') continue;
        if (i + 1 >= s.len) return false;
        const next = s[i + 1];
        if (next == '$') {
            i += 1;
            continue;
        }
        if (next == '{') return true;
        if (isNameStart(next)) return true;
    }
    return false;
}

// -- Tests -----------------------------------------------------------------

const testing = std.testing;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn setEnv(name: [:0]const u8, value: [:0]const u8) void {
    _ = setenv(name.ptr, value.ptr, 1);
}

fn unsetEnv(name: [:0]const u8) void {
    _ = unsetenv(name.ptr);
}

test "expand ${VAR} when set" {
    setEnv("CHATSCAN_TEST_VAR", "hello");
    defer unsetEnv("CHATSCAN_TEST_VAR");

    const got = try expandEnvVars(testing.allocator, "x=${CHATSCAN_TEST_VAR}");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("x=hello", got);
}

test "expand ${VAR} when unset yields empty" {
    unsetEnv("CHATSCAN_TEST_UNSET");
    const got = try expandEnvVars(testing.allocator, "x=${CHATSCAN_TEST_UNSET}");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("x=", got);
}

test "expand $VAR without braces" {
    setEnv("CHATSCAN_TEST_VAR2", "world");
    defer unsetEnv("CHATSCAN_TEST_VAR2");

    const got = try expandEnvVars(testing.allocator, "hi $CHATSCAN_TEST_VAR2!");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hi world!", got);
}

test "colon-dash default fires on unset" {
    unsetEnv("CHATSCAN_TEST_COLON_UNSET");
    const got = try expandEnvVars(testing.allocator, "${CHATSCAN_TEST_COLON_UNSET:-fallback}");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("fallback", got);
}

test "colon-dash default fires on empty" {
    setEnv("CHATSCAN_TEST_EMPTY", "");
    defer unsetEnv("CHATSCAN_TEST_EMPTY");

    const got = try expandEnvVars(testing.allocator, "${CHATSCAN_TEST_EMPTY:-fallback}");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("fallback", got);
}

test "colon-dash set value wins over default" {
    setEnv("CHATSCAN_TEST_SET", "actual");
    defer unsetEnv("CHATSCAN_TEST_SET");

    const got = try expandEnvVars(testing.allocator, "${CHATSCAN_TEST_SET:-fallback}");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("actual", got);
}

test "bare dash keeps empty value (does not fire default)" {
    setEnv("CHATSCAN_TEST_BARE_EMPTY", "");
    defer unsetEnv("CHATSCAN_TEST_BARE_EMPTY");

    const got = try expandEnvVars(testing.allocator, "x=${CHATSCAN_TEST_BARE_EMPTY-fallback}y");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("x=y", got);
}

test "bare dash fires on unset" {
    unsetEnv("CHATSCAN_TEST_BARE_UNSET");
    const got = try expandEnvVars(testing.allocator, "${CHATSCAN_TEST_BARE_UNSET-fallback}");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("fallback", got);
}

test "nested default resolves innermost" {
    unsetEnv("CHATSCAN_A");
    unsetEnv("CHATSCAN_B");
    unsetEnv("CHATSCAN_C");

    const got = try expandEnvVars(testing.allocator, "${CHATSCAN_A:-${CHATSCAN_B:-${CHATSCAN_C:-bottom}}}");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("bottom", got);
}

test "nested middle layer wins when set" {
    unsetEnv("CHATSCAN_A");
    setEnv("CHATSCAN_B", "middle");
    defer unsetEnv("CHATSCAN_B");
    unsetEnv("CHATSCAN_C");

    const got = try expandEnvVars(testing.allocator, "${CHATSCAN_A:-${CHATSCAN_B:-${CHATSCAN_C:-bottom}}}");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("middle", got);
}

test "runaway recursion does not hang" {
    // Even if MY_VAR=${MY_VAR} somehow got into a default, depth guard stops it
    const got = try expandEnvVars(testing.allocator, "${UNDEF:-${UNDEF:-${UNDEF:-${UNDEF:-${UNDEF:-${UNDEF:-${UNDEF:-${UNDEF:-${UNDEF:-${UNDEF:-${UNDEF:-deep}}}}}}}}}}}");
    defer testing.allocator.free(got);
    // Over max depth — expansion stops, which is fine (bounded behavior)
    // Just assert we got *something* and didn't hang
    try testing.expect(got.len < 100);
}

test "unterminated brace passes through literally" {
    const got = try expandEnvVars(testing.allocator, "x=${UNTERMINATED");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("x=${UNTERMINATED", got);
}

test "double-dollar is literal dollar" {
    const got = try expandEnvVars(testing.allocator, "price=$$5");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("price=$5", got);
}

test "hasEnvRef detects references" {
    try testing.expect(hasEnvRef("${VAR}"));
    try testing.expect(hasEnvRef("$VAR"));
    try testing.expect(!hasEnvRef("plain text"));
    try testing.expect(!hasEnvRef("$$ is literal"));
    try testing.expect(!hasEnvRef("$5 is numeric"));
}
