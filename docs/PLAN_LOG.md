# PLAN log

Completed PLAN.md items retired by plan-retire, oldest retirement first.

## Retired 2026-10-14

- [x] [Plan] Confirm which activity resets the watcher idle timeout: a successful pass that indexes or deletes files; searches and no-op polls do not reset it — completed 2026-08-05 10:56 EDT.
- [x] [Plan] Confirm and report the default `chatscan watch` idle timeout: `30m`; `never` disables retirement — completed 2026-08-05 10:54 EDT.
- [x] [Plan] Ported codescan self-suiciding watcher to chatscan (`chatscan watch`) — done 2026-07-29 20:20 EDT. retirement.zig (pure policy) + watch.zig (polling loop, injected clock) + CLI `watch`/--interval/--idle-timeout + config watcher_interval/watcher_idle_timeout + SIGINT/SIGTERM graceful stop. TDD: retirement suite, RetirementTracker mock-clock test, cli parse test, and a bounded CLI e2e proving self-termination.
- [x] [Plan] Make RRF ranking weights configurable (config keys weight_vector/weight_lexical/weight_recency + --weight-* CLI flags + CHATSCAN_WEIGHT_* env; flag>env>config>default; defaults unchanged 1.0/1.0/0.3) so a weak embedding model can be dialed down instead of dominating. Done 2026-07-28 22:30 EDT. TDD: config parse, cli parse (incl. reject non-numeric), and a search.zig behavioral test proving vector-heavy vs lexical-heavy flips the winner.
- [x] [Plan] Exclude observer/meta noise: configurable ignore-list (default-skips claude-mem observer-sessions; extend via CHATSCAN_IGNORE). Index-time skip + auto-purge of previously-indexed rows via the delete-sweep. Verified on a real-index COPY: observer purged, real convs intact, real index untouched. Done 2026-07-28 13:46 EDT. Files stay on disk (still mineable).
- [x] [Plan] Show LLM source (claude/codex/gemini) on each hit via LlmSource.fromPath — [source] tag in human output + JSON source field. Done 2026-07-28 13:32 EDT.
- [x] [Plan] Fix hybrid search burying exact-term matches under recent-but-irrelevant conversations (the "Ghostty window" complaint): replace the weighted raw-score sum with **Reciprocal Rank Fusion** across vector+lexical+recency rankers; recency demoted to a low-weight tiebreaker; fixed the dedup bug that silently dropped a vector hit's lexical signal. Red test `hybrid ranks an exact-term match above recent semantically-adjacent noise` first, then green; dogfooded on the real index (top-8 went from unrelated `tiffz` to a coherent Ghostty set) — completed 2026-07-27 20:30 EDT.
  - Curiosity poke: does RRF's tight score-clustering break the ratio-based `score_dropoff` gate?
- [x] [Plan] Adversarial code review of the scoring algorithm — completed 2026-07-27 21:16 EDT. Found F1 (one conversation floods 7/10 slots), F2 (`score_dropoff` a no-op under RRF), F3 (vector candidates bypass filter pushdown), F4 (multi-term FTS ORs tokens). The BDFN (Benevolent Dictator For Now) chose to fix all four.
- [x] [Plan] F1: dedup to best message per conversation — done 2026-07-27 21:20 EDT. Real index: "Ghostty window" top-10 now 10 DISTINCT conversations (was 7 fragments of one).
- [x] [Plan] F2: recalibrate `score_dropoff` for RRF — done 2026-07-27 21:47 EDT. Hybrid cuts at a fixed fraction of the theoretical-max fused score (1/rrf_k), top_n-stable; total_relevant converges (~25) instead of growing with --top (was 64+).
- [x] [Plan] F3: filtered vector search via scalar-distance full scan (vec_distance_l2) — done 2026-07-27 21:33 EDT.
- [x] [Plan] F4: conjunctive (AND) multi-term FTS with OR fallback — done 2026-07-27 21:22 EDT.
- [x] [Plan] F7 (found during F2 work): fixed inverted --mode lexical ranking — normalize on bm25 MAGNITUDE (|bm25|/(1+|bm25|)) so stronger matches score higher. Red test confirmed weakest-first, green after. Done 2026-07-27 21:50 EDT.
- [x] [Plan] Fix repeated `chatscan index` runs that report configured Ollama model `bge-m3` is loading without initiating or observing a load — completed 2026-07-24 11:11 EDT.
  - Curiosity poke: does readiness confuse “installed but not resident,” “actively loading,” and “unavailable,” and can its advice actually advance each state?
- [x] [Plan] Reconcile the detached commit and `mechatron-ci-integration` into `yolo` without losing the exact staged cleanup — completed 2026-07-24 09:25 EDT (estimated).
  - Curiosity poke: do hidden `refs/jj/keep/*` contain unique trees that are absent from the reconciled history?
- [x] [Plan] Fix the shared memories skill so `.codescan/` search-index internals are ignored by title listing and frontmatter validation (blocks metadata recall) — completed 2026-07-24 09:29 EDT.
  - Curiosity poke: are other generated hidden directories recursively misclassified even though root-level hidden files are already ignored?
- [x] [Plan] Reproduce `chatscan rg` failing because `zig-out/bin/chatscan` requests an unavailable musl loader, then add a persistent regression test and repair the build/install path — completed 2026-07-24 09:39 EDT.
  - Curiosity poke: can a cross-compiled artifact silently replace the host-native PATH binary after `build_all` or a Nix build?
- [x] [Plan] Complete the Mechatron Prime CI integration: exact targets manifest, canonical dynamic README badge, webhook audit/provisioning, push, and live PASSING verification — completed 2026-07-24 09:57 EDT.
  - [x] Add and locally verify the exact package/check target set and canonical dynamic badge — completed 2026-07-24 09:47 EDT.
  - [x] Confirm the existing active webhook, push `yolo`, and verify exact commit `590184f` reaches `PASSING` — completed 2026-07-24 09:57 EDT.
  - Curiosity poke: does the exact pushed SHA expose both selected flake targets, and does the public badge follow that build rather than stale state?
- [x] [Plan] Add a failing CI-contract test for a real sandboxed suite — completed 2026-07-10 11:27 EDT (estimated).
  - Curiosity poke: can a check still pass by printing a success marker without executing Zig?
- [x] [Plan] Add `checks.x86_64-linux.test` and make `./test` the full-suite entrypoint — completed 2026-07-10 11:28 EDT (estimated).
  - Curiosity poke: do pure Nix sandboxes provide script interpreters and ELF loaders at global filesystem paths?
- [x] [Plan] Make Linux test executables baseline-portable and runnable in the sandbox — completed 2026-07-10 11:34 EDT (estimated).
  - Curiosity poke: does the contract prove the exact target/CPU/test arguments and failure propagation?
- [x] [Plan] Run the complete sandboxed test suite and independent package build — completed 2026-07-10 11:36 EDT.
  - Curiosity poke: are the final results reproducible after documentation and metadata enter the flake source?
- [x] [Plan] Integrate current `origin/yolo` without losing its ReleaseSafe and CLI suites — completed 2026-07-10 11:58 EDT (estimated).
  - Curiosity poke: does the sandbox runner continue into CLI tests after a Zig failure, proving group accumulation?
- [x] [Plan] Re-run `./test`, `./build`, and `nix flake check` after conflict resolution — completed 2026-07-10 12:13 EDT.
  - Curiosity poke: does the pure sandbox contain every CLI tool the richer suite needs?
- [x] [Plan] Permanently ban native Zig through `nix develop` in top-level entrypoints and route ordinary `./test` through the Nix check — completed 2026-07-10 12:19 EDT (estimated).
  - Curiosity poke: are `--no-build` and the live-Ollama boundary still described truthfully across the pure/marked-direct split?
- [x] [Active] Add native Grok Build indexing through `--llm grok` and `--all-llms`, preserving authoritative session/project identity and visible ACP roles. (done 2026-10-14 19:20 EDT; commit `1732c6e`; context: [docs/plan_context/grok-indexing.md](docs/plan_context/grok-indexing.md))
	- [x] TDD root resolution, summary discovery, canonical metadata, missing-install no-op, and fail-closed duplicate session IDs. (done 2026-10-14 16:05 EDT)
	- [x] TDD ACP visible-message reconstruction while excluding reasoning, tools, hooks, plugins, and synthetic records. (done 2026-10-14 16:05 EDT)
	- [x] TDD unchanged reruns, append-only updates, incomplete trailing JSONL, and source-scoped stale-record expiry. (done 2026-10-14 16:05 EDT)
	- [x] Wire CLI/config/help/docs and run the complete `./test` gate. (done 2026-10-14 16:22 EDT)
	- [x] Commit, push, report the candidate to Einstein, and verify exact-commit Mechatron Prime CI. (done 2026-10-14 19:20 EDT; commit `1732c6e`)
- [x] [Recent completions] Added byte-bounded raw-verified `recall` and `expand`, with exact scope, stable references, and duplicate-free continuation. (done 2026-09-16 18:52 EDT; commit `0d27d73`)
- [x] [Recent completions] Repaired current-format rename discovery, stale-index expiry, and nonblocking confirmation input. (done 2026-08-05 12:23 EDT)
