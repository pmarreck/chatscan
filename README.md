# chatscan

[![Garnix](https://img.shields.io/endpoint.svg?url=https://garnix.io/api/badges/pmarreck/chatscan/yolo)](https://garnix.io)
[![Build](https://github.com/pmarreck/chatscan/actions/workflows/build.yml/badge.svg?branch=yolo)](https://github.com/pmarreck/chatscan/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Search your Claude Code conversation history with semantic + lexical search.

Claude Code stores all conversation transcripts as `.jsonl` files under `~/.claude/projects/`. These accumulate quickly and contain valuable context — past solutions, debugging sessions, architectural decisions. **chatscan** indexes them into SQLite (with FTS5 + optional vector embeddings via Ollama) and provides fast hybrid search.

## Quick start

```bash
# Index your conversations
chatscan index

# Search (scoped to current project by default)
chatscan "SIMD optimization"

# Search all projects
chatscan "error handling" --all

# Regex search via ripgrep
chatscan --regex "indexOfIgnoreCase"

# JSON output
chatscan "config" --json
```

## Features

- **Hybrid search** — FTS5 lexical search + optional bge-large vector embeddings via Ollama
- **Sandwich display** — matched message shown bold, with previous/next messages dimmed for context
- **Auto-scoping** — searches are scoped to the current project by default (falls back to all if no conversations exist for cwd)
- **Incremental indexing** — only re-indexes changed files based on mtime
- **Regex fallback** — `--regex` shells out to ripgrep against raw JSONL files
- **Graceful degradation** — works without Ollama (lexical-only), warns and falls back automatically

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

## Usage

```
chatscan <query>              Search conversations (implicit)
chatscan search <query>       Search conversations
chatscan index                Index/update conversation database
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

Index options:
  --reindex                     Force full re-index

Global options:
  --db <path>                   SQLite database path
  --conversation-dir <path>     Conversation files directory
  --ollama-url <url>            Ollama server URL
  --ollama-model <name>         Embedding model name
  --embedding-dim <n>           Embedding dimension
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
