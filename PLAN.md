# PLAN

Open work is ordered below. Completed history is in [docs/PLAN_LOG.md](docs/PLAN_LOG.md); stable purpose is in [INTENT.md](INTENT.md).

## Active

- [ ] Add native Grok Build indexing through `--llm grok` and `--all-llms`, preserving authoritative session/project identity and visible ACP roles. (context: [docs/plan_context/grok-indexing.md](docs/plan_context/grok-indexing.md))
	- [x] TDD root resolution, summary discovery, canonical metadata, missing-install no-op, and fail-closed duplicate session IDs. (done 2026-10-14 16:05 EDT)
	- [x] TDD ACP visible-message reconstruction while excluding reasoning, tools, hooks, plugins, and synthetic records. (done 2026-10-14 16:05 EDT)
	- [x] TDD unchanged reruns, append-only updates, incomplete trailing JSONL, and source-scoped stale-record expiry. (done 2026-10-14 16:05 EDT)
	- [x] Wire CLI/config/help/docs and run the complete `./test` gate. (done 2026-10-14 16:22 EDT)
	- [ ] Commit, push, report the candidate to Einstein, and verify exact-commit Mechatron Prime CI.

## Deferred

- [ ] Decide whether to retain or Trash local experimental embedding-index backups after the active model choice is settled.
- [ ] Evaluate observer-session records as possible curated memory source material; keep observer noise excluded from normal search.

## Recent completions

- [x] Added byte-bounded raw-verified `recall` and `expand`, with exact scope, stable references, and duplicate-free continuation. (done 2026-09-16 18:52 EDT; commit `0d27d73`)
- [x] Repaired current-format rename discovery, stale-index expiry, and nonblocking confirmation input. (done 2026-08-05 12:23 EDT)
