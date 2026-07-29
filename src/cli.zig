const std = @import("std");
const search = @import("search.zig");
const config = @import("config.zig");

pub const OutputFormat = enum {
    human,
    json,
};

pub const CommandTag = enum {
    help,
    about,
    index,
    search,
    config,
    rename,
};

pub const ConfigAction = enum {
    show,
    edit,
};

pub const Seen = struct {
    top_n: bool = false,
    db_path: bool = false,
    ollama_url: bool = false,
    ollama_model: bool = false,
    embedding_dim: bool = false,
    conversation_dir: bool = false,
    search_mode: bool = false,
    project: bool = false,
    embedding_backend: bool = false,
    embedding_url: bool = false,
    embedding_model: bool = false,
    embedding_api_key: bool = false,
};

/// Validate a "YYYY-MM-DD" date string (the granularity chatscan filters on).
/// Checks length, dash positions, digit classes, and basic month/day ranges.
fn isValidDate(s: []const u8) bool {
    if (s.len != 10) return false;
    if (s[4] != '-' or s[7] != '-') return false;
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9 }) |idx| {
        if (s[idx] < '0' or s[idx] > '9') return false;
    }
    const month = (s[5] - '0') * 10 + (s[6] - '0');
    const day = (s[8] - '0') * 10 + (s[9] - '0');
    if (month < 1 or month > 12) return false;
    if (day < 1 or day > 31) return false;
    return true;
}

pub const Parsed = struct {
    command: CommandTag = .search,
    assumed_search: bool = false,
    help_topic: ?[]const u8 = null,
    config_action: ConfigAction = .show,

    // Search options
    query: ?[]const u8 = null,
    query_owned: ?[]u8 = null,
    top_n: usize = 10,
    output: OutputFormat = .human,
    search_mode: search.SearchMode = .hybrid,
    role_filter: ?[]const u8 = null,
    context_lines: usize = 4,
    all_projects: bool = false,
    project: ?[]const u8 = null,
    since: ?[]const u8 = null,
    until: ?[]const u8 = null,
    regex_mode: bool = false,
    reindex: bool = false,
    force: bool = false,
    llm_source: ?config.LlmSource = null,
    weight_vector: ?f32 = null,
    weight_lexical: ?f32 = null,
    weight_recency: ?f32 = null,

    // Rename args
    rename_old: ?[]const u8 = null,
    rename_new: ?[]const u8 = null,

    // Global
    db_path: ?[]const u8 = null,
    ollama_url: ?[]const u8 = null,
    ollama_model: ?[]const u8 = null,
    embedding_dim: ?usize = null,
    conversation_dir: ?[]const u8 = null,
    embedding_backend: ?config.EmbeddingBackend = null,
    embedding_url: ?[]const u8 = null,
    embedding_model: ?[]const u8 = null,
    embedding_api_key: ?[]const u8 = null,

    seen: Seen = .{},

    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        if (self.query_owned) |q| allocator.free(q);
        self.query_owned = null;
    }
};

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) !Parsed {
    var parsed = Parsed{};
    if (args.len <= 1) return parsed;

    var query_parts = std.ArrayListUnmanaged([]const u8).empty;
    defer query_parts.deinit(allocator);

    var i: usize = 1;
    var verb_seen = false;

    while (i < args.len) {
        const arg = args[i];

        // Flags
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                parsed.command = .help;
                i += 1;
                if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
                    parsed.help_topic = args[i];
                    i += 1;
                }
                continue;
            }
            if (std.mem.eql(u8, arg, "--about")) {
                parsed.command = .about;
                return parsed;
            }
            if (std.mem.eql(u8, arg, "--json")) {
                parsed.output = .json;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--top")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                parsed.top_n = try std.fmt.parseInt(usize, args[i], 10);
                parsed.seen.top_n = true;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--all") or std.mem.eql(u8, arg, "-a")) {
                parsed.all_projects = true;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--project") or std.mem.eql(u8, arg, "-p")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                parsed.project = args[i];
                parsed.seen.project = true;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--role")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                const val = args[i];
                if (!std.mem.eql(u8, val, "user") and !std.mem.eql(u8, val, "assistant")) {
                    return error.InvalidRole;
                }
                parsed.role_filter = val;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--since") or std.mem.eql(u8, arg, "--after")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                if (!isValidDate(args[i])) return error.InvalidDate;
                parsed.since = args[i];
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--until") or std.mem.eql(u8, arg, "--before")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                if (!isValidDate(args[i])) return error.InvalidDate;
                parsed.until = args[i];
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--date") or std.mem.eql(u8, arg, "--on")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                if (!isValidDate(args[i])) return error.InvalidDate;
                parsed.since = args[i];
                parsed.until = args[i];
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--regex") or std.mem.eql(u8, arg, "--re") or std.mem.eql(u8, arg, "--regexp")) {
                parsed.regex_mode = true;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--reindex") or std.mem.eql(u8, arg, "--force-reindex")) {
                parsed.reindex = true;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
                parsed.force = true;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--llm")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                parsed.llm_source = config.LlmSource.parse(args[i]) catch return error.InvalidLlmSource;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--weight-vector")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                parsed.weight_vector = std.fmt.parseFloat(f32, args[i]) catch return error.InvalidWeight;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--weight-lexical")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                parsed.weight_lexical = std.fmt.parseFloat(f32, args[i]) catch return error.InvalidWeight;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--weight-recency")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                parsed.weight_recency = std.fmt.parseFloat(f32, args[i]) catch return error.InvalidWeight;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--all-llms")) {
                parsed.llm_source = .all;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--context-lines")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                parsed.context_lines = try std.fmt.parseInt(usize, args[i], 10);
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--mode")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                parsed.search_mode = try search.SearchMode.parse(args[i]);
                parsed.seen.search_mode = true;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--db")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                parsed.db_path = args[i];
                parsed.seen.db_path = true;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--ollama-url")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                parsed.ollama_url = args[i];
                parsed.seen.ollama_url = true;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--ollama-model")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                parsed.ollama_model = args[i];
                parsed.seen.ollama_model = true;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--embedding-dim")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                parsed.embedding_dim = try std.fmt.parseInt(usize, args[i], 10);
                parsed.seen.embedding_dim = true;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--conversation-dir")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                parsed.conversation_dir = args[i];
                parsed.seen.conversation_dir = true;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--backend") or std.mem.eql(u8, arg, "--embedding-backend")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                parsed.embedding_backend = config.EmbeddingBackend.parse(args[i]) catch return error.InvalidBackend;
                parsed.seen.embedding_backend = true;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--embedding-url")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                parsed.embedding_url = args[i];
                parsed.seen.embedding_url = true;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--embedding-model")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                parsed.embedding_model = args[i];
                parsed.seen.embedding_model = true;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--embedding-api-key")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                parsed.embedding_api_key = args[i];
                parsed.seen.embedding_api_key = true;
                i += 1;
                continue;
            }
            return error.UnknownFlag;
        }

        // Commands
        if (!verb_seen) {
            if (std.mem.eql(u8, arg, "help")) {
                parsed.command = .help;
                verb_seen = true;
                i += 1;
                if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
                    parsed.help_topic = args[i];
                    i += 1;
                }
                continue;
            }
            if (std.mem.eql(u8, arg, "index")) {
                parsed.command = .index;
                verb_seen = true;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "search") or std.mem.eql(u8, arg, "query")) {
                parsed.command = .search;
                verb_seen = true;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "config")) {
                parsed.command = .config;
                verb_seen = true;
                i += 1;
                if (i < args.len) {
                    if (std.mem.eql(u8, args[i], "edit")) {
                        parsed.config_action = .edit;
                        i += 1;
                    } else if (std.mem.eql(u8, args[i], "show")) {
                        parsed.config_action = .show;
                        i += 1;
                    }
                }
                continue;
            }
            if (std.mem.eql(u8, arg, "rename")) {
                parsed.command = .rename;
                verb_seen = true;
                i += 1;
                // Next two positional args are old and new paths
                if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
                    parsed.rename_old = args[i];
                    i += 1;
                }
                if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
                    parsed.rename_new = args[i];
                    i += 1;
                }
                continue;
            }
        }

        // Accumulate as query token
        try query_parts.append(allocator, arg);
        if (!verb_seen) {
            parsed.assumed_search = true;
            verb_seen = true;
        }
        i += 1;
    }

    // Join query parts
    if (query_parts.items.len > 0) {
        var total_len: usize = 0;
        for (query_parts.items, 0..) |part, idx| {
            total_len += part.len;
            if (idx < query_parts.items.len - 1) total_len += 1;
        }
        var buf = try allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (query_parts.items, 0..) |part, idx| {
            @memcpy(buf[pos..][0..part.len], part);
            pos += part.len;
            if (idx < query_parts.items.len - 1) {
                buf[pos] = ' ';
                pos += 1;
            }
        }
        parsed.query_owned = buf;
        parsed.query = buf;
    }

    return parsed;
}

test "parse implicit search" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "chatscan", "SIMD", "optimization" };
    var parsed = try parse(allocator, &args);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(CommandTag.search, parsed.command);
    try std.testing.expect(parsed.assumed_search);
    try std.testing.expectEqualStrings("SIMD optimization", parsed.query.?);
}

test "parse explicit search" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "chatscan", "search", "hello", "--top", "5", "--json" };
    var parsed = try parse(allocator, &args);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(CommandTag.search, parsed.command);
    try std.testing.expect(!parsed.assumed_search);
    try std.testing.expectEqualStrings("hello", parsed.query.?);
    try std.testing.expectEqual(@as(usize, 5), parsed.top_n);
    try std.testing.expectEqual(OutputFormat.json, parsed.output);
}

test "parse index command" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "chatscan", "index", "--reindex" };
    var parsed = try parse(allocator, &args);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(CommandTag.index, parsed.command);
    try std.testing.expect(parsed.reindex);
}

test "parse regex flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "chatscan", "--regex", "indexOfIgnoreCase" };
    var parsed = try parse(allocator, &args);
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.regex_mode);
    try std.testing.expectEqualStrings("indexOfIgnoreCase", parsed.query.?);
}

test "parse project filter" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "chatscan", "search", "test", "--project", "codescan" };
    var parsed = try parse(allocator, &args);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("codescan", parsed.project.?);
}

test "parse --backend openai" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "chatscan", "index", "--backend", "openai" };
    var parsed = try parse(allocator, &args);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(config.EmbeddingBackend.openai, parsed.embedding_backend.?);
}

test "parse --backend mlx maps to openai" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "chatscan", "index", "--backend", "mlx" };
    var parsed = try parse(allocator, &args);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(config.EmbeddingBackend.openai, parsed.embedding_backend.?);
}

test "parse --embedding-api-key" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "chatscan", "index", "--embedding-api-key", "sk-xyz" };
    var parsed = try parse(allocator, &args);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("sk-xyz", parsed.embedding_api_key.?);
}

test "parse no args" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{"chatscan"};
    var parsed = try parse(allocator, &args);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(CommandTag.search, parsed.command);
    try std.testing.expect(parsed.query == null);
}

test "parse reads --weight-* flags as floats (later overrides earlier)" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "query", "--weight-vector", "0.2", "--weight-lexical", "1.5", "--weight-recency", "0.1", "--weight-vector", "0.4" };
    var parsed = try parse(allocator, &args);
    defer parsed.deinit(allocator);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), parsed.weight_vector.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), parsed.weight_lexical.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), parsed.weight_recency.?, 0.0001);
}

test "parse rejects a non-numeric weight" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "query", "--weight-vector", "notanumber" };
    try std.testing.expectError(error.InvalidWeight, parse(allocator, &args));
}
