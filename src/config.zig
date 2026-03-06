const std = @import("std");

pub const Config = struct {
    conversation_dir: ?[]const u8 = null,
    db_path: ?[]const u8 = null,
    ollama_url: ?[]const u8 = null,
    ollama_model: ?[]const u8 = null,
    embedding_dim: ?usize = null,
    owned_strings: std.ArrayListUnmanaged([]u8) = .{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.owned_strings.items) |s| allocator.free(s);
        self.owned_strings.deinit(allocator);
    }
};

/// Return the XDG config directory for chatscan.
pub fn configDir(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
        defer allocator.free(xdg);
        return std.fmt.allocPrint(allocator, "{s}/chatscan", .{xdg});
    } else |_| {}
    const home = try getHome(allocator);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.config/chatscan", .{home});
}

/// Return the XDG data directory for chatscan.
pub fn dataDir(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_DATA_HOME")) |xdg| {
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

/// Return the default conversation source directory.
pub fn defaultConversationDir(allocator: std.mem.Allocator) ![]u8 {
    const home = try getHome(allocator);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.claude/projects", .{home});
}

/// Load config from the XDG config file. Returns default config if file doesn't exist.
pub fn loadConfig(allocator: std.mem.Allocator) !Config {
    const cd = try configDir(allocator);
    defer allocator.free(cd);
    const path = try std.fmt.allocPrint(allocator, "{s}/config", .{cd});
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return Config{},
        else => return err,
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 64 * 1024) catch return Config{};
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
                const owned = try allocator.dupe(u8, value);
                try cfg.owned_strings.append(allocator, owned);
                cfg.conversation_dir = owned;
            } else if (std.mem.eql(u8, key, "db_path")) {
                const owned = try allocator.dupe(u8, value);
                try cfg.owned_strings.append(allocator, owned);
                cfg.db_path = owned;
            } else if (std.mem.eql(u8, key, "ollama_url")) {
                const owned = try allocator.dupe(u8, value);
                try cfg.owned_strings.append(allocator, owned);
                cfg.ollama_url = owned;
            } else if (std.mem.eql(u8, key, "ollama_model")) {
                const owned = try allocator.dupe(u8, value);
                try cfg.owned_strings.append(allocator, owned);
                cfg.ollama_model = owned;
            } else if (std.mem.eql(u8, key, "embedding_dim")) {
                cfg.embedding_dim = std.fmt.parseInt(usize, value, 10) catch null;
            }
        }
    }
    return cfg;
}

fn getHome(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "HOME") catch return error.NoHomeDir;
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
