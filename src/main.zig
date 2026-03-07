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
const rename_mod = @import("rename.zig");

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
    llm_source: config.LlmSource,
    /// Extra conversation dirs for --all-llms mode
    extra_dirs: []ExtraDir = &.{},

    const ExtraDir = struct {
        dir: []const u8,
        llm: config.LlmSource,
        owned: bool,
    };
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

    if (parsed.command == .rename) {
        try handleRename(allocator, parsed, stdout, stderr);
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
    defer {
        for (settings.extra_dirs) |ed| {
            if (ed.owned) allocator.free(ed.dir);
        }
        allocator.free(settings.extra_dirs);
    }

    switch (parsed.command) {
        .help, .about, .rename => unreachable,
        .config => {
            try stdout.print("llm_source = {s}\n", .{@tagName(settings.llm_source)});
            try stdout.print("conversation_dir = {s}\n", .{settings.conversation_dir});
            for (settings.extra_dirs) |ed| {
                try stdout.print("extra_dir ({s}) = {s}\n", .{ @tagName(ed.llm), ed.dir });
            }
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

            const primary_llm: config.LlmSource = if (settings.llm_source == .all) .claude else settings.llm_source;
            const stats = try indexer.indexAllForLlm(
                allocator,
                db,
                settings.conversation_dir,
                primary_llm,
                emb,
                settings.batch_size,
                settings.reindex,
                stderr,
            );

            var total_files = stats.files_indexed;
            var total_messages = stats.messages_indexed;
            var total_deleted = stats.files_deleted;

            // Index extra LLM sources (--all-llms)
            for (settings.extra_dirs) |ed| {
                const extra_stats = indexer.indexAllForLlm(
                    allocator,
                    db,
                    ed.dir,
                    ed.llm,
                    emb,
                    settings.batch_size,
                    settings.reindex,
                    stderr,
                ) catch continue;
                total_files += extra_stats.files_indexed;
                total_messages += extra_stats.messages_indexed;
                total_deleted += extra_stats.files_deleted;
            }

            try stdout.print("Indexed {d} files ({d} messages)\n", .{ total_files, total_messages });
            if (total_deleted > 0) {
                try stdout.print("Removed {d} deleted files from index\n", .{total_deleted});
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

                const primary_llm2: config.LlmSource = if (settings.llm_source == .all) .claude else settings.llm_source;
                _ = indexer.indexAllForLlm(allocator, db, settings.conversation_dir, primary_llm2, emb, settings.batch_size, false, stderr) catch |err| {
                    _ = stderr.print("warning: indexing failed: {}\n", .{err}) catch {};
                    _ = stderr.flush() catch {};
                };

                // Index extra LLM sources
                for (settings.extra_dirs) |ed| {
                    _ = indexer.indexAllForLlm(allocator, db, ed.dir, ed.llm, emb, settings.batch_size, false, stderr) catch {};
                }
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

    // Resolve LLM source: CLI flag > env var > auto-detect
    const llm_source = if (parsed.llm_source) |llm| llm else blk: {
        if (std.process.getEnvVarOwned(allocator, "CHATSCAN_LLM")) |env_val| {
            defer allocator.free(env_val);
            break :blk config.LlmSource.parse(env_val) catch .claude;
        } else |_| {}
        break :blk try config.detectDefaultLlm(allocator);
    };

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

    // Conversation dir — depends on LLM source
    var conv_dir: []const u8 = undefined;
    var conv_dir_owned = false;
    const effective_llm = if (llm_source == .all) config.LlmSource.claude else llm_source;
    if (parsed.conversation_dir) |p| {
        conv_dir = p;
    } else if (cfg.conversation_dir) |p| {
        conv_dir = p;
    } else {
        conv_dir = try config.defaultConversationDirForLlm(allocator, effective_llm);
        conv_dir_owned = true;
    }

    // For --all-llms, build extra dirs for the other LLM sources
    var extra_dirs = std.ArrayListUnmanaged(Settings.ExtraDir){};
    if (llm_source == .all) {
        const other_sources = [_]config.LlmSource{ .codex, .gemini };
        for (other_sources) |src| {
            const dir = config.defaultConversationDirForLlm(allocator, src) catch continue;
            std.fs.accessAbsolute(dir, .{}) catch {
                allocator.free(dir);
                continue;
            };
            try extra_dirs.append(allocator, .{ .dir = dir, .llm = src, .owned = true });
        }
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
        .llm_source = llm_source,
        .extra_dirs = try extra_dirs.toOwnedSlice(allocator),
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

fn handleRename(
    allocator: std.mem.Allocator,
    parsed: cli.Parsed,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    _ = stderr;

    const old_arg = parsed.rename_old orelse {
        try stdout.writeAll("error: chatscan rename requires two arguments: <old-path> <new-path>\n");
        try stdout.flush();
        std.process.exit(64);
    };
    const new_arg = parsed.rename_new orelse {
        try stdout.writeAll("error: chatscan rename requires two arguments: <old-path> <new-path>\n");
        try stdout.flush();
        std.process.exit(64);
    };

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    const old_path = try rename_mod.resolvePath(allocator, old_arg, cwd);
    defer allocator.free(old_path);

    // If new_arg has no '/', treat as basename in same parent as old_path
    const new_path = if (std.mem.indexOfScalar(u8, new_arg, '/') == null) blk: {
        if (std.fs.path.dirname(old_path)) |parent| {
            break :blk try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, new_arg });
        }
        break :blk try rename_mod.resolvePath(allocator, new_arg, cwd);
    } else try rename_mod.resolvePath(allocator, new_arg, cwd);
    defer allocator.free(new_path);

    // Validate old path exists
    std.fs.accessAbsolute(old_path, .{}) catch {
        try stdout.print("error: old path does not exist: {s}\n", .{old_path});
        try stdout.flush();
        std.process.exit(1);
    };

    // Validate new path doesn't exist
    std.fs.accessAbsolute(new_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {}, // good
        else => {},
    };
    // If new path exists, error
    if (std.fs.accessAbsolute(new_path, .{})) |_| {
        try stdout.print("error: new path already exists: {s}\n", .{new_path});
        try stdout.flush();
        std.process.exit(1);
    } else |_| {} // FileNotFound is expected

    // Try to open the DB for index updates
    const db_path = config.defaultDbPath(allocator) catch null;
    defer if (db_path) |p| allocator.free(p);

    var db: ?storage.Db = null;
    if (db_path) |p| {
        db = storage.openFileWithVec(allocator, p) catch null;
    }
    defer if (db) |d| storage.close(d);

    if (db) |d| {
        var schema_result = storage.initSchema(allocator, d, .{
            .embedding_dim = 1024,
        }) catch null;
        if (schema_result) |*sr| sr.deinit(allocator);
    }

    // Build plan
    var plan = try rename_mod.buildPlan(allocator, old_path, new_path, db);
    defer plan.deinit();

    // Print plan
    try rename_mod.printPlan(&plan, stdout);
    try stdout.flush();

    // Confirm
    if (!parsed.force) {
        const confirmed = rename_mod.confirmPrompt(stdout) catch false;
        if (!confirmed) {
            try stdout.writeAll("Aborted.\n");
            try stdout.flush();
            return;
        }
    }

    // Execute
    rename_mod.executePlan(allocator, &plan, db, stdout) catch |err| {
        try stdout.print("error: rename failed: {}\n", .{err});
        try stdout.flush();
        std.process.exit(1);
    };
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
        \\chatscan — search AI coding conversation history
        \\
        \\Usage:
        \\  chatscan <query>              Search conversations (implicit)
        \\  chatscan search <query>       Search conversations
        \\  chatscan index                Index/update conversation database
        \\  chatscan rename <old> <new>    Rename project dir + update all logs
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
        \\LLM source options:
        \\  --llm <claude|codex|gemini>   Select LLM source (default: auto-detect)
        \\  --all-llms                    Search across all available LLM sources
        \\  CHATSCAN_LLM=<value>          Env var alternative (claude|codex|gemini|all)
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
        \\Sources: ~/.claude/projects/, ~/.codex/sessions/, ~/.gemini/tmp/
        \\
    );
}

test "printUsage does not crash" {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    try printUsage(&w.interface);
}
