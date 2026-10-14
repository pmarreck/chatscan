# Native Grok Build indexing

An approved 2026-09-02 project request adds Grok Build as a native chatscan source without broadening the index architecture.

## Current source contract

- Resolve the client root from `GROK_HOME`, otherwise `$HOME/.grok`; sessions live under `sessions/`.
- Discover `sessions/**/summary.json`. Treat `.info.id` as session identity and `.info.cwd` as the canonical project path. Never decode identity from the parent directory when metadata exists; long paths may use a slug plus `.cwd`.
- Treat `updates.jsonl` as the authoritative ACP event stream. Its discriminator is `.params.update.sessionUpdate`.
- Reconstruct visible `user_message_chunk` and `agent_message_chunk` text in event order. Exclude thought chunks, tool calls and updates, hooks, plugin changes, system data, and synthetic material.
- `chat_history.jsonl` is non-authoritative when it disagrees with ACP updates.
- Missing Grok roots, metadata-only sessions, and missing optional fields/files are successful no-ops or empty sessions as appropriate.

## Identity and failure policy

Before mutating the Grok portion of the index, discover and sort all candidate sessions. If one `.info.id` occurs in more than one directory, reject the Grok pass before writes and emit a deterministic diagnostic listing the conflicting metadata paths. Directory slugs never break the tie. This keeps retries idempotent and avoids silently combining or replacing two sessions with one claimed identity.

An incomplete final JSONL record is ignored until a later append completes it. Previously indexed complete messages remain intact. A retry after unchanged input is a no-op; appended complete events add each logical visible message once.

## Acceptance checks

- Two encoded project groups retain distinct canonical `.info.cwd` values, including a long-cwd slug with `.cwd` present.
- Chunked visible messages reconstruct without thought, tool, hook, or plugin text.
- An unchanged second pass performs no writes; an append adds exactly one logical message.
- Missing or incomplete trailing data cannot corrupt prior indexed rows.
- Duplicate IDs fail before writes with stable ordering and a loud diagnostic.
- `GROK_HOME` override and default-root resolution are isolated and tested.
- `--all-llms` includes Grok; a Grok-specific selector follows the existing `--llm` convention.
- Synthetic fixtures contain no real transcript text.
