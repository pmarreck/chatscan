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
# Invoked by the EXIT trap below.
# shellcheck disable=SC2329
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

# --- 11. Bounded, source-verified recall and expansion -----------------------
help_out="$("$BIN" --help 2>/dev/null)"
assert_contains "$help_out" "chatscan recall" "help documents bounded recall"
assert_contains "$help_out" "chatscan expand" "help documents reference expansion"
assert_contains "$help_out" "--project-exact" "help documents canonical project scope"
assert_contains "$help_out" "--max-bytes" "help documents the serialized byte bound"
assert_contains "$help_out" "--cursor" "help documents expansion continuation"

recall_json="$WORK/recall.json"
CHATSCAN_DB="$DB" CHATSCAN_CONVERSATION_DIR="$FIX" \
	"$BIN" recall html --project-exact /proj/alpha --max-bytes 1400 >"$recall_json" 2>"$WORK/recall.err"
recall_rc=$?
recall_bytes="$(wc -c <"$recall_json" | tr -d ' ')"
assert_eq 0 "$recall_rc" "project-exact recall exits 0 without an embedding service"
if jq -e . "$recall_json" >/dev/null 2>&1; then pass "recall stdout is independently valid JSON"; else fail "recall stdout is independently valid JSON"; fi
assert_eq "$recall_bytes" "$(jq -r '.serialized_bytes' "$recall_json")" "recall reports the externally measured final stdout bytes"
if [ "$recall_bytes" -le 1400 ]; then pass "recall obeys the final serialized byte limit"; else fail "recall obeys the final serialized byte limit" "emitted $recall_bytes bytes"; fi
assert_eq "chatscan/recall-v1" "$(jq -r '.schema' "$recall_json")" "recall exposes its versioned schema"
assert_eq 1 "$(jq -r '.results | length' "$recall_json")" "exact project recall cannot leak beta's matching hit"
assert_eq /proj/alpha "$(jq -r '.results[0].project' "$recall_json")" "recall reports source-owned canonical project"
assert_eq a1 "$(jq -r '.results[0].session_id' "$recall_json")" "recall reports source-owned session identity"
assert_eq false "$(jq -r '.absence_is_proof' "$recall_json")" "recall never presents absence as proof"

session_json="$WORK/session-recall.json"
CHATSCAN_DB="$DB" CHATSCAN_CONVERSATION_DIR="$FIX" \
	"$BIN" recall html --session b1 --max-bytes 1400 >"$session_json" 2>"$WORK/session-recall.err"
assert_eq 1 "$(jq -r '.results | length' "$session_json")" "exact session recall selects one matching transcript"
assert_eq /proj/beta "$(jq -r '.results[0].project' "$session_json")" "exact session recall does not leak another session"

empty_json="$WORK/empty-recall.json"
CHATSCAN_DB="$DB" CHATSCAN_CONVERSATION_DIR="$FIX" \
	"$BIN" recall html --project-exact /proj/gamma --max-bytes 1400 >"$empty_json" 2>"$WORK/empty-recall.err"
assert_eq 0 "$(jq -r '.results | length' "$empty_json")" "no-hit recall returns an honest empty result set"
assert_eq false "$(jq -r '.absence_is_proof' "$empty_json")" "no-hit recall still disclaims proof of absence"

ref="$(jq -r '.results[0].ref' "$recall_json")"
expand_json="$WORK/expand.json"
CHATSCAN_DB="$DB" CHATSCAN_CONVERSATION_DIR="$FIX" \
	"$BIN" expand "$ref" --before 0 --after 1 --max-bytes 4000 >"$expand_json" 2>"$WORK/expand.err"
expand_rc=$?
expand_bytes="$(wc -c <"$expand_json" | tr -d ' ')"
assert_eq 0 "$expand_rc" "source expansion exits 0"
if jq -e . "$expand_json" >/dev/null 2>&1; then pass "expand stdout is independently valid JSON"; else fail "expand stdout is independently valid JSON"; fi
assert_eq "$expand_bytes" "$(jq -r '.serialized_bytes' "$expand_json")" "expand reports the externally measured final stdout bytes"
if [ "$expand_bytes" -le 4000 ]; then pass "expand obeys the final serialized byte limit"; else fail "expand obeys the final serialized byte limit" "emitted $expand_bytes bytes"; fi
assert_eq current "$(jq -r '.source_status.index' "$expand_json")" "expand reports current index freshness separately from raw verification"
assert_eq "how do I render html output in the browser|the dirtree command gives a nice project overview" "$(jq -r '[.messages[].chunk.text] | join("|")' "$expand_json")" "expand preserves chronological surrounding turns"

loose_err="$(CHATSCAN_DB="$DB" CHATSCAN_CONVERSATION_DIR="$FIX" "$BIN" recall html --project alpha 2>&1 >/dev/null)"
loose_rc=$?
if [ "$loose_rc" -ne 0 ]; then pass "recall rejects loose project scope"; else fail "recall rejects loose project scope"; fi
assert_contains "$loose_err" "does not accept loose --project" "loose project failure explains the exact-scope requirement"

scope_err="$(CHATSCAN_DB="$DB" CHATSCAN_CONVERSATION_DIR="$FIX" "$BIN" recall html 2>&1 >/dev/null)"
scope_rc=$?
if [ "$scope_rc" -ne 0 ]; then pass "recall requires an explicit exact scope"; else fail "recall requires an explicit exact scope"; fi
assert_contains "$scope_err" "requires --project-exact" "missing scope failure lists accepted scopes"

tiny_out="$WORK/tiny-recall.out"
CHATSCAN_DB="$DB" CHATSCAN_CONVERSATION_DIR="$FIX" \
	"$BIN" recall html --all --max-bytes 10 >"$tiny_out" 2>"$WORK/tiny-recall.err"
tiny_rc=$?
tiny_err="$(cat "$WORK/tiny-recall.err")"
if [ "$tiny_rc" -ne 0 ]; then pass "a budget smaller than the envelope fails nonzero"; else fail "a budget smaller than the envelope fails nonzero"; fi
assert_eq 0 "$(wc -c <"$tiny_out" | tr -d ' ')" "tiny-budget failure emits no oversized stdout"
assert_contains "$tiny_err" "BudgetTooSmall" "tiny-budget failure is explicit"

cursor_err="$(CHATSCAN_DB="$DB" CHATSCAN_CONVERSATION_DIR="$FIX" "$BIN" expand "$ref" --cursor malformed --max-bytes 1400 2>&1 >/dev/null)"
cursor_rc=$?
if [ "$cursor_rc" -ne 0 ]; then pass "malformed continuation cursor fails nonzero"; else fail "malformed continuation cursor fails nonzero"; fi
assert_contains "$cursor_err" "InvalidCursor" "malformed cursor failure is explicit"

# --- LLM source provenance tag (F: derive from file_path) --------------------
src_json="$(CHATSCAN_DB="$DB" CHATSCAN_CONVERSATION_DIR="$FIX" "$BIN" html --all --mode lexical --json 2>/dev/null | jq -r ".results[0].source")"
assert_eq "claude" "$src_json" "json output tags each hit with source=claude (fixtures live under a claude-style path)"

src_human="$(CHATSCAN_DB="$DB" CHATSCAN_CONVERSATION_DIR="$FIX" "$BIN" html --all --mode lexical 2>/dev/null)"
assert_contains "$src_human" "[claude]" "human output shows the [claude] source tag"

# --- watch: self-suiciding daemon retires on idle --------------------------
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || echo "")"
if [ -n "$TIMEOUT_BIN" ]; then
	watch_db="$WORK/watch.sqlite3"
	watch_t0="$(date +%s)"
	watch_out="$(CHATSCAN_DB="$watch_db" CHATSCAN_CONVERSATION_DIR="$FIX" "$TIMEOUT_BIN" 20 "$BIN" watch --idle-timeout 2s --interval 1 --embedding-url http://127.0.0.1:1 2>&1)"
	watch_rc=$?
	watch_t1="$(date +%s)"
	assert_eq 0 "$watch_rc" "watch self-terminates on idle (exit 0, not timeout-killed)"
	assert_contains "$watch_out" "retiring after 2 seconds" "watch announces its idle retirement"
	if [ "$((watch_t1 - watch_t0))" -le 12 ]; then pass "watch retires promptly"; else fail "watch retires promptly" "took $((watch_t1-watch_t0))s"; fi
else
	pass "watch self-terminate test skipped (no timeout/gtimeout available)"
fi

# --- Summary -----------------------------------------------------------------
echo
if [ "$FAILS" -eq 0 ]; then
	echo "CLI: all assertions passed"
else
	echo "CLI: $FAILS assertion(s) failed" >&2
fi
exit "$FAILS"
