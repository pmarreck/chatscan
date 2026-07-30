const std = @import("std");
const indexer = @import("indexer.zig");
const storage = @import("storage.zig");
const embedding = @import("embedding.zig");
const config = @import("config.zig");
const retirement = @import("retirement.zig");
const runtime = @import("runtime.zig");

pub const WatchOptions = struct {
    interval_ms: u64 = 2000,
    llm: config.LlmSource = .claude,
    batch_size: usize = 16,
    /// How long the watcher may sit idle (no index activity) before standing
    /// down. Null never retires — a supervised service unit needs that.
    idle_limit_ns: ?u64 = null,
    /// Injected wall clock, so retirement is exercised without waiting.
    now_fn: *const fn () i128 = systemNowNs,
};

/// Default clock for `WatchOptions.now_fn`.
pub fn systemNowNs() i128 {
    return @intCast(std.Io.Timestamp.now(runtime.io(), .real).nanoseconds);
}

/// Retirement bookkeeping for the watch loop. Owns the idle origin and the
/// in-progress flag so a retirement decision can never land mid-index; only a
/// pass that actually changed the index resets the idle countdown.
const RetirementTracker = struct {
    options: WatchOptions,
    started_ns: i128,
    last_activity_ns: ?i128 = null,
    index_in_progress: bool = false,

    fn init(options: WatchOptions) RetirementTracker {
        return .{ .options = options, .started_ns = options.now_fn() };
    }

    fn beginIndex(self: *RetirementTracker) void {
        self.index_in_progress = true;
    }

    /// chatscan's IndexStats doesn't split new vs modified; files_indexed covers
    /// both, files_deleted covers removals and ignored-file purges.
    fn endIndex(self: *RetirementTracker, stats: indexer.IndexStats) void {
        self.index_in_progress = false;
        if (retirement.countsAsActivity(.{
            .new_files = stats.files_indexed,
            .deleted_files = stats.files_deleted,
        })) {
            self.last_activity_ns = self.options.now_fn();
        }
    }

    fn abandonIndex(self: *RetirementTracker) void {
        self.index_in_progress = false;
    }

    fn decide(self: *const RetirementTracker) retirement.Decision {
        return retirement.shouldRetire(.{
            .now_ns = self.options.now_fn(),
            .last_index_ns = self.last_activity_ns,
            .started_ns = self.started_ns,
            .idle_limit_ns = self.options.idle_limit_ns,
            .index_in_progress = self.index_in_progress,
        });
    }
};

fn announceRetirement(stderr: *std.Io.Writer, idle_limit_ns: u64) void {
    var buf: [64]u8 = undefined;
    const limit = retirement.formatIdleLimit(&buf, idle_limit_ns);
    _ = stderr.print("watcher: retiring after {s} with no index activity (--idle-timeout never disables)\n", .{limit}) catch {};
    _ = stderr.flush() catch {};
}

fn printChangeSummary(stderr: *std.Io.Writer, stats: indexer.IndexStats) void {
    if (stats.files_indexed == 0 and stats.files_deleted == 0) {
        _ = stderr.print("watcher: up to date ({d} files scanned)\n", .{stats.files_scanned}) catch {};
    } else {
        _ = stderr.print("watcher: ~{d} indexed, -{d} removed, {d} messages\n", .{ stats.files_indexed, stats.files_deleted, stats.messages_indexed }) catch {};
    }
    _ = stderr.flush() catch {};
}

/// Polling watch loop: re-runs the incremental index every interval and
/// self-terminates after the idle limit elapses with no activity. Blocks until
/// `stop` is set (by the SIGINT handler). Native fs-events are intentionally
/// skipped — polling mtimes keeps it identical across all target platforms, and
/// the underlying index scan already skips unchanged files by mtime.
pub fn watchLoop(
    allocator: std.mem.Allocator,
    db: storage.Db,
    conversation_dir: []const u8,
    embedder: ?embedding.Embedder,
    options: WatchOptions,
    stop: *const std.atomic.Value(bool),
    stderr: *std.Io.Writer,
) !void {
    _ = stderr.print("Watching {s} (poll every {d}ms, Ctrl-C to stop)\n", .{ conversation_dir, options.interval_ms }) catch {};
    _ = stderr.flush() catch {};

    var tracker = RetirementTracker.init(options);

    // Initial pass so the index is fresh the moment the watcher comes up.
    tracker.beginIndex();
    const initial = indexer.indexAllForLlm(allocator, db, conversation_dir, options.llm, embedder, options.batch_size, false, stderr) catch |err| {
        tracker.abandonIndex();
        return err;
    };
    tracker.endIndex(initial);
    printChangeSummary(stderr, initial);

    const max_consecutive_errors = 5;
    var consecutive_errors: u32 = 0;

    while (!stop.load(.acquire)) {
        runtime.io().sleep(std.Io.Duration.fromNanoseconds(options.interval_ms * std.time.ns_per_ms), .awake) catch {};
        if (stop.load(.acquire)) break;

        tracker.beginIndex();
        const stats = indexer.indexAllForLlm(allocator, db, conversation_dir, options.llm, embedder, options.batch_size, false, stderr) catch |err| {
            tracker.abandonIndex();
            consecutive_errors += 1;
            _ = stderr.print("watcher: index error: {s} ({d}/{d})\n", .{ @errorName(err), consecutive_errors, max_consecutive_errors }) catch {};
            _ = stderr.flush() catch {};
            if (consecutive_errors >= max_consecutive_errors) {
                _ = stderr.print("watcher: too many consecutive errors, stopping\n", .{}) catch {};
                _ = stderr.flush() catch {};
                return;
            }
            continue;
        };
        tracker.endIndex(stats);
        consecutive_errors = 0;

        if (stats.files_indexed > 0 or stats.files_deleted > 0) {
            printChangeSummary(stderr, stats);
        }

        // Decided outside the index call, so `index_in_progress` can never be
        // observed mid-pass.
        if (tracker.decide() == .retire) {
            announceRetirement(stderr, options.idle_limit_ns.?);
            return;
        }
    }
}

// --- tests ------------------------------------------------------------------

var test_clock_ns: i128 = 0;
fn testNow() i128 {
    return test_clock_ns;
}

test "RetirementTracker: retires after idle limit, resets on real activity, holds during an index" {
    test_clock_ns = 0;
    var tracker = RetirementTracker.init(.{ .idle_limit_ns = std.time.ns_per_hour, .now_fn = testNow });

    // 30 min in, no activity yet: origin is the watcher start (0), 30m < 1h.
    test_clock_ns = 30 * std.time.ns_per_min;
    try std.testing.expectEqual(retirement.Decision.keep_running, tracker.decide());

    // A pass that did real work resets the countdown at t=30m.
    tracker.beginIndex();
    tracker.endIndex(.{ .files_indexed = 2 });

    // 89 min: only 59m since the last activity -> keep running.
    test_clock_ns = 89 * std.time.ns_per_min;
    try std.testing.expectEqual(retirement.Decision.keep_running, tracker.decide());

    // 90 min: a full hour since the last activity -> retire.
    test_clock_ns = 90 * std.time.ns_per_min;
    try std.testing.expectEqual(retirement.Decision.retire, tracker.decide());

    // A no-op pass (nothing changed) must NOT reset the countdown.
    tracker.beginIndex();
    tracker.endIndex(.{ .files_scanned = 100, .files_indexed = 0, .files_deleted = 0 });
    try std.testing.expectEqual(retirement.Decision.retire, tracker.decide());

    // While an index is in progress, never retire (don't abandon partial work).
    tracker.beginIndex();
    try std.testing.expectEqual(retirement.Decision.keep_running, tracker.decide());
}

test "RetirementTracker: a null idle limit never retires" {
    test_clock_ns = 0;
    var tracker = RetirementTracker.init(.{ .idle_limit_ns = null, .now_fn = testNow });
    test_clock_ns = 1000 * std.time.ns_per_day;
    try std.testing.expectEqual(retirement.Decision.keep_running, tracker.decide());
}
