---
purpose: Durable, hard-won lessons about this codebase and its toolchain for future agents/humans
audience: both
maintained_by: agent
---

# Learnings

## sqlite-vec function-pointer UB → SIGTRAP in Release builds (2026-07-01)

`chatscan <query>` (default hybrid / `--mode vector`) crashed with
`Trace/BPT trap: 5` (SIGTRAP) in **ReleaseFast** builds while Debug worked.

- **Root cause (found via clang `-fsanitize=undefined` on a minimal repro):**
  `sqlite-vec.c:8323` called `fvec_cleanup_noop` / `sqlite3_free` **through a
  function pointer of the wrong type** — `fvec_cleanup` was `void(*)(f32*)`
  while the call site used `void(*)(void*)`. Calling a function through an
  incompatible pointer type is genuine C undefined behaviour. Zig's C UBSan
  (`-fsanitize=function`, on in Release/trap mode) traps on it; hence the
  message-less SIGTRAP inside `sqlite3_step`.
- **Why Debug didn't catch it (corrected):** it is NOT optimization-triggered
  (clang flags it at `-O0` too). Zig's **Debug** C-sanitizer set omits the
  `function` check while its **Release** (trap) set includes it. The check-set,
  not the opt level, is what differs.
- **Why it went unnoticed:** local builds default to Debug (`build.zig` uses
  `standardOptimizeOption`), *and* no test exercised vec0 insert/KNN, so even
  CI's ReleaseSafe run stayed green. It only surfaced when a Release binary ran
  a vector search. Surfaced "now" because the Zig 0.16 migration set the current
  toolchain whose Release trap-set includes `function` — not new code.
- **Real fix:** upstream sqlite-vec fixed this exact UB (unified `fvec_cleanup`
  with `vector_cleanup` as `void(*)(void*)`) by v0.1.10. We bumped our fork
  pmarreck/sqlite-vec from v0.1.7-alpha.2 -> v0.1.10-alpha.4 (disabling the new
  DISKANN/RESCORE companion .c files we don't use), rewired build.zig.zon + the
  flake zigDepsHash, and **removed** the interim `sanitize_c = .off` band-aid.
  ReleaseSafe tests now pass with the sanitizer fully on — the UB is gone, not
  hidden.
- **General lesson:** a Debug-only test loop can hide real Release crashes in
  third-party C. Run the suite at ReleaseSafe (Zig safety checks + C UBSan) in
  CI, and make sure tests actually call into the C dependency's hot paths. When
  UBSan fires on a dependency, prefer fixing/upgrading the UB over suppressing.

## Pure Nix sandbox execution (2026-07-10)

- 2026-07-10: A pure Nix build sandbox has neither `/usr/bin/env` nor the host's `/lib64` dynamic loader. Invoke repository scripts with the Nix-provided `bash`, and compile Linux test executables for a static musl target with `-Dcpu=baseline` when they must run during the derivation.
- 2026-07-10: The Zig/Nix hook supplies `-Dcpu=baseline` for its default phases, but a custom `buildPhase` must state that portability contract explicitly.
- 2026-07-10: The live-Ollama tests are discovered in the deterministic suite but must use their existing `SkipZigTest` path when no service is provisioned. Because ordinary `./test` routes through a pure Nix derivation, host variables cannot reach it; `CHATSCAN_TEST_OLLAMA_URL` is truthful only with the explicitly marked `CHATSCAN_IN_NIX_CHECK=1` direct path inside a provisioned dev shell. CI never silently depends on a builder-local Ollama instance or model inventory.
