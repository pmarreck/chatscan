# Mistakes

- 2026-07-10: An initially under-scoped patch inserted `CHATSCAN_ZIG_TARGET` into the package build instead of the test derivation because both phases had the same cache setup lines. An immediate targeted `rg` inspection caught it before testing; the fix used the `checks.test` block as unique patch context.
- 2026-07-10: Interim progress entries used projected rather than observed completion times and briefly landed in the future. Corrected them against the shell clock before commit and marked reconstructed times as estimated.
- 2026-07-10: The first conflict integration preserved the richer remote runner's `nix develop -c zig build` command without rechecking it against the canonical top-level-script rule. Parent review caught the violation; a permanent entrypoint-set contract now rejects that command and requires ordinary `./test` to route through the Nix check.
