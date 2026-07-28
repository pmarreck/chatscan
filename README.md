# chatscan

[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Fchatscan.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)
[![Build](https://github.com/pmarreck/chatscan/actions/workflows/build.yml/badge.svg?branch=yolo)](https://github.com/pmarreck/chatscan/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Search your AI coding conversation history with semantic + lexical + recency search.

Supports **Claude Code**, **Codex**, and **Gemini CLI** conversations. Indexes them into SQLite (with FTS5 + optional vector embeddings via **Ollama** or any **OpenAI-compatible** server like **oMLX**) and provides fast hybrid search with recency weighting.

## Quick start

```bash
# Index your conversations (auto-detects Claude, Codex, or Gemini)
chatscan index

# Search (scoped to current project by default)
chatscan "SIMD optimization"

# Search all projects
chatscan "error handling" --all

# Search across all LLM sources
chatscan "error handling" --all-llms

# Regex search via ripgrep
chatscan --regex "indexOfIgnoreCase"

# JSON output
chatscan "config" --json
```

## Features

- **Multi-LLM support** — indexes Claude (`~/.claude/projects/`), Codex (`~/.codex/sessions/`), and Gemini (`~/.gemini/tmp/`) conversations
- **Hybrid search** — semantic (vector), lexical (FTS5), and recency signals fused by **Reciprocal Rank Fusion** (RRF), which ranks by rank-position rather than combining incomparable raw scores, so a strong match in any one signal reliably surfaces
- **Recency as a gentle tiebreaker** — recent conversations get a mild boost (a low-weight RRF ranker), not enough to bury an exact-term match under recent-but-irrelevant chatter
- **Sandwich display** — matched message shown bold, with previous/next messages dimmed for context
- **Auto-scoping (with escape hatches)** — searches are scoped to the current directory's project by default, and say so on stderr; use `--all` to search everything or `--project <name-or-partial-path>` to target another project
- **Env-var overrides** — `CHATSCAN_DB` and `CHATSCAN_CONVERSATION_DIR` (plus `CHATSCAN_LLM`) override paths without flags; CLI flags override env vars override config
- **Incremental indexing** — only re-indexes changed files based on mtime
- **Project rename** — rename a project directory and update all conversation logs in one command
- **Regex fallback** — `--regex` shells out to ripgrep against raw JSONL files
- **Pluggable embedding backends** — Ollama (default) or any OpenAI-compatible server (oMLX, LM Studio, vLLM, etc.)
- **Env-var expansion in config** — `${VAR}` / `${VAR:-default}` so secrets like API keys stay out of committed configs
- **Graceful degradation** — works without an embedder (lexical-only), warns and falls back automatically

## Installation

### With Nix (recommended)

```bash
nix run github:pmarreck/chatscan -- "your query"

# Or install into your profile
nix profile install github:pmarreck/chatscan
```

### From source

Requires Zig 0.15+ and SQLite amalgamation:

```bash
git clone https://github.com/pmarreck/chatscan.git
cd chatscan
nix develop  # sets up all dependencies
zig build -Doptimize=ReleaseFast
./zig-out/bin/chatscan help
```

## Testing

Run the complete suite through the repository's sandboxed Nix check:

```bash
./test
```

`./test --no-build` skips the separate package artifact build, but the pure
check still builds its own private CLI before running integration tests.

Mechatron Prime CI builds `packages.x86_64-linux.default` and evaluates
`checks.x86_64-linux.test` from the exact pushed commit. The check calls the
same `./test` entrypoint inside the Nix sandbox, builds the CLI and runs the Zig
suite in ReleaseSafe, then runs the Bash CLI integration suite. Linux binaries
target static musl with `-Dcpu=baseline` so they remain portable across
builders.

The deterministic suite still discovers the two live-Ollama tests, but points
them at an unavailable loopback port so their existing `SkipZigTest` path makes
the external service boundary explicit. An ordinary `./test` is a pure Nix
build, so host environment variables cannot opt it into a local service. For an
explicit x86_64 Linux live-service run, enter the dev shell and invoke the
marked direct path:

```bash
nix develop
CHATSCAN_IN_NIX_CHECK=1 \
  CHATSCAN_ZIG_TARGET=x86_64-linux-musl \
  CHATSCAN_TEST_OLLAMA_URL=http://localhost:11434 \
  ./test
```

Use `aarch64-linux-musl` on ARM Linux; leave `CHATSCAN_ZIG_TARGET` unset on
Darwin.

## Usage

```
chatscan <query>              Search conversations (implicit)
chatscan search <query>       Search conversations
chatscan index                Index/update conversation database
chatscan rename <old> <new>   Rename project dir + update all logs
chatscan config               Show configuration
chatscan help                 Show this help

Search options (by default, only the CURRENT directory's project is searched):
  --top <n>                     Number of results (default 10)
  --all                         Search across every project (not just the current one)
  --project <path>              Limit to a project by name or PARTIAL PATH
                                (case-insensitive; '/' in the filter matches the stored '-')
  --role <user|assistant>       Filter by message role
  --since <YYYY-MM-DD>           Only results on/after this date
  --until <YYYY-MM-DD>           Only results on/before this date
  --date <YYYY-MM-DD>            Only results on this exact day (--since == --until)
  --regex                       Use ripgrep for regex search
  --mode <vector|lexical|hybrid> Search mode (default hybrid)
  --context-lines <n>           Lines to show per message (default 4)
  --json                        JSON output

LLM source options:
  --llm <claude|codex|gemini>   Select LLM source (default: auto-detect)
  --all-llms                    Search across all available LLM sources
  CHATSCAN_LLM=<value>          Env var alternative (claude|codex|gemini|all)

Index options:
  --reindex                     Force full re-index

Global options:
  --db <path>                   SQLite database path (env: CHATSCAN_DB)
  --conversation-dir <path>     Conversation files directory (env: CHATSCAN_CONVERSATION_DIR)
  --ollama-url <url>            Ollama server URL (backend=ollama)
  --ollama-model <name>         Embedding model name (backend=ollama)
  --backend <ollama|openai|mlx> Embedding backend (default: ollama)
  --embedding-url <url>         Override embedding server URL
  --embedding-model <name>      Override embedding model name
  --embedding-api-key <key>     API key for OpenAI-compatible backend
  --embedding-dim <n>           Embedding dimension
```

### Scope: current project vs. everything

By default `chatscan <query>` searches **only the project for the current
directory** (matched by the cwd, with symlinks resolved), and prints a note to
stderr saying so. If a search comes back empty, chatscan explains *why* on
stderr rather than leaving you guessing:

```bash
chatscan html
# note: limiting to the current project (-Users-you-Code-myproj). Use --all to
#       search every project, or --project <path> to pick another.
# note: no matches in the current project. Re-run with --all to search all projects.

chatscan html --all                 # search every indexed project
chatscan html --project validate    # by name (case-insensitive, partial)
chatscan html --project Code/validate   # by partial path ('/' matches the stored '-')
```

> Tip: if you moved/renamed a project directory (e.g. via a symlink), its older
> conversations may be stored under the *previous* path. `--all`, or a
> `--project` fragment common to both paths, will find them.

### Environment overrides

Paths can be set by env var instead of flags — handy for scripting and tests.
Precedence is **CLI flag → env var → config file → built-in default**:

```bash
export CHATSCAN_DB=/tmp/scratch-index.sqlite3
export CHATSCAN_CONVERSATION_DIR=/path/to/fixture/conversations
chatscan index
chatscan "query" --all
```

## Multi-LLM support

chatscan auto-detects which LLM sources are available on your system:

| LLM | Conversation directory | Format |
|-----|----------------------|--------|
| Claude Code | `~/.claude/projects/` | JSONL per session |
| Codex | `~/.codex/sessions/YYYY/MM/DD/` | JSONL with event_msg wrappers |
| Gemini CLI | `~/.gemini/tmp/*/chats/` | JSON with messages array |

```bash
# Index only Codex conversations
chatscan --llm codex index

# Search only Gemini conversations
chatscan --llm gemini "build system"

# Index and search across all LLMs
chatscan --all-llms index
chatscan --all-llms "error handling" --all

# Or set via environment variable
export CHATSCAN_LLM=all
chatscan index
chatscan "your query"
```

## Project rename

Rename a project directory and update all LLM conversation logs to match:

```bash
# Full paths
chatscan rename /path/to/old-name /path/to/new-name

# Basename shortcut (stays in same parent directory)
chatscan rename /path/to/old-name new-name

# Relative paths work too
chatscan rename ./old-name ./new-name

# From inside the project directory
chatscan rename ../old-name ../new-name

# Skip confirmation prompt
chatscan rename old-name new-name --force
```

Before making any changes, chatscan shows a detailed plan:

```
chatscan rename: the following changes will be made:

  Project directory:
    mv /Users/you/projects/old-name
     → /Users/you/projects/new-name

  Claude conversations:
    rename ~/.claude/projects/-Users-you-projects-old-name/
         → ~/.claude/projects/-Users-you-projects-new-name/
    (47 files)

  Codex sessions:
    update cwd in 12 session files

  Gemini:
    update .project_root in 2 project dirs

  chatscan index:
    update 834 indexed messages

Proceed? [y/N]
```

## Configuration

Config file: `$XDG_CONFIG_HOME/chatscan/config` (default `~/.config/chatscan/config`)

```
conversation_dir = ~/.claude/projects
db_path = ~/.local/share/chatscan/index.sqlite3

# Ollama backend (default)
embedding_backend = ollama
ollama_url = http://localhost:11434
ollama_model = bge-large
embedding_dim = 1024

# Or OpenAI-compatible backend (oMLX, LM Studio, vLLM, etc.)
# embedding_backend = openai            # "mlx" and "omlx" also accepted
# embedding_url = http://localhost:10240
# embedding_model = text-embedding-3-small
# embedding_api_key = ${OMLX_API_KEY}   # env var expansion supported
```

### Env-var expansion in config

Values support shell-style expansion so secrets can stay out of committed configs:

| Form          | Behavior                                           |
|---------------|----------------------------------------------------|
| `$VAR`        | simple reference                                   |
| `${VAR}`      | braced reference                                   |
| `${VAR:-DEF}` | default if `VAR` is unset **or empty**             |
| `${VAR-DEF}`  | default if `VAR` is **unset only**                 |
| `$$`          | literal `$`                                        |

For secret fields (e.g. `embedding_api_key`), chatscan remembers the raw `${VAR}` text so future config rewrites preserve the placeholder rather than baking in the resolved value.

## Embedding backends

### Ollama (default)

For vector-based semantic search, install and run [Ollama](https://ollama.ai) with an embedding model:

```bash
ollama pull bge-large
chatscan index    # will generate embeddings
chatscan "your query" --mode hybrid
```

### oMLX / OpenAI-compatible

Any OpenAI-compatible `/v1/embeddings` endpoint works — oMLX, LM Studio, vLLM, the real OpenAI API, etc.

```bash
# Flags
chatscan --backend mlx \
         --embedding-url http://localhost:10240 \
         --embedding-model text-embedding-3-small \
         --embedding-api-key sk-your-key \
         index

# Env vars
export CHATSCAN_EMBEDDING_BACKEND=mlx
export CHATSCAN_EMBEDDING_API_KEY=sk-your-key
chatscan index
```

`mlx` and `omlx` are accepted as aliases for `openai` everywhere the backend is named.

Without Ollama, chatscan falls back to FTS5 lexical search automatically.

## License

[MIT](LICENSE)
