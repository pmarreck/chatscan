#!/usr/bin/env bash

# Prove the exact package artifact installed by ./build executes on this host.
set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
binary="${CHATSCAN_BIN:-$root/zig-out/bin/chatscan}"

output="$("$binary" --about 2>&1)"
status=$?
if [ "$status" -ne 0 ]; then
	printf 'FAIL: built package artifact is not executable (exit %d)\n' "$status" >&2
	printf '%s\n' "$output" >&2
	exit 1
fi

if [ -z "$output" ]; then
	printf '%s\n' 'FAIL: chatscan --about returned no description' >&2
	exit 1
fi

printf '%s\n' 'PASS: built package artifact executes on this host'
