# Plan

- [x] Add a failing CI-contract test for a real sandboxed suite — completed 2026-07-10 11:27 EDT (estimated).
  - Curiosity poke: can a check still pass by printing a success marker without executing Zig?
- [x] Add `checks.x86_64-linux.test` and make `./test` the full-suite entrypoint — completed 2026-07-10 11:28 EDT (estimated).
  - Curiosity poke: do pure Nix sandboxes provide script interpreters and ELF loaders at global filesystem paths?
- [x] Make Linux test executables baseline-portable and runnable in the sandbox — completed 2026-07-10 11:34 EDT (estimated).
  - Curiosity poke: does the contract prove the exact target/CPU/test arguments and failure propagation?
- [x] Run the complete sandboxed test suite and independent package build — completed 2026-07-10 11:36 EDT.
  - Curiosity poke: are the final results reproducible after documentation and metadata enter the flake source?
- [x] Integrate current `origin/yolo` without losing its ReleaseSafe and CLI suites — completed 2026-07-10 11:58 EDT (estimated).
  - Curiosity poke: does the sandbox runner continue into CLI tests after a Zig failure, proving group accumulation?
- [x] Re-run `./test`, `./build`, and `nix flake check` after conflict resolution — completed 2026-07-10 12:13 EDT.
  - Curiosity poke: does the pure sandbox contain every CLI tool the richer suite needs?
- [x] Permanently ban native Zig through `nix develop` in top-level entrypoints and route ordinary `./test` through the Nix check — completed 2026-07-10 12:19 EDT (estimated).
  - Curiosity poke: are `--no-build` and the live-Ollama boundary still described truthfully across the pure/marked-direct split?
