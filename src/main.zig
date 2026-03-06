const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const storage = @import("storage.zig");
const embedding = @import("embedding.zig");
const ollama = @import("ollama.zig");
const indexer = @import("indexer.zig");
const search_mod = @import("search.zig");
const output = @import("output.zig");
const ripgrep = @import("ripgrep.zig");
const conversation = @import("conversation.zig");

const version = "0.1.0";

const Defaults = struct {
    top_n: usize = 10,
    ollama_url: []const u8 = "http://localhost:11434",
    ollama_model: []const u8 = "bge-large",
    embedding_dim: usize = 1024,
    batch_size: usize = 16,
    search_mode: search_mod.SearchMode = .hybrid,
    context_lines: usize = 4,
};

const Settings = struct {
    output: cli.OutputFormat,
    top_n: usize,
    db_path: []const u8,
    db_path_owned: bool,
    conversation_dir: []const u8,
    conversation_dir_owned: bool,
    ollama_url: []const u8,
    ollama_model: []const u8,
    embedding_dim: usize,
    batch_size: usize,
    search_mode: search_mod.SearchMode,
    context_lines: usize,
    all_projects: bool,
    project: ?[]const u8,
    role_filter: ?[]const u8,
    regex_mode: bool,
    reindex: bool,
    force: bool,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    var parsed = cli.parse(allocator, args) catch |err| {
        _ = stderr.print("error: {}\n", .{err}) catch {};
        _ = stderr.flush() catch {};
        std.process.exit(64);
    };
    defer parsed.deinit(allocator);

    if (parsed.command == .help) {
        try printUsage(stdout);
        try stdout.flush();
        return;
    }

    if (parsed.command == .about) {
        try stdout.print("chatscan {s} — search Claude Code conversation history ({s}-{s})\n", .{
            version,
            @tagName(@import("builtin").target.os.tag),
            @tagName(@import("builtin").target.cpu.arch),
        });
        try stdout.flush();
        return;
    }

    // Load config
    var cfg = config.loadConfig(allocator) catch Config_empty: {
        break :Config_empty config.Config{};
    };
    defer cfg.deinit(allocator);

    // Resolve settings
    const settings = try resolveSettings(allocator, parsed, cfg);
    defer if (settings.db_path_owned) allocator.free(settings.db_path);
    defer if (settings.conversation_dir_owned) allocator.free(settings.conversation_dir);

    switch (parsed.command) {
        .help, .about => unreachable,
        .config => {
            try stdout.print("conversation_dir = {s}\n", .{settings.conversation_dir});
            try stdout.print("db_path = {s}\n", .{settings.db_path});
            try stdout.print("ollama_url = {s}\n", .{settings.ollama_url});
            try stdout.print("ollama_model = {s}\n", .{settings.ollama_model});
            try stdout.print("embedding_dim = {d}\n", .{settings.embedding_dim});
            try stdout.flush();
        },
        .index => {
            try ensureDbDir(allocator, settings.db_path);
            const db = try storage.openFileWithVec(allocator, settings.db_path);
            defer storage.close(db);

            var schema_result = try storage.initSchema(allocator, db, .{
                .embedding_dim = settings.embedding_dim,
                .embedding_model = settings.ollama_model,
            });
            defer schema_result.deinit(allocator);

            if (settings.reindex) {
                _ = stderr.print("Force re-indexing...\n", .{}) catch {};
                _ = stderr.flush() catch {};
                try storage.resetIndex(db);
            }

            // Try to set up embedder
            var http_client = ollama.StdHttpTransport.init(allocator);
            defer http_client.deinit();
            const ollama_ok = tryInitOllama(allocator, &http_client, settings.ollama_url, settings.ollama_model, stderr);

            var embedder_adapter = embedding.OllamaEmbedder{
                .transport = http_client.transport(),
                .base_url = settings.ollama_url,
                .model = settings.ollama_model,
            };
            const emb: ?embedding.Embedder = if (ollama_ok) embedder_adapter.embedder() else null;

            const stats = try indexer.indexAll(
                allocator,
                db,
                settings.conversation_dir,
                emb,
                settings.batch_size,
                settings.reindex,
                stderr,
            );

            try stdout.print("Indexed {d} files ({d} messages)\n", .{ stats.files_indexed, stats.messages_indexed });
            if (stats.files_deleted > 0) {
                try stdout.print("Removed {d} deleted files from index\n", .{stats.files_deleted});
            }
            try stdout.flush();
        },
        .search => {
            const query = parsed.query orelse {
                _ = stderr.print("error: no search query provided\n", .{}) catch {};
                _ = stderr.flush() catch {};
                std.process.exit(1);
            };

            // Regex mode: shell out to ripgrep
            if (settings.regex_mode) {
                try runRegexSearch(allocator, query, settings, stdout, stderr);
                try stdout.flush();
                return;
            }

            try ensureDbDir(allocator, settings.db_path);
            const db = try storage.openFileWithVec(allocator, settings.db_path);
            defer storage.close(db);

            var schema_result = try storage.initSchema(allocator, db, .{
                .embedding_dim = settings.embedding_dim,
                .embedding_model = settings.ollama_model,
            });
            defer schema_result.deinit(allocator);

            // Set up HTTP client for Ollama
            var http_client = ollama.StdHttpTransport.init(allocator);
            defer http_client.deinit();
            const ollama_ok = tryInitOllama(allocator, &http_client, settings.ollama_url, settings.ollama_model, stderr);

            var embedder_adapter = embedding.OllamaEmbedder{
                .transport = http_client.transport(),
                .base_url = settings.ollama_url,
                .model = settings.ollama_model,
            };
            const emb: ?embedding.Embedder = if (ollama_ok) embedder_adapter.embedder() else null;

            // Auto-index if empty
            if (!storage.isIndexPopulated(db)) {
                _ = stderr.print("No index found. Indexing conversations...\n", .{}) catch {};
                _ = stderr.flush() catch {};

                _ = indexer.indexAll(allocator, db, settings.conversation_dir, emb, settings.batch_size, false, stderr) catch |err| {
                    _ = stderr.print("warning: indexing failed: {}\n", .{err}) catch {};
                    _ = stderr.flush() catch {};
                };
            }

            // Detect current project for default filtering
            var project_dir_filter: ?[]const u8 = null;
            if (!settings.all_projects and settings.project == null) {
                project_dir_filter = try detectCurrentProjectDir(allocator, settings.conversation_dir);
                if (project_dir_filter == null) {
                    _ = stderr.print("note: No conversations found for current directory. Searching all projects.\n", .{}) catch {};
                    _ = stderr.flush() catch {};
                }
            }
            defer if (project_dir_filter) |p| allocator.free(p);

            const effective_mode: search_mod.SearchMode = if (emb == null and settings.search_mode != .lexical) blk: {
                break :blk .lexical;
            } else settings.search_mode;

            const sr = try search_mod.search(allocator, db, emb, query, .{
                .top_n = settings.top_n,
                .mode = effective_mode,
                .role_filter = settings.role_filter,
                .project_filter = settings.project,
                .project_dir_filter = project_dir_filter,
            });
            defer search_mod.freeResults(allocator, sr.results);

            const use_color = parsed.output != .json and std.process.getEnvVarOwned(allocator, "NO_COLOR") == error.EnvironmentVariableNotFound;

            try output.writeResults(allocator, db, stdout, settings.output, sr.results, .{
                .use_color = use_color,
                .total_relevant = sr.total_relevant,
                .top_n = settings.top_n,
                .context_lines = settings.context_lines,
            });
            try stdout.flush();
        },
    }
}

fn resolveSettings(allocator: std.mem.Allocator, parsed: cli.Parsed, cfg: config.Config) !Settings {
    const defaults = Defaults{};

    // DB path
    var db_path: []const u8 = undefined;
    var db_path_owned = false;
    if (parsed.db_path) |p| {
        db_path = p;
    } else if (cfg.db_path) |p| {
        db_path = p;
    } else {
        db_path = try config.defaultDbPath(allocator);
        db_path_owned = true;
    }

    // Conversation dir
    var conv_dir: []const u8 = undefined;
    var conv_dir_owned = false;
    if (parsed.conversation_dir) |p| {
        conv_dir = p;
    } else if (cfg.conversation_dir) |p| {
        conv_dir = p;
    } else {
        conv_dir = try config.defaultConversationDir(allocator);
        conv_dir_owned = true;
    }

    return Settings{
        .output = parsed.output,
        .top_n = if (parsed.seen.top_n) parsed.top_n else defaults.top_n,
        .db_path = db_path,
        .db_path_owned = db_path_owned,
        .conversation_dir = conv_dir,
        .conversation_dir_owned = conv_dir_owned,
        .ollama_url = parsed.ollama_url orelse cfg.ollama_url orelse defaults.ollama_url,
        .ollama_model = parsed.ollama_model orelse cfg.ollama_model orelse defaults.ollama_model,
        .embedding_dim = parsed.embedding_dim orelse cfg.embedding_dim orelse defaults.embedding_dim,
        .batch_size = defaults.batch_size,
        .search_mode = if (parsed.seen.search_mode) parsed.search_mode else defaults.search_mode,
        .context_lines = parsed.context_lines,
        .all_projects = parsed.all_projects,
        .project = parsed.project,
        .role_filter = parsed.role_filter,
        .regex_mode = parsed.regex_mode,
        .reindex = parsed.reindex,
        .force = parsed.force,
    };
}

fn tryInitOllama(
    allocator: std.mem.Allocator,
    http_client: *ollama.StdHttpTransport,
    ollama_url: []const u8,
    ollama_model: []const u8,
    stderr: *std.Io.Writer,
) bool {
    ollama.ensureModelAvailable(allocator, http_client.transport(), ollama_url, ollama_model) catch |err| {
        switch (err) {
            error.ModelLoading => {
                _ = stderr.print("note: Ollama model '{s}' is loading. Embeddings will be generated once loaded.\n", .{ollama_model}) catch {};
                _ = stderr.flush() catch {};
                return true;
            },
            else => {
                _ = stderr.print("note: Ollama not available ({s}). Falling back to lexical search.\n", .{ollama_url}) catch {};
                _ = stderr.flush() catch {};
                return false;
            },
        }
    };
    return true;
}

fn runRegexSearch(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    settings: Settings,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    _ = stderr;
    const matches = ripgrep.searchRegex(allocator, pattern, settings.conversation_dir, settings.top_n * 5) catch |err| {
        var buf: [256]u8 = undefined;
        var w = std.fs.File.stderr().writer(&buf);
        const ew = &w.interface;
        _ = ew.print("error: ripgrep search failed: {}\n", .{err}) catch {};
        _ = ew.flush() catch {};
        std.process.exit(1);
    };
    defer {
        for (matches) |*m| {
            var match = m.*;
            match.deinit(allocator);
        }
        allocator.free(matches);
    }

    if (matches.len == 0) {
        try stdout.writeAll("No matches found.\n");
        return;
    }

    const use_color = std.process.getEnvVarOwned(allocator, "NO_COLOR") == error.EnvironmentVariableNotFound;

    for (matches, 0..) |match, idx| {
        if (idx >= settings.top_n) break;

        if (use_color) try stdout.writeAll("\x1b[1m");
        try stdout.print("{d}.", .{idx + 1});
        if (use_color) try stdout.writeAll("\x1b[0m");
        try stdout.writeAll(" ");

        if (use_color) try stdout.writeAll("\x1b[36m");
        try stdout.writeAll(match.file_path);
        if (use_color) try stdout.writeAll("\x1b[0m");

        if (use_color) try stdout.writeAll("\x1b[33m");
        try stdout.print(":{d}", .{match.line_number});
        if (use_color) try stdout.writeAll("\x1b[0m");

        try stdout.writeAll("\n");

        // Show a truncated preview of the matched line
        const preview = if (match.line_text.len > 200) match.line_text[0..200] else match.line_text;
        try stdout.print("   {s}", .{preview});
        if (match.line_text.len > 200) try stdout.writeAll("...");
        try stdout.writeAll("\n");
    }
}

/// Detect the current project's conversation directory slug by matching the cwd
/// to known project directories in the conversation dir.
fn detectCurrentProjectDir(allocator: std.mem.Allocator, conversation_dir: []const u8) !?[]u8 {
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    // Convert cwd to the project directory slug format: replace / with -
    // e.g., /Users/pmarreck/Documents-CloudManaged/codescan -> -Users-pmarreck-Documents-CloudManaged-codescan
    var slug = try allocator.alloc(u8, cwd.len);
    for (cwd, 0..) |ch, i| {
        slug[i] = if (ch == '/') '-' else ch;
    }

    // Check if this directory exists under conversation_dir
    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ conversation_dir, slug });
    defer allocator.free(full_path);

    std.fs.accessAbsolute(full_path, .{}) catch {
        allocator.free(slug);
        return null;
    };

    return slug;
}

fn ensureDbDir(allocator: std.mem.Allocator, db_path: []const u8) !void {
    if (std.fs.path.dirname(db_path)) |dir| {
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                // Try creating parent directories
                const parent = try allocator.dupe(u8, dir);
                defer allocator.free(parent);
                std.fs.makeDirAbsolute(parent) catch {};
            },
        };
    }
}

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\chatscan — search Claude conversation history
        \\
        \\Usage:
        \\  chatscan <query>              Search conversations (implicit)
        \\  chatscan search <query>       Search conversations
        \\  chatscan index                Index/update conversation database
        \\  chatscan config               Show configuration
        \\  chatscan help                 Show this help
        \\
        \\Search options:
        \\  --top <n>                     Number of results (default 10)
        \\  --all                         Search all projects
        \\  --project <name>              Search specific project
        \\  --role <user|assistant>        Filter by message role
        \\  --regex                       Use ripgrep for regex search
        \\  --mode <vector|lexical|hybrid> Search mode (default hybrid)
        \\  --context-lines <n>           Lines to show per message (default 4)
        \\  --json                        JSON output
        \\
        \\Index options:
        \\  --reindex                     Force full re-index
        \\
        \\Global options:
        \\  --db <path>                   SQLite database path
        \\  --conversation-dir <path>     Conversation files directory
        \\  --ollama-url <url>            Ollama server URL
        \\  --ollama-model <name>         Embedding model name
        \\  --embedding-dim <n>           Embedding dimension
        \\
        \\Config file: $XDG_CONFIG_HOME/chatscan/config
        \\Database: $XDG_DATA_HOME/chatscan/index.sqlite3
        \\Conversations: ~/.claude/projects/
        \\
    );
}

test "printUsage does not crash" {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    try printUsage(&w.interface);
}
