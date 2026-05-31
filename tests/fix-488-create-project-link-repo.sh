#!/usr/bin/env bash
# Tests: bin/gh, bin/github-issues/migration/create-project.sh, bin/github-issues/migration/state.sh
# Tags: 488, create-project-link-repo
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_SCRIPT="$REPO_ROOT/bin/github-issues/migration/state.sh"
CREATE_SCRIPT="$REPO_ROOT/bin/github-issues/migration/create-project.sh"
GH_MOCK="$REPO_ROOT/tests/fixtures/migration/gh-mock.sh"

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 30 "$@"
  else perl -e 'alarm 30; exec @ARGV' -- "$@"; fi
}

TMPROOT=""; REPO=""
setup_fixture() {
    local has_existing="${1:-0}"
    TMPROOT="$(mktemp -d)"
    REPO="$TMPROOT/repo"
    mkdir -p "$REPO"
    # shellcheck disable=SC1090
    source "$STATE_SCRIPT"
    state_init "$REPO" >/dev/null 2>&1
    mkdir -p "$TMPROOT/bin"
    printf '#!/bin/bash\nexec "%s" "$@"\n' "$GH_MOCK" > "$TMPROOT/bin/gh"
    chmod +x "$TMPROOT/bin/gh"
    export PATH="$TMPROOT/bin:$PATH"
    export MOCK_LOG="$TMPROOT/gh-mock.log"
    export MOCK_COUNTER="$TMPROOT/gh-mock-counter"
    : > "$MOCK_LOG"
    if [ "$has_existing" = "1" ]; then export MOCK_HAS_EXISTING_PROJECT="1"
    else unset MOCK_HAS_EXISTING_PROJECT 2>/dev/null || true; fi
}
teardown_fixture() {
    rm -rf "$TMPROOT"
    unset MOCK_LOG MOCK_COUNTER MOCK_HAS_EXISTING_PROJECT MOCK_LINK_FAILS 2>/dev/null || true
    TMPROOT=""; REPO=""
}

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "PASS: $1"; }
ng() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
assert() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else ng "$n"; fi; }

# L1: new-create path
setup_fixture 0
_rc=0
run_with_timeout bash "$CREATE_SCRIPT" "$REPO" >/dev/null 2>&1 || _rc=$?
assert "L1 create-project exits 0" [ "$_rc" = "0" ]
assert "L1 linkProjectV2ToRepository called on new-create" grep -qE 'linkProjectV2ToRepository' "$MOCK_LOG"
assert "L1 repo_linked=true in state" bash -c '[ "$(jq -r .project.repo_linked "$1/.migration-state.json")" = "true" ]' _ "$REPO"
teardown_fixture

# L2: existing-reuse path (setup_fixture 1 sets MOCK_HAS_EXISTING_PROJECT=1)
setup_fixture 1
_rc=0
run_with_timeout bash "$CREATE_SCRIPT" "$REPO" >/dev/null 2>&1 || _rc=$?
assert "L2 create-project exits 0" [ "$_rc" = "0" ]
assert "L2 linkProjectV2ToRepository called on existing-reuse" grep -qE 'linkProjectV2ToRepository' "$MOCK_LOG"
assert "L2 repo_linked=true in state" bash -c '[ "$(jq -r .project.repo_linked "$1/.migration-state.json")" = "true" ]' _ "$REPO"
teardown_fixture

# L3: link failure tolerance — migration must NOT abort, repo_linked stays false
setup_fixture 0
export MOCK_LINK_FAILS=1
run_with_timeout bash "$CREATE_SCRIPT" "$REPO" >/dev/null 2>&1 || true
assert "L3 project still created despite link failure" bash -c '[ "$(jq -r .project.number "$1/.migration-state.json")" != "null" ]' _ "$REPO"
assert "L3 repo_linked=false after link failure" bash -c '[ "$(jq -r .project.repo_linked "$1/.migration-state.json")" = "false" ]' _ "$REPO"
unset MOCK_LINK_FAILS
teardown_fixture

# L4: dry-run — no linkProjectV2ToRepository in log
setup_fixture 0
run_with_timeout bash "$CREATE_SCRIPT" "$REPO" --dry-run >/dev/null 2>&1 || true
assert "L4 dry-run skips link mutation" bash -c '! grep -qE linkProjectV2ToRepository "$1"' _ "$MOCK_LOG"
teardown_fixture

# L5: skip-on-already-linked — second run skips link mutation
setup_fixture 1
run_with_timeout bash "$CREATE_SCRIPT" "$REPO" >/dev/null 2>&1 || true
: > "$MOCK_LOG"
run_with_timeout bash "$CREATE_SCRIPT" "$REPO" >/dev/null 2>&1 || true
assert "L5 second run skips link mutation when repo_linked=true" bash -c '! grep -qE linkProjectV2ToRepository "$1"' _ "$MOCK_LOG"
teardown_fixture

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
