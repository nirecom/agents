#!/bin/bash
# Tests: bin/github-issues/migration/state.sh
# Tags: history, docs, github, issues, bin
# Tests for state.sh schema v2 + advanced helpers (issue #415).
#
# RED: this suite fails until state.sh is upgraded to:
#   - schema_version: 2 (with auto-upgrade from v1 in state_load)
#   - state_set_advanced <kind> <stage>  (idempotent timestamp write)
#   - state_get_advanced <kind> <stage>  (empty when missing)
#
# Advanced block layout (post-impl):
#   .<kind>.advanced.<stage>   (e.g. .history.advanced.canary_1)

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_SH="$AGENTS_DIR/bin/github-issues/migration/state.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

if [ ! -f "$STATE_SH" ]; then
    echo "FAIL: $STATE_SH not found"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# shellcheck disable=SC1090
source "$STATE_SH"

# --- a. state_set_advanced is idempotent ---
TMPDIR_A="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_A" "${TMPDIR_B:-}" "${TMPDIR_C:-}"' EXIT
state_init "$TMPDIR_A" >/dev/null 2>&1 || true
state_load "$TMPDIR_A" >/dev/null 2>&1 || true

if ! declare -F state_set_advanced >/dev/null; then
    fail "a: state_set_advanced is defined"
else
    state_set_advanced history canary_1 >/dev/null 2>&1
    V1=$(jq -r '.history.advanced.canary_1 // empty' "$TMPDIR_A/.migration-state.json" 2>/dev/null)
    state_set_advanced history canary_1 >/dev/null 2>&1
    V2=$(jq -r '.history.advanced.canary_1 // empty' "$TMPDIR_A/.migration-state.json" 2>/dev/null)
    if [ -n "$V1" ] && [ "$V1" = "$V2" ]; then
        pass "a: state_set_advanced idempotent (V1=V2=$V1)"
    else
        fail "a: state_set_advanced idempotent (V1=$V1 V2=$V2)"
    fi
fi

# --- b. state_get_advanced returns empty for missing stage ---
TMPDIR_B="$(mktemp -d)"
state_init "$TMPDIR_B" >/dev/null 2>&1 || true
state_load "$TMPDIR_B" >/dev/null 2>&1 || true
if ! declare -F state_get_advanced >/dev/null; then
    fail "b: state_get_advanced is defined"
else
    OUT=$(state_get_advanced history canary_1 2>/dev/null || true)
    if [ -z "$OUT" ]; then
        pass "b: state_get_advanced returns empty when stage not set"
    else
        fail "b: state_get_advanced expected empty, got: '$OUT'"
    fi
fi

# --- c. state_load auto-upgrades schema v1 -> v2 ---
TMPDIR_C="$(mktemp -d)"
V1_STATE="$TMPDIR_C/.migration-state.json"
jq -n '{
  schema_version: 1,
  repo_dir: "/fake/repo",
  started_at: "2026-05-01T00:00:00Z",
  current_step: 2,
  history: {
    total_entries: 3,
    migrated: [
      {entry_id: "e1", issue_number: 1, title: "T1"},
      {entry_id: "e2", issue_number: 2, title: "T2"},
      {entry_id: "e3", issue_number: 3, title: "T3"}
    ]
  },
  todo: {total_entries: 0, migrated: [], todo_md_rewritten: false},
  project: {number: null, node_id: null, field_ids: {}}
}' > "$V1_STATE"

if state_load "$TMPDIR_C" >/dev/null 2>&1; then
    VER=$(jq -r '.schema_version' "$V1_STATE" 2>/dev/null)
    if [ "$VER" = "2" ]; then
        pass "c1: state_load auto-upgrades schema_version to 2"
    else
        fail "c1: schema_version expected 2, got '$VER'"
    fi

    COUNT=$(state_count_migrated history 2>/dev/null || echo "?")
    if [ "$COUNT" = "3" ]; then
        pass "c2: migrated[] preserved across upgrade (count=3)"
    else
        fail "c2: migrated[] expected count=3, got '$COUNT'"
    fi

    if declare -F state_get_advanced >/dev/null; then
        ADV=$(state_get_advanced history canary_1 2>/dev/null || true)
        if [ -z "$ADV" ]; then
            pass "c3: advanced.canary_1 absent (null treated as not-set)"
        else
            fail "c3: advanced.canary_1 expected empty, got '$ADV'"
        fi
    else
        fail "c3: state_get_advanced is defined"
    fi
else
    fail "c: state_load accepts v1 and auto-upgrades (rejected v1 instead)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
