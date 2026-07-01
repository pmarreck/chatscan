#!/usr/bin/env bash
# CLI integration tests for chatscan search behaviour.
#
# Exercises the real binary end-to-end against a committed conversation fixture
# and a freshly-built index. Covers the scoping/filtering surface that unit
# tests can't reach: default current-project scoping, --all, --project partial
# path/name matching, env-var overrides, and verbose messaging.
#
# No Ollama required: indexing populates FTS regardless of embedder availability,
# and every search here runs with `--mode lexical` so results are deterministic.
#
# Per house rules: `set -u` only (NOT `set -e` — we assert on non-zero exits
# ourselves). Exit code = number of failed assertions.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
BIN="${CHATSCAN_BIN:-$REPO_ROOT/zig-out/bin/chatscan}"
# Absolutize BIN: several tests `cd` into temp dirs, so a relative path would break.
case "$BIN" in /*) ;; *) BIN="$(cd "$(dirname "$BIN")" && pwd -P)/$(basename "$BIN")" ;; esac
FIX="$SCRIPT_DIR/fixtures/conversations"

FAILS=0
pass() { printf '  ok   - %s\n' "$1"; }
fail() { FAILS=$((FAILS + 1)); printf '  FAIL - %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '           %s\n' "$2" >&2; }

assert_eq() { # expected actual desc
	if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "expected [$1], got [$2]"; fi
}
assert_contains() { # haystack needle desc
	case "$1" in
		*"$2"*) pass "$3" ;;
		*) fail "$3" "expected to contain [$2], got [$1]" ;;
	esac
}

# --- Preconditions -----------------------------------------------------------
if [ ! -x "$BIN" ]; then
	echo "chatscan binary not found/executable at $BIN — run ./build first" >&2
	exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
	echo "jq not found — run this via 'nix develop -c bash $0'" >&2
	exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chatscan-cli.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

DB="$WORK/index.sqlite3"

# All invocations share these; individual tests may override via flags/env.
export CHATSCAN_LLM=claude

# Helper: run a search and print the result count (results[] length).
count() { # query [extra args...]
	CHATSCAN_DB="$DB" CHATSCAN_CONVERSATION_DIR="$FIX" \
		"$BIN" "$@" --mode lexical --json 2>/dev/null | jq '.results | length'
}
# Helper: run a search and print sorted, comma-joined distinct project names.
names() { # query [extra args...]
	CHATSCAN_DB="$DB" CHATSCAN_CONVERSATION_DIR="$FIX" \
		"$BIN" "$@" --mode lexical --json 2>/dev/null | jq -r '.results[].project_name' | sort -u | paste -sd, -
}

echo "== chatscan CLI integration tests =="

# --- 1. Index the fixture ----------------------------------------------------
idx_out="$(CHATSCAN_DB="$DB" CHATSCAN_CONVERSATION_DIR="$FIX" "$BIN" index --embedding-url http://127.0.0.1:1 2>&1)"
idx_rc=$?
assert_eq 0 "$idx_rc" "index fixture exits 0"
assert_contains "$idx_out" "5 messages" "index reports 5 messages across 3 fixture projects"

# --- 2. --all finds matches across every project (the reproduction) ----------
assert_eq 2 "$(count html --all)" "html --all returns both projects that mention html"
assert_eq "alpha,beta" "$(names html --all)" "html --all spans alpha and beta (not gamma)"

# --- 3. --project narrows by exact name --------------------------------------
assert_eq 1 "$(count html --project alpha)" "--project alpha narrows to one result"
assert_eq "alpha" "$(names html --project alpha)" "--project alpha selects only alpha"

# --- 4. --project narrows by PARTIAL path fragment (/ ~ - normalization) ------
assert_eq 1 "$(count html --project fixture-beta)" "--project partial slug 'fixture-beta' matches"
assert_eq "beta" "$(names html --project fixture-beta)" "--project 'fixture-beta' selects only beta"
assert_eq 1 "$(count html --project Fixture/Beta)" "--project 'Fixture/Beta' (path form, case-insensitive) matches beta"

# --- 5. A distinctive term is found in the right project ----------------------
assert_eq 1 "$(count dirtree --all)" "dirtree --all finds the single dirtree mention"
assert_eq "alpha" "$(names dirtree --all)" "dirtree lives in alpha"

# --- 6. Non-matching --project is empty AND verbose about why -----------------
gamma_err="$(CHATSCAN_DB="$DB" CHATSCAN_CONVERSATION_DIR="$FIX" "$BIN" html --project gamma --mode lexical 2>&1 >/dev/null)"
assert_eq 0 "$(count html --project gamma)" "html in gamma yields no results"
assert_contains "$gamma_err" "no matches for --project 'gamma'" "empty --project search explains itself on stderr"
assert_contains "$gamma_err" "--all" "empty --project search suggests --all"

# --- 7. Env-var overrides work with NO path flags ----------------------------
env_count="$(CHATSCAN_DB="$DB" CHATSCAN_CONVERSATION_DIR="$FIX" "$BIN" html --all --mode lexical --json 2>/dev/null | jq '.results | length')"
assert_eq 2 "$env_count" "CHATSCAN_DB + CHATSCAN_CONVERSATION_DIR drive search with no --db/--conversation-dir flags"

# --- 8. Default current-project scoping actually scopes (Peter's exact bug) ---
# Build a second index where one project's slug equals THIS test's real cwd slug,
# plus an unrelated project sharing the same search term. Default (no --all)
# must return only the current project's hit and announce the scoping.
SCOPE_CONV="$WORK/scopeconv"
PROJ="$WORK/proj/scopeproj"
mkdir -p "$PROJ"
REAL="$(cd "$PROJ" && pwd -P)"
SLUG="$(printf '%s' "$REAL" | sed 's:/:-:g')"     # /a/b -> -a-b, matching detectCurrentProjectDir
mkdir -p "$SCOPE_CONV/$SLUG" "$SCOPE_CONV/-unrelated-other"
cat > "$SCOPE_CONV/$SLUG/s.jsonl" <<JSONL
{"type":"user","timestamp":"2026-04-01T10:00:00Z","sessionId":"s1","cwd":"$REAL","message":{"role":"user","content":[{"type":"text","text":"sharedscopeword appears in the current project"}]}}
JSONL
cat > "$SCOPE_CONV/-unrelated-other/o.jsonl" <<JSONL
{"type":"user","timestamp":"2026-04-01T10:00:00Z","sessionId":"o1","cwd":"/somewhere/other","message":{"role":"user","content":[{"type":"text","text":"sharedscopeword also appears over here in another project"}]}}
JSONL

SDB="$WORK/scope.sqlite3"
CHATSCAN_DB="$SDB" CHATSCAN_CONVERSATION_DIR="$SCOPE_CONV" "$BIN" index --embedding-url http://127.0.0.1:1 >/dev/null 2>&1

# --all sees both projects.
all_scope="$(cd "$REAL" && CHATSCAN_DB="$SDB" CHATSCAN_CONVERSATION_DIR="$SCOPE_CONV" "$BIN" sharedscopeword --all --mode lexical --json 2>/dev/null | jq '.results | length')"
assert_eq 2 "$all_scope" "--all sees the term in both projects"

# Default (no --all), run from inside the project dir: scoped to just this one.
scope_out="$(cd "$REAL" && CHATSCAN_DB="$SDB" CHATSCAN_CONVERSATION_DIR="$SCOPE_CONV" "$BIN" sharedscopeword --mode lexical --json 2>"$WORK/scope.err")"
scope_count="$(printf '%s' "$scope_out" | jq '.results | length')"
scope_err="$(cat "$WORK/scope.err")"
assert_eq 1 "$scope_count" "default search scopes to the current project only"
assert_contains "$scope_err" "limiting to the current project" "default scoping announces itself on stderr"

# --- 9. Missing query is a clear error, not a silent nothing ------------------
noq_err="$(CHATSCAN_DB="$DB" CHATSCAN_CONVERSATION_DIR="$FIX" "$BIN" --project alpha 2>&1 >/dev/null)"
assert_contains "$noq_err" "error" "a search with no query text reports a clear error"

# --- 10. Date filtering: --date / --since / --until over the fixture ----------
# Fixture html mentions: alpha=2026-03-01, beta=2026-03-02 (gamma has none).
assert_eq 1 "$(count html --all --date 2026-03-01)" "--date 2026-03-01 keeps only the Mar-1 (alpha) html hit"
assert_eq "alpha" "$(names html --all --date 2026-03-01)" "--date 2026-03-01 selects alpha"
assert_eq 1 "$(count html --all --since 2026-03-02)" "--since 2026-03-02 drops the earlier alpha hit"
assert_eq "beta" "$(names html --all --since 2026-03-02)" "--since 2026-03-02 keeps beta"
assert_eq 1 "$(count html --all --until 2026-03-01)" "--until 2026-03-01 keeps only alpha"
assert_eq 2 "$(count html --all --since 2026-03-01 --until 2026-03-02)" "--since/--until range spans alpha+beta"
assert_eq 0 "$(count html --all --date 2026-03-03)" "--date 2026-03-03 (gamma day) has no html"

# Invalid date is a clear error, not a silent empty result.
date_err="$(CHATSCAN_DB="$DB" CHATSCAN_CONVERSATION_DIR="$FIX" "$BIN" html --since 2026-13-99 2>&1 >/dev/null)"
assert_contains "$date_err" "YYYY-MM-DD" "an invalid --since date reports a clear format error"

# --- Summary -----------------------------------------------------------------
echo
if [ "$FAILS" -eq 0 ]; then
	echo "CLI: all assertions passed"
else
	echo "CLI: $FAILS assertion(s) failed" >&2
fi
exit "$FAILS"
