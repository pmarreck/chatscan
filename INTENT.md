# Project intent

## Purpose and users

chatscan helps developers recover useful evidence from local AI coding-agent conversation history. It serves people who need to find prior decisions, explanations, commands, and project context across multiple agent clients without rereading entire transcripts.

## Desired outcomes

- Index supported clients' current conversation formats into one local search database while preserving source, speaker, session, project, timestamp, and raw-record provenance.
- Return useful lexical and optional semantic matches quickly, with explicit project scope and honest freshness limits.
- Provide byte-bounded, raw-verified evidence retrieval for agents after context compaction.
- Keep incremental indexing safe to rerun and expire records whose source logs disappeared.

## Scope and non-goals

Source adapters, local indexing, search, bounded recall, source expansion, watching, and explicit project-rename migration are in scope. Optional local or OpenAI-compatible embedding services may improve ranking, but lexical search must remain useful without them.

chatscan does not treat a keyword match as proof of a final decision, execute transcript content, or mutate raw logs except through an explicitly requested rename operation. Unsupported legacy formats may be detected and reported; their owning client remains responsible for upgrading them.

## Constraints and tradeoffs

- Raw client metadata outranks encoded directory names when identifying projects and sessions.
- Visible user and assistant messages are indexed; reasoning, tool traffic, hooks, system notifications, and synthetic summaries stay excluded unless a future source contract explicitly classifies them otherwise.
- Missing, changed, truncated, or ambiguous raw sources fail closed for exact evidence.
- Persisted indexes and transcripts are user data. Changes require safe migration, recoverability, or explicit approval.
- The CLI targets macOS aarch64, Linux aarch64/x86_64, and Windows aarch64/x86_64.

## Success evidence

`./test` is the complete required test entry point. Source adapters use synthetic current-schema fixtures, set-classifier tests for filters and exclusions, isolated databases, and repeat-run tests for incremental behavior. Mechatron Prime CI evaluates the declared package and test targets from the exact pushed commit.

Current work and sequencing live in [PLAN.md](PLAN.md). User-facing behavior and commands live in [README.md](README.md).
