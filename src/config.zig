const std = @import("std");
const env_expand = @import("env_expand.zig");
const runtime = @import("runtime.zig");

pub const EmbeddingBackend = enum {
    ollama,
    openai,

    pub fn parse(value: []const u8) !EmbeddingBackend {
        if (std.mem.eql(u8, value, "ollama")) return .ollama;
        if (std.mem.eql(u8, value, "openai")) return .openai;
        if (std.mem.eql(u8, value, "mlx")) return .openai;
        if (std.mem.eql(u8, value, "omlx")) return .openai;
        return error.InvalidBackend;
    }
};

pub const LlmSource = enum {
    claude,
    codex,
    gemini,
    all,

    pub fn parse(value: []const u8) !LlmSource {
        if (std.mem.eql(u8, value, "claude")) return .claude;
        if (std.mem.eql(u8, value, "codex")) return .codex;
        if (std.mem.eql(u8, value, "gemini")) return .gemini;
        if (std.mem.eql(u8, value, "all")) return .all;
        return error.InvalidLlmSource;
    }

    /// Infer the origin CLI from a conversation file path (provenance for
    /// display). Claude lives under `.claude/projects`, Codex under
    /// `.codex/sessions`, Gemini under `.gemini/tmp`; unknown paths default to
    /// claude (the historical single source).
    pub fn fromPath(file_path: []const u8) LlmSource {
        if (std.mem.indexOf(u8, file_path, "/.codex/") != null) return .codex;
        if (std.mem.indexOf(u8, file_path, "/.gemini/") != null) return .gemini;
        return .claude;
    }

    /// Short lowercase label for display/JSON (e.g. "claude").
    pub fn label(self: LlmSource) []const u8 {
        return switch (self) {
            .claude => "claude",
            .codex => "codex",
            .gemini => "gemini",
            .all => "all",
        };
    }
};

/// Conversation-path fragments that indexing skips by default. The claude-mem
/// "observer" sessions are a secondary agent's XML commentary on real sessions,
/// not conversations worth searching. Extend at runtime via CHATSCAN_IGNORE.
pub const default_ignore_patterns = [_][]const u8{"-claude-mem-observer-sessions"};

/// True if `file_path` contains any of `patterns` as a literal substring — the
/// classifier used to exclude tool/meta conversation dirs from the index.
pub fn isIgnoredPath(file_path: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pat| {
        if (pat.len == 0) continue;
        if (std.mem.indexOf(u8, file_path, pat) != null) return true;
    }
    return false;
}

pub const Config = struct {
    conversation_dir: ?[]const u8 = null,
    db_path: ?[]const u8 = null,
    ollama_url: ?[]const u8 = null,
    ollama_model: ?[]const u8 = null,
    embedding_dim: ?usize = null,
    embedding_backend: ?EmbeddingBackend = null,
    embedding_url: ?[]const u8 = null,
    embedding_model: ?[]const u8 = null,
    weight_vector: ?f32 = null,
    weight_lexical: ?f32 = null,
    weight_recency: ?f32 = null,
    embedding_api_key: ?[]const u8 = null,
    // Raw pre-expansion value for embedding_api_key, used to preserve ${VAR}
    // placeholders when rewriting the config file.
    embedding_api_key_raw: ?[]const u8 = null,
    owned_strings: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.owned_strings.items) |s| allocator.free(s);
        self.owned_strings.deinit(allocator);
    }
};

/// Return the XDG config directory for chatscan.
pub fn configDir(allocator: std.mem.Allocator) ![]u8 {
    if (runtime.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
        defer allocator.free(xdg);
        return std.fmt.allocPrint(allocator, "{s}/chatscan", .{xdg});
    } else |_| {}
    const home = try getHome(allocator);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.config/chatscan", .{home});
}

/// Return the XDG data directory for chatscan.
pub fn dataDir(allocator: std.mem.Allocator) ![]u8 {
    if (runtime.getEnvVarOwned(allocator, "XDG_DATA_HOME")) |xdg| {
        defer allocator.free(xdg);
        return std.fmt.allocPrint(allocator, "{s}/chatscan", .{xdg});
    } else |_| {}
    const home = try getHome(allocator);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.local/share/chatscan", .{home});
}

/// Return the default database path.
pub fn defaultDbPath(allocator: std.mem.Allocator) ![]u8 {
    const dd = try dataDir(allocator);
    defer allocator.free(dd);
    return std.fmt.allocPrint(allocator, "{s}/index.sqlite3", .{dd});
}

/// Return the default conversation source directory for a given LLM.
pub fn defaultConversationDir(allocator: std.mem.Allocator) ![]u8 {
    return defaultConversationDirForLlm(allocator, .claude);
}

pub fn defaultConversationDirForLlm(allocator: std.mem.Allocator, llm: LlmSource) ![]u8 {
    const home = try getHome(allocator);
    defer allocator.free(home);
    return switch (llm) {
        .claude => std.fmt.allocPrint(allocator, "{s}/.claude/projects", .{home}),
        .codex => std.fmt.allocPrint(allocator, "{s}/.codex/sessions", .{home}),
        .gemini => std.fmt.allocPrint(allocator, "{s}/.gemini/tmp", .{home}),
        .all => std.fmt.allocPrint(allocator, "{s}/.claude/projects", .{home}),
    };
}

/// Detect which LLM sources exist on the system, returning the first available.
pub fn detectDefaultLlm(allocator: std.mem.Allocator) !LlmSource {
    const sources = [_]LlmSource{ .claude, .codex, .gemini };
    for (sources) |llm| {
        const dir = try defaultConversationDirForLlm(allocator, llm);
        defer allocator.free(dir);
        std.Io.Dir.cwd().access(runtime.io(), dir, .{}) catch continue;
        return llm;
    }
    return .claude; // fallback
}

/// Load config from the XDG config file. Returns default config if file doesn't exist.
pub fn loadConfig(allocator: std.mem.Allocator) !Config {
    const cd = try configDir(allocator);
    defer allocator.free(cd);
    const path = try std.fmt.allocPrint(allocator, "{s}/config", .{cd});
    defer allocator.free(path);

    const file = std.Io.Dir.cwd().openFile(runtime.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return Config{},
        else => return err,
    };
    defer file.close(runtime.io());

    const content = runtime.readToEndAlloc(file, allocator, 64 * 1024) catch return Config{};
    defer allocator.free(content);

    return parseConfig(allocator, content);
}

fn parseConfig(allocator: std.mem.Allocator, content: []const u8) !Config {
    var cfg = Config{};
    errdefer cfg.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

            if (std.mem.eql(u8, key, "conversation_dir")) {
                cfg.conversation_dir = try storeExpanded(allocator, &cfg, value);
            } else if (std.mem.eql(u8, key, "db_path")) {
                cfg.db_path = try storeExpanded(allocator, &cfg, value);
            } else if (std.mem.eql(u8, key, "ollama_url")) {
                cfg.ollama_url = try storeExpanded(allocator, &cfg, value);
            } else if (std.mem.eql(u8, key, "ollama_model")) {
                cfg.ollama_model = try storeExpanded(allocator, &cfg, value);
            } else if (std.mem.eql(u8, key, "embedding_url")) {
                cfg.embedding_url = try storeExpanded(allocator, &cfg, value);
            } else if (std.mem.eql(u8, key, "embedding_model")) {
                cfg.embedding_model = try storeExpanded(allocator, &cfg, value);
            } else if (std.mem.eql(u8, key, "embedding_backend")) {
                const expanded = try storeExpanded(allocator, &cfg, value);
                cfg.embedding_backend = EmbeddingBackend.parse(expanded) catch null;
            } else if (std.mem.eql(u8, key, "embedding_api_key")) {
                // Secret field: preserve raw placeholder if it contains any ${VAR}
                if (env_expand.hasEnvRef(value)) {
                    const raw = try allocator.dupe(u8, value);
                    try cfg.owned_strings.append(allocator, raw);
                    cfg.embedding_api_key_raw = raw;
                }
                cfg.embedding_api_key = try storeExpanded(allocator, &cfg, value);
            } else if (std.mem.eql(u8, key, "embedding_dim")) {
                cfg.embedding_dim = std.fmt.parseInt(usize, value, 10) catch null;
            } else if (std.mem.eql(u8, key, "weight_vector")) {
                cfg.weight_vector = std.fmt.parseFloat(f32, value) catch null;
            } else if (std.mem.eql(u8, key, "weight_lexical")) {
                cfg.weight_lexical = std.fmt.parseFloat(f32, value) catch null;
            } else if (std.mem.eql(u8, key, "weight_recency")) {
                cfg.weight_recency = std.fmt.parseFloat(f32, value) catch null;
            }
        }
    }
    return cfg;
}

fn storeExpanded(
    allocator: std.mem.Allocator,
    cfg: *Config,
    value: []const u8,
) ![]u8 {
    const expanded = try env_expand.expandEnvVars(allocator, value);
    try cfg.owned_strings.append(allocator, expanded);
    return expanded;
}

fn getHome(allocator: std.mem.Allocator) ![]u8 {
    return runtime.getEnvVarOwned(allocator, "HOME") catch return error.NoHomeDir;
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn testSetEnv(name: [:0]const u8, value: [:0]const u8) void {
    _ = setenv(name.ptr, value.ptr, 1);
}

fn testUnsetEnv(name: [:0]const u8) void {
    _ = unsetenv(name.ptr);
}

test "parseConfig expands ${VAR} in non-secret fields" {
    testSetEnv("CHATSCAN_CFG_URL", "http://localhost:9999");
    defer testUnsetEnv("CHATSCAN_CFG_URL");

    const content = "ollama_url = ${CHATSCAN_CFG_URL}\n";
    var cfg = try parseConfig(std.testing.allocator, content);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("http://localhost:9999", cfg.ollama_url.?);
}

test "parseConfig preserves raw placeholder for api key" {
    testSetEnv("CHATSCAN_CFG_KEY", "sk-secret-1234");
    defer testUnsetEnv("CHATSCAN_CFG_KEY");

    const content = "embedding_api_key = ${CHATSCAN_CFG_KEY}\n";
    var cfg = try parseConfig(std.testing.allocator, content);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("sk-secret-1234", cfg.embedding_api_key.?);
    try std.testing.expectEqualStrings("${CHATSCAN_CFG_KEY}", cfg.embedding_api_key_raw.?);
}

test "parseConfig api key without env-ref has no raw" {
    const content = "embedding_api_key = literal-key\n";
    var cfg = try parseConfig(std.testing.allocator, content);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("literal-key", cfg.embedding_api_key.?);
    try std.testing.expect(cfg.embedding_api_key_raw == null);
}

test "parseConfig parses embedding_backend" {
    const content = "embedding_backend = openai\n";
    var cfg = try parseConfig(std.testing.allocator, content);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(EmbeddingBackend.openai, cfg.embedding_backend.?);
}

test "parseConfig accepts mlx as alias for openai" {
    const content = "embedding_backend = mlx\n";
    var cfg = try parseConfig(std.testing.allocator, content);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(EmbeddingBackend.openai, cfg.embedding_backend.?);
}

test "defaultConversationDir returns expected path" {
    const allocator = std.testing.allocator;
    const dir = try defaultConversationDir(allocator);
    defer allocator.free(dir);
    try std.testing.expect(std.mem.endsWith(u8, dir, "/.claude/projects"));
}

test "defaultDbPath returns expected path" {
    const allocator = std.testing.allocator;
    const path = try defaultDbPath(allocator);
    defer allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "/chatscan/index.sqlite3"));
}

test "LlmSource.fromPath classifies origin CLI over a set of paths" {
    const home = "/home/pmarreck";
    // A SET: each source's real path shape, plus the meta observer dir (still claude).
    try std.testing.expectEqual(LlmSource.claude, LlmSource.fromPath(home ++ "/.claude/projects/-x-proj/abc.jsonl"));
    try std.testing.expectEqual(LlmSource.codex, LlmSource.fromPath(home ++ "/.codex/sessions/2026/xyz.jsonl"));
    try std.testing.expectEqual(LlmSource.gemini, LlmSource.fromPath(home ++ "/.gemini/tmp/hash/logs.json"));
    // Observer sessions live under .claude/projects -> claude, not a new source.
    try std.testing.expectEqual(LlmSource.claude, LlmSource.fromPath(home ++ "/.claude/projects/-home-pmarreck--claude-mem-observer-sessions/s.jsonl"));
    // Unknown layout defaults to claude.
    try std.testing.expectEqual(LlmSource.claude, LlmSource.fromPath("relative/path.jsonl"));
    // Labels round-trip through parse.
    try std.testing.expectEqualStrings("codex", LlmSource.codex.label());
    try std.testing.expectEqual(LlmSource.gemini, try LlmSource.parse(LlmSource.gemini.label()));
}

test "isIgnoredPath excludes observer sessions, keeps real projects (classifier over a set)" {
    const def = &default_ignore_patterns;
    try std.testing.expect(isIgnoredPath("/home/p/.claude/projects/-home-p--claude-mem-observer-sessions/a.jsonl", def));
    try std.testing.expect(!isIgnoredPath("/home/p/.claude/projects/-home-p-Code-dirtree/a.jsonl", def));
    try std.testing.expect(!isIgnoredPath("/home/p/.claude/projects/-home-p-Code-validate/b.jsonl", def));
    // Custom CHATSCAN_IGNORE-style patterns compose as a set.
    const custom = [_][]const u8{ "scratch", "fixture-gamma" };
    try std.testing.expect(isIgnoredPath("/x/scratch/y.jsonl", &custom));
    try std.testing.expect(isIgnoredPath("/x/-a-fixture-gamma/y.jsonl", &custom));
    try std.testing.expect(!isIgnoredPath("/x/-a-fixture-beta/y.jsonl", &custom));
    // Empty set / empty pattern ignore nothing.
    try std.testing.expect(!isIgnoredPath("/anything", &[_][]const u8{}));
    try std.testing.expect(!isIgnoredPath("/anything", &[_][]const u8{""}));
}

test "parseConfig parses RRF ranking weights" {
    const allocator = std.testing.allocator;
    const text =
        \\weight_vector = 0.4
        \\weight_lexical = 1.0
        \\weight_recency = 0.25
    ;
    var cfg = try parseConfig(allocator, text);
    defer cfg.deinit(allocator);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), cfg.weight_vector.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cfg.weight_lexical.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), cfg.weight_recency.?, 0.0001);
}
