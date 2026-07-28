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
const runtime = @import("runtime.zig");

const version = "0.1.0";

const Defaults = struct {
    top_n: usize = 10,
    ollama_url: []const u8 = "http://localhost:11434",
    ollama_model: []const u8 = "bge-large",
    openai_url: []const u8 = "http://localhost:10240",
    openai_model: []const u8 = "text-embedding-3-small",
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
    embedding_backend: config.EmbeddingBackend,
    embedding_url: []const u8,
    embedding_model: []const u8,
    embedding_api_key: ?[]const u8,
    embedding_api_key_owned: bool,
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

pub fn main(init: std.process.Init) !void {
    runtime.init(init.io, init.environ_map);
    const io = init.io;

    const arena = init.arena;
    const allocator = arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    var parsed = cli.parse(allocator, args) catch |err| {
        switch (err) {
            error.InvalidDate => _ = stderr.print("error: invalid date — expected YYYY-MM-DD (e.g. --since 2026-07-01)\n", .{}) catch {},
            error.MissingValue => _ = stderr.print("error: an option is missing its value\n", .{}) catch {},
            error.InvalidRole => _ = stderr.print("error: --role must be 'user' or 'assistant'\n", .{}) catch {},
            else => _ = stderr.print("error: {s}\n", .{@errorName(err)}) catch {},
        }
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
    defer if (settings.embedding_api_key_owned) {
        if (settings.embedding_api_key) |k| allocator.free(k);
    };
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
            try stdout.print("embedding_backend = {s}\n", .{@tagName(settings.embedding_backend)});
            try stdout.print("embedding_url = {s}\n", .{settings.embedding_url});
            try stdout.print("embedding_model = {s}\n", .{settings.embedding_model});
            try stdout.print("embedding_api_key = {s}\n", .{if (settings.embedding_api_key) |_| "<set>" else "<unset>"});
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
            var ollama_adapter: embedding.OllamaEmbedder = undefined;
            var openai_adapter: embedding.OpenAIEmbedder = undefined;
            const emb = setupEmbedder(allocator, &http_client, settings, stderr, &ollama_adapter, &openai_adapter);

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

            // Set up HTTP client + embedder
            var http_client = ollama.StdHttpTransport.init(allocator);
            defer http_client.deinit();
            var ollama_adapter: embedding.OllamaEmbedder = undefined;
            var openai_adapter: embedding.OpenAIEmbedder = undefined;
            const emb = setupEmbedder(allocator, &http_client, settings, stderr, &ollama_adapter, &openai_adapter);

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

            // Detect current project for default filtering. Be transparent about
            // scoping — silently limiting to the cwd's project is the #1 "why did
            // my search return nothing?" surprise.
            var project_dir_filter: ?[]const u8 = null;
            if (!settings.all_projects and settings.project == null) {
                project_dir_filter = try detectCurrentProjectDir(allocator, settings.conversation_dir);
                if (project_dir_filter) |slug| {
                    _ = stderr.print("note: limiting to the current project ({s}). Use --all to search every project, or --project <path> to pick another.\n", .{slug}) catch {};
                    _ = stderr.flush() catch {};
                } else {
                    _ = stderr.print("note: no conversations indexed for the current directory; searching all projects.\n", .{}) catch {};
                    _ = stderr.flush() catch {};
                }
            }
            defer if (project_dir_filter) |p| allocator.free(p);

            const effective_mode: search_mod.SearchMode = if (emb == null and settings.search_mode != .lexical) blk: {
                break :blk .lexical;
            } else settings.search_mode;

            const sr = search_mod.search(allocator, db, emb, query, .{
                .top_n = settings.top_n,
                .mode = effective_mode,
                .role_filter = settings.role_filter,
                .project_filter = settings.project,
                .project_dir_filter = project_dir_filter,
                .since = parsed.since,
                .until = parsed.until,
            }) catch |err| {
                _ = stderr.print("error: search failed: {s}\n", .{@errorName(err)}) catch {};
                switch (err) {
                    error.EmptyQuery => _ = stderr.print("  (no query text was provided)\n", .{}) catch {},
                    error.InvalidWeights => _ = stderr.print("  (search weights sum to zero; check --mode / config)\n", .{}) catch {},
                    error.InvalidEmbeddingCount => _ = stderr.print("  (embedder returned an unexpected number of vectors; is the embedding model correct?)\n", .{}) catch {},
                    else => {},
                }
                _ = stderr.flush() catch {};
                std.process.exit(1);
            };
            defer search_mod.freeResults(allocator, sr.results);

            // Loudly explain an empty result set — usually it's scoping, not absence.
            if (sr.total_relevant == 0) {
                if (project_dir_filter != null) {
                    _ = stderr.print("note: no matches in the current project. Re-run with --all to search all projects.\n", .{}) catch {};
                } else if (settings.project) |p| {
                    _ = stderr.print("note: no matches for --project '{s}'. Try a shorter path fragment, or --all.\n", .{p}) catch {};
                }
                _ = stderr.flush() catch {};
            }

            const use_color = parsed.output != .json and runtime.getEnvVarOwned(allocator, "NO_COLOR") == error.EnvironmentVariableNotFound;

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
        if (runtime.getEnvVarOwned(allocator, "CHATSCAN_LLM")) |env_val| {
            defer allocator.free(env_val);
            break :blk config.LlmSource.parse(env_val) catch .claude;
        } else |_| {}
        break :blk try config.detectDefaultLlm(allocator);
    };

    // DB path: CLI flag > env (CHATSCAN_DB) > config > default
    var db_path: []const u8 = undefined;
    var db_path_owned = false;
    if (parsed.db_path) |p| {
        db_path = p;
    } else if (runtime.getEnvVarOwned(allocator, "CHATSCAN_DB")) |env_val| {
        db_path = env_val;
        db_path_owned = true;
    } else |_| {
        if (cfg.db_path) |p| {
            db_path = p;
        } else {
            db_path = try config.defaultDbPath(allocator);
            db_path_owned = true;
        }
    }

    // Conversation dir — depends on LLM source
    var conv_dir: []const u8 = undefined;
    var conv_dir_owned = false;
    const effective_llm = if (llm_source == .all) config.LlmSource.claude else llm_source;
    if (parsed.conversation_dir) |p| {
        conv_dir = p;
    } else if (runtime.getEnvVarOwned(allocator, "CHATSCAN_CONVERSATION_DIR")) |env_val| {
        conv_dir = env_val;
        conv_dir_owned = true;
    } else |_| {
        if (cfg.conversation_dir) |p| {
            conv_dir = p;
        } else {
            conv_dir = try config.defaultConversationDirForLlm(allocator, effective_llm);
            conv_dir_owned = true;
        }
    }

    // For --all-llms, build extra dirs for the other LLM sources
    var extra_dirs = std.ArrayListUnmanaged(Settings.ExtraDir).empty;
    if (llm_source == .all) {
        const other_sources = [_]config.LlmSource{ .codex, .gemini };
        for (other_sources) |src| {
            const dir = config.defaultConversationDirForLlm(allocator, src) catch continue;
            std.Io.Dir.cwd().access(runtime.io(), dir, .{}) catch {
                allocator.free(dir);
                continue;
            };
            try extra_dirs.append(allocator, .{ .dir = dir, .llm = src, .owned = true });
        }
    }

    // Resolve embedding backend: CLI flag > env var > config > default (ollama)
    const backend: config.EmbeddingBackend = if (parsed.embedding_backend) |b| b else blk: {
        if (runtime.getEnvVarOwned(allocator, "CHATSCAN_EMBEDDING_BACKEND")) |env_val| {
            defer allocator.free(env_val);
            break :blk config.EmbeddingBackend.parse(env_val) catch .ollama;
        } else |_| {}
        if (cfg.embedding_backend) |b| break :blk b;
        break :blk .ollama;
    };

    // Resolve per-backend URL/model defaults
    const default_url = switch (backend) {
        .ollama => defaults.ollama_url,
        .openai => defaults.openai_url,
    };
    const default_model = switch (backend) {
        .ollama => defaults.ollama_model,
        .openai => defaults.openai_model,
    };

    const embedding_url = parsed.embedding_url orelse cfg.embedding_url orelse switch (backend) {
        .ollama => parsed.ollama_url orelse cfg.ollama_url orelse default_url,
        .openai => default_url,
    };
    const embedding_model = parsed.embedding_model orelse cfg.embedding_model orelse switch (backend) {
        .ollama => parsed.ollama_model orelse cfg.ollama_model orelse default_model,
        .openai => default_model,
    };

    // Resolve API key: CLI flag > env var > config
    var api_key: ?[]const u8 = null;
    var api_key_owned = false;
    if (parsed.embedding_api_key) |k| {
        api_key = k;
    } else if (runtime.getEnvVarOwned(allocator, "CHATSCAN_EMBEDDING_API_KEY")) |env_val| {
        api_key = env_val;
        api_key_owned = true;
    } else |_| {
        if (cfg.embedding_api_key) |k| api_key = k;
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
        .embedding_backend = backend,
        .embedding_url = embedding_url,
        .embedding_model = embedding_model,
        .embedding_api_key = api_key,
        .embedding_api_key_owned = api_key_owned,
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

/// Build an Embedder for the configured backend, or return null if it's not
/// available (Ollama not running, model unavailable, etc.). Adapter storage is
/// provided by the caller so lifetimes match the HTTP client.
fn setupEmbedder(
    allocator: std.mem.Allocator,
    http_client: *ollama.StdHttpTransport,
    settings: Settings,
    stderr: *std.Io.Writer,
    ollama_adapter: *embedding.OllamaEmbedder,
    openai_adapter: *embedding.OpenAIEmbedder,
) ?embedding.Embedder {
    switch (settings.embedding_backend) {
        .ollama => {
            if (!tryInitOllama(allocator, http_client, settings.embedding_url, settings.embedding_model, stderr)) {
                return null;
            }
            ollama_adapter.* = .{
                .transport = http_client.transport(),
                .base_url = settings.embedding_url,
                .model = settings.embedding_model,
            };
            return ollama_adapter.embedder();
        },
        .openai => {
            openai_adapter.* = .{
                .transport = http_client.transport(),
                .base_url = settings.embedding_url,
                .api_key = settings.embedding_api_key,
                .model = settings.embedding_model,
            };
            return openai_adapter.embedder();
        },
    }
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
            error.ModelNotFound => {
                _ = stderr.print("note: Ollama model '{s}' is not installed. Falling back to lexical search.\n", .{ollama_model}) catch {};
                _ = stderr.flush() catch {};
                return false;
            },
            error.ModelWarmupFailed => {
                _ = stderr.print("note: Ollama model '{s}' is installed but could not be started. Falling back to lexical search.\n", .{ollama_model}) catch {};
                _ = stderr.flush() catch {};
                return false;
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
        var w = std.Io.File.stderr().writer(runtime.io(), &buf);
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

    const use_color = runtime.getEnvVarOwned(allocator, "NO_COLOR") == error.EnvironmentVariableNotFound;

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
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(runtime.io(), ".", allocator);
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

    std.Io.Dir.cwd().access(runtime.io(), full_path, .{}) catch {
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

    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(runtime.io(), ".", allocator);
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
    std.Io.Dir.cwd().access(runtime.io(), old_path, .{}) catch {
        try stdout.print("error: old path does not exist: {s}\n", .{old_path});
        try stdout.flush();
        std.process.exit(1);
    };

    // Validate new path doesn't exist
    std.Io.Dir.cwd().access(runtime.io(), new_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {}, // good
        else => {},
    };
    // If new path exists, error
    if (std.Io.Dir.cwd().access(runtime.io(), new_path, .{})) |_| {
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
        std.Io.Dir.cwd().createDirPath(runtime.io(), dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                // Try creating parent directories
                const parent = try allocator.dupe(u8, dir);
                defer allocator.free(parent);
                std.Io.Dir.cwd().createDirPath(runtime.io(), parent) catch {};
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
        \\Search options (by default, only the CURRENT directory's project is searched):
        \\  --top <n>                     Number of results (default 10)
        \\  --all                         Search across every project (not just the current one)
        \\  --project <path>              Limit to a project by name or partial path
        \\                                (case-insensitive; '/' matches the stored '-')
        \\  --role <user|assistant>        Filter by message role
        \\  --since <YYYY-MM-DD>          Only results on/after this date
        \\  --until <YYYY-MM-DD>          Only results on/before this date
        \\  --date <YYYY-MM-DD>           Only results on this exact day
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
        \\  CHATSCAN_IGNORE=<a:b:c>       Colon-separated path fragments to exclude from
        \\                                indexing (adds to the built-in default that
        \\                                skips claude-mem observer sessions)
        \\
        \\Global options:
        \\  --db <path>                   SQLite database path
        \\  --conversation-dir <path>     Conversation files directory
        \\  CHATSCAN_DB=<path>            Env var alternative to --db
        \\  CHATSCAN_CONVERSATION_DIR=<path>
        \\                                Env var alternative to --conversation-dir
        \\                                (CLI flags override env vars override config)
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
    var w = std.Io.File.stderr().writer(runtime.io(), &buf);
    try printUsage(&w.interface);
}
