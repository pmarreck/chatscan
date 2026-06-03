//! Process-wide runtime context for Zig 0.16 migration.
//!
//! Zig 0.16 threaded `std.Io` and the environment map as explicit parameters
//! through most filesystem/process APIs. Rather than refactor every function
//! signature in chatscan, we capture the values once in `main` and expose them
//! as process-globals that other modules read directly.
//!
//! Initialised by `main()`; safe to read for the lifetime of the process.
//! During tests (where `main` does not run), `io()` lazily falls back to
//! `std.testing.io` and `getEnv` returns null (so env lookups behave as
//! "unset"), which matches typical test expectations.

const std = @import("std");
const builtin = @import("builtin");

var g_io: std.Io = undefined;
var g_env: ?*const std.process.Environ.Map = null;
var g_initialised: bool = false;

pub fn init(io_val: std.Io, env_val: *const std.process.Environ.Map) void {
    g_io = io_val;
    g_env = env_val;
    g_initialised = true;
}

pub fn io() std.Io {
    if (!g_initialised) {
        if (builtin.is_test) {
            return std.testing.io;
        }
        std.debug.panic("runtime.io() called before runtime.init()", .{});
    }
    return g_io;
}

pub fn env() *const std.process.Environ.Map {
    std.debug.assert(g_initialised);
    return g_env.?;
}

/// Convenience: borrowed env var lookup. Returns null if unset or runtime
/// has not been initialised (e.g. during tests).
pub fn getEnv(name: []const u8) ?[]const u8 {
    if (!g_initialised) {
        // During tests we still want env access to work for the few tests that
        // set vars via libc setenv. Fall back to libc getenv.
        if (builtin.is_test) {
            const name_z = std.heap.page_allocator.dupeZ(u8, name) catch return null;
            defer std.heap.page_allocator.free(name_z);
            const c_val = std.c.getenv(name_z.ptr) orelse return null;
            return std.mem.span(c_val);
        }
        return null;
    }
    if (g_env) |m| return m.get(name);
    return null;
}

/// 0.15-style API shim — returns an owned slice or
/// `error.EnvironmentVariableNotFound` to match the old signature.
pub const GetEnvVarError = error{ EnvironmentVariableNotFound, OutOfMemory };
pub fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) GetEnvVarError![]u8 {
    const v = getEnv(name) orelse return error.EnvironmentVariableNotFound;
    return try allocator.dupe(u8, v);
}

/// Return an owned copy of env var `key`, or an owned copy of `fallback`
/// when it is unset. Caller owns the returned slice.
pub fn envOrDefault(allocator: std.mem.Allocator, key: []const u8, fallback: []const u8) ![]u8 {
    return getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return allocator.dupe(u8, fallback),
        else => return err,
    };
}

/// 0.15-style shim for `file.readToEndAlloc(allocator, max)`.
/// Returns owned slice limited to `max` bytes.
pub fn readToEndAlloc(file: std.Io.File, allocator: std.mem.Allocator, max: usize) ![]u8 {
    var buf: [4096]u8 = undefined;
    var r = file.reader(io(), &buf);
    return r.interface.allocRemaining(allocator, .limited(max));
}

/// Helper: `std.Io.File.stdin()` value bound to the singleton io.
pub fn stdin() std.Io.File {
    return std.Io.File.stdin();
}

pub fn stdout() std.Io.File {
    return std.Io.File.stdout();
}

pub fn stderr() std.Io.File {
    return std.Io.File.stderr();
}
