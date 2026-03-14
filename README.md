# chatscan

[![built with garnix](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2Fpmarreck%2Fchatscan%3Fbranch%3Dyolo)](https://garnix.io)
[![Build](https://github.com/pmarreck/chatscan/actions/workflows/build.yml/badge.svg?branch=yolo)](https://github.com/pmarreck/chatscan/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Search your AI coding conversation history with semantic + lexical + recency search.

Supports **Claude Code**, **Codex**, and **Gemini CLI** conversations. Indexes them into SQLite (with FTS5 + optional vector embeddings via Ollama) and provides fast hybrid search with recency weighting.

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
- **Hybrid search** — equally weighted semantic (vector), lexical (FTS5), and recency scoring
- **Recency weighting** — recent conversations rank higher (exponential decay, 30-day half-life)
- **Sandwich display** — matched message shown bold, with previous/next messages dimmed for context
- **Auto-scoping** — searches are scoped to the current project by default (falls back to all if no conversations exist for cwd)
- **Incremental indexing** — only re-indexes changed files based on mtime
- **Project rename** — rename a project directory and update all conversation logs in one command
- **Regex fallback** — `--regex` shells out to ripgrep against raw JSONL files
- **Graceful degradation** — works without Ollama (lexical-only), warns and falls back automatically

## Installation

### With Nix (recommended)

This project uses [Nix flakes](https://nixos.wiki/wiki/Flakes), which require the `nix-command` and `flakes` experimental features to be enabled.

**One-time run (no install):**

```bash
nix --extra-experimental-features 'nix-command flakes' run github:pmarreck/chatscan -- "your query"
```

**Install into your profile:**

```bash
nix --extra-experimental-features 'nix-command flakes' profile install github:pmarreck/chatscan
```

**To avoid typing the flags every time**, add this to your `~/.config/nix/nix.conf` (or `/etc/nix/nix.conf`):

```
experimental-features = nix-command flakes
```

Then you can use the shorter form:

```bash
nix run github:pmarreck/chatscan -- "your query"
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

## Usage

```
chatscan <query>              Search conversations (implicit)
chatscan search <query>       Search conversations
chatscan index                Index/update conversation database
chatscan rename <old> <new>   Rename project dir + update all logs
chatscan config               Show configuration
chatscan help                 Show this help

Search options:
  --top <n>                     Number of results (default 10)
  --all                         Search all projects
  --project <name>              Search specific project
  --role <user|assistant>       Filter by message role
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
  --db <path>                   SQLite database path
  --conversation-dir <path>     Conversation files directory
  --ollama-url <url>            Ollama server URL
  --ollama-model <name>         Embedding model name
  --embedding-dim <n>           Embedding dimension
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
ollama_url = http://localhost:11434
ollama_model = bge-large
embedding_dim = 1024
```

## Optional: semantic search with Ollama

For vector-based semantic search, install and run [Ollama](https://ollama.ai) with an embedding model:

```bash
ollama pull bge-large
chatscan index    # will generate embeddings
chatscan "your query" --mode hybrid
```

Without Ollama, chatscan falls back to FTS5 lexical search automatically.

## License

[MIT](LICENSE)
