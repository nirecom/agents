#!/usr/bin/env bash
# Tests: bin/codegraph-lifecycle.js, bin/codegraph-lifecycle/index-health.js, bin/codegraph-lifecycle/process-identity.js
# Tags: codegraph, lifecycle, installer, env-flag, daemon, sqlite, process-identity, TL2, scope:issue-specific
# Detail plan ST-18, cases L1-L30. Layer TL2: spawns the real CLI as a process
# against synthetic roots, a synthetic AGENTS_CONFIG_DIR/.env and a PATH-injected
# recording `codegraph` stub. Every side effect stays inside this file's own
# mktemp -d tree; the real HOME, .codegraph/ and repo tree are never touched.

set -u

# TL3 gap (what this test does NOT catch):
# - whether a real `codegraph index -q` rebuilds a 0-byte / foreign-schema DB (stubbed here) - VER-5
# - whether a real daemon (running as node.exe) is identified from a real CIM query - VER-4
# - whether stopping the daemon clears the Windows EPERM on `git worktree remove` - VER-4
# - whether install/win/codegraph.ps1 runs to completion non-interactively - VER-1 / VER-2
# - whether post-checkout / post-merge fire on a real `git checkout` - VER-3
# - on win32, that a rejected pid never reaches the external query at all (the stub is unrunnable there)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: installer.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIFECYCLE_SRC="$AGENTS_DIR/bin/codegraph-lifecycle.js"
INDEX_HEALTH_SRC="$AGENTS_DIR/bin/codegraph-lifecycle/index-health.js"
IDENTITY_SRC="$AGENTS_DIR/bin/codegraph-lifecycle/process-identity.js"

PASS=0; FAIL=0; SKIPPED=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIPPED=$((SKIPPED + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-codegraph-lifecycle"

# shellcheck source=./feature-codegraph-lifecycle/harness.sh
. "$SCRIPT_DIR/harness.sh"

for src in "$LIFECYCLE_SRC" "$INDEX_HEALTH_SRC" "$IDENTITY_SRC"; do
    [ -f "$src" ] || fail "IMPLEMENTATION MISSING: ${src#"$AGENTS_DIR"/}"
done

# shellcheck source=./feature-codegraph-lifecycle/env-silence.sh
. "$SCRIPT_DIR/env-silence.sh"
# shellcheck source=./feature-codegraph-lifecycle/stop-flag-exempt.sh
. "$SCRIPT_DIR/stop-flag-exempt.sh"
# shellcheck source=./feature-codegraph-lifecycle/index-verb.sh
. "$SCRIPT_DIR/index-verb.sh"
# shellcheck source=./feature-codegraph-lifecycle/quarantine.sh
. "$SCRIPT_DIR/quarantine.sh"
# shellcheck source=./feature-codegraph-lifecycle/sync-gate.sh
. "$SCRIPT_DIR/sync-gate.sh"
# shellcheck source=./feature-codegraph-lifecycle/stop-identity.sh
. "$SCRIPT_DIR/stop-identity.sh"
# shellcheck source=./feature-codegraph-lifecycle/stop-pid.sh
. "$SCRIPT_DIR/stop-pid.sh"
# shellcheck source=./feature-codegraph-lifecycle/success-paths.sh
. "$SCRIPT_DIR/success-paths.sh"
# shellcheck source=./feature-codegraph-lifecycle/tokenizer.sh
. "$SCRIPT_DIR/tokenizer.sh"
# shellcheck source=./feature-codegraph-lifecycle/secrets.sh
. "$SCRIPT_DIR/secrets.sh"

echo ""
echo "=== Results: $PASS passed, $FAIL failed, $SKIPPED skipped ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
