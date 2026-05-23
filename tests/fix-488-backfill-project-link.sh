#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKFILL_SCRIPT="$REPO_ROOT/bin/github-issues/migration/backfill-project-link.sh"
GH_MOCK="$REPO_ROOT/tests/fixtures/migration/gh-mock.sh"

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 30 "$@"
  else perl -e 'alarm 30; exec @ARGV' -- "$@"; fi
}

TMPROOT=""
setup_fixture() {
    TMPROOT="$(mktemp -d)"
    mkdir -p "$TMPROOT/bin"
    printf '#!/bin/bash\nexec "%s" "$@"\n' "$GH_MOCK" > "$TMPROOT/bin/gh"
    chmod +x "$TMPROOT/bin/gh"
    export PATH="$TMPROOT/bin:$PATH"
    export MOCK_LOG="$TMPROOT/gh-mock.log"
    export MOCK_COUNTER="$TMPROOT/gh-mock-counter"
    : > "$MOCK_LOG"
}
teardown_fixture() {
    rm -rf "$TMPROOT"
    unset MOCK_LOG MOCK_COUNTER 2>/dev/null || true
    TMPROOT=""
}

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "PASS: $1"; }
ng() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
assert() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else ng "$n"; fi; }

# B1: happy path — link called, rc=0, NO state file in CWD
setup_fixture
tmp="$(mktemp -d)"
_rc=0
( cd "$tmp" && run_with_timeout bash "$BACKFILL_SCRIPT" \
    --project-node-id PVT_kwDOmock --owner mockowner --repo mockrepo ) >/dev/null 2>&1 || _rc=$?
assert "B1 backfill exits 0" [ "$_rc" = "0" ]
assert "B1 link mutation called" grep -qE 'linkProjectV2ToRepository' "$MOCK_LOG"
assert "B1 no state file in CWD" [ ! -f "$tmp/.migration-state.json" ]
rm -rf "$tmp"
teardown_fixture

# B2: missing --project-node-id → rc!=0
setup_fixture
set +e
run_with_timeout bash "$BACKFILL_SCRIPT" --owner mockowner --repo mockrepo >/dev/null 2>&1
RC=$?; set -e
assert "B2 missing --project-node-id fails" [ "$RC" != "0" ]
teardown_fixture

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
