#!/usr/bin/env bash
# tests/feature-2344-concern-carrier.sh
# Tests: bin/lib/concern-ledger.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/render.sh, bin/concern-ledger
# Tags: concern-ledger, concerns-log, carrier, render-concerns-log, issue-2344, TL1, scope:issue-specific, pwsh-not-required, dup-group-keep:size-hard-limit
# dup-group-keep:size-hard-limit: D-suite total = dispatcher(117) + sub-files(508) = 625
# lines. Appending all content to bin-concern-ledger-parse-allowlist.sh (237 lines)
# would produce 862 lines > 500 HARD (append-vs-new.md condition b). find-tests-for-
# source.sh sees only the dispatcher (excluded=-; 237+117=354<500) because Pattern A
# sub-files are staged separately; WARNINGS_ACCEPTED covers this tool limitation.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$AGENTS_ROOT/bin/lib/concern-ledger.sh"
CLI="$AGENTS_ROOT/bin/concern-ledger"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL+1)); fi
}

assert_eq_nz() {
    local name="$1" want="$2" got="$3"
    if [ -z "$want" ]; then
        echo "FAIL: $name — expected value could not be computed (empty); implementation likely missing"
        FAIL=$((FAIL+1)); return
    fi
    assert_eq "$name" "$want" "$got"
}

assert_contains() {
    local name="$1" needle="$2" hay="$3"
    if printf '%s' "$hay" | grep -Fq -- "$needle"; then pass "$name"
    else echo "FAIL: $name — output does not contain $(printf '%q' "$needle")"; FAIL=$((FAIL+1)); fi
}

assert_not_contains() {
    local name="$1" needle="$2" hay="$3"
    if printf '%s' "$hay" | grep -Fq -- "$needle"; then
        echo "FAIL: $name — output unexpectedly contains $(printf '%q' "$needle")"; FAIL=$((FAIL+1))
    else pass "$name"; fi
}

# Fixture isolation: dual-pinned plans dir, no inherited session id.
TMPDIR_BASE=$(mktemp -d)
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
unset CLAUDE_ENV_FILE 2>/dev/null || true
export AGENTS_CONFIG_DIR="$AGENTS_ROOT"
mkdir -p "$TMPDIR_BASE/work"
cd "$TMPDIR_BASE" || exit 1

run_cli() { bash "$CLI" "$@"; }

# Ledger-v2 fixture builders (schema: ID|SEV|STATE|FIRST|LAST|SLOT|DISCRIM|ORIGIN|PRODUCERS|FLAGS|TEXT).
mk_ledger() { printf '#concern-ledger-v2|%s|%s|cycle=%s\n' "$2" "$3" "$4" > "$1"; }
add_entry() {
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}" >> "$1"
}

# Single library load — all helpers available in this shell after this point.
LIB_LOADED=0
if [[ -f "$LIB" ]]; then
    set +u; if source "$LIB" >/dev/null 2>&1; then LIB_LOADED=1; fi; set -u
fi
if [[ "$LIB_LOADED" -eq 1 ]]; then
    set +u; cl_sha256 "carrier-suite-probe" >/dev/null 2>&1 || true; set -u
fi

# Implementation presence — FAIL (not SKIP) keeps the suite non-zero until /write-code.
for _f in "$LIB" "$CLI"; do
    [[ -f "$_f" ]] || fail "implementation missing: ${_f#"$AGENTS_ROOT/"}"
done

discrim_of() {
    [[ "$LIB_LOADED" -eq 1 ]] || { printf ''; return; }
    set +u; cl_discrim "$1"; set -u
}
slot_of() {
    [[ "$LIB_LOADED" -eq 1 ]] || { printf 'b00000000'; return; }
    set +u; cl_slot_body "$1"; set -u
}

# carrier_path_for <plans-dir> <session-id> <format>
# Mirrors _cl_carrier_from_ledger: <plans-dir>/<sid>-<fmt>-concern-carrier.md
carrier_path_for() { printf '%s/%s-%s-concern-carrier.md' "$1" "$2" "$3"; }

# ---------------------------------------------------------------------------
# Cases live in a sibling folder per rules/coding/file-split.md Pattern A; each
# file is sourced (not executed) so it shares the fixture + helpers above.
# ---------------------------------------------------------------------------
SUITE_DIR="$AGENTS_ROOT/tests/feature-2344-concern-carrier"

# shellcheck source=./feature-2344-concern-carrier/render-resolve.sh
. "$SUITE_DIR/render-resolve.sh"
# shellcheck source=./feature-2344-concern-carrier/reject-durability.sh
. "$SUITE_DIR/reject-durability.sh"
# shellcheck source=./feature-2344-concern-carrier/merge-and-exit.sh
. "$SUITE_DIR/merge-and-exit.sh"
# shellcheck source=./feature-2344-concern-carrier/reject-cli.sh
. "$SUITE_DIR/reject-cli.sh"

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && { echo "All tests passed."; exit 0; }
exit 1
