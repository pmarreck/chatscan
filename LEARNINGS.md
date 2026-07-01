---
purpose: Durable, hard-won lessons about this codebase and its toolchain for future agents/humans
audience: both
maintained_by: agent
---

# Learnings

## sqlite-vec traps under optimization; Debug hides it (2026-07-01)

`chatscan <query>` (default hybrid / `--mode vector`) crashed with
`Trace/BPT trap: 5` (SIGTRAP) in **ReleaseFast** builds, while Debug worked
fine. Root cause: `sqlite-vec` 0.1.7-alpha's vec0 vtable operations (both
embedding **insert** and KNN **search**) contain undefined behaviour that
Zig's C UBSan compiles to a trap under ReleaseFast/ReleaseSafe. At `-O0`
(Debug) the offending path is tolerated, so the whole class was invisible to
the default test run.

- **Fix:** `build.zig` sets `sanitize_c = .off` on the `sqlite3` and
  `sqlite_vec0` dependency artifacts. The behaviour is benign in practice
  (Debug produces correct results), so suppressing the C UBSan trap on these
  battle-tested third-party libs is the right call.
- **Why the tests didn't catch it:** no test exercised vec0 ops, *and*
  `zig build test` defaults to Debug (`standardOptimizeOption`). Two blind
  spots stacked. Guards added: an in-memory vector-search test + an
  embedding-insert path test, and `./test` now runs `-Doptimize=ReleaseSafe`
  (matching `flake.nix`'s Garnix check) so the trap-class actually bites.
- **General lesson:** for a Zig project wrapping third-party C, a Debug-only
  test loop can hide real release crashes. Run the suite at ReleaseSafe (keeps
  Zig safety checks *and* C UBSan traps) at least in CI, and make sure tests
  actually call into the C dependency's hot paths.
