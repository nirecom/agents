#!/usr/bin/env bash
# tests/install/feature-3102-npm-update.sh
# Tests: install/linux/npm.sh, install/lib/npm-engine-check.js
# Tags: installer, npm-update, node-stub, TL2, scope:issue-specific, test-lang-exception:e2e
# #3102: real npm.sh (bash entry) -> real node + npm-engine-check.js; PATH-first stub npm supplies the range.
# Two cases only (minimum-test constraint): range met -> npm install runs; range unmet -> skipped with a manual command. rc 0.

# TL3 gap (what this test does NOT catch):
# - package-manager / non-writable prefix skips and a failing `npm install` (environment-dependent, checked by hand)
# - real npm replacing itself, and the absence of the npm update notice after the Codex step
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category: installer.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

NPM_SH="$SCRIPT_CHECKOUT_ROOT/install/linux/npm.sh"

T="$(make_tmp)"
trap 'rm -rf "$T"' EXIT
harness_isolate "$T/iso"

# Writable fixture the stub reports as the npm global root / prefix (the writability check must pass).
mkdir -p "$T/stub-bin" "$T/root/npm" "$T/prefix/bin" "$T/no-nvm-parent"
export NPM_STUB_LOG="$T/npm-calls.log"
export NPM_STUB_ROOT="$T/root"
export NPM_STUB_PREFIX="$T/prefix"
printf '%s\n' \
  '#!/bin/bash' \
  'echo "npm $*" >> "$NPM_STUB_LOG"' \
  'case "$1 $2" in' \
  '  "root -g") echo "$NPM_STUB_ROOT" ;;' \
  '  "prefix -g") echo "$NPM_STUB_PREFIX" ;;' \
  '  "view npm@latest") echo "$NPM_STUB_RANGE" ;;' \
  'esac' \
  'exit 0' > "$T/stub-bin/npm"
chmod +x "$T/stub-bin/npm"

# run_npm_step <engines.node range> — sets OUT (stdout+stderr), RC, CALLS (stub log).
run_npm_step() {
  : > "$NPM_STUB_LOG"
  OUT="$(NPM_STUB_RANGE="$1" NVM_DIR="$T/no-nvm-parent/absent" PATH="$T/stub-bin:$PATH" \
    run_with_timeout 120 bash "$NPM_SH" 2>&1 < /dev/null)"
  RC=$?
  CALLS="$(cat "$NPM_STUB_LOG")"
}

case_begin "compatible-node-runs-npm-install" "install/linux/npm.sh"
run_npm_step ">=1.0.0"
assert_eq "$RC" "0"
case "$CALLS" in
  *"install -g npm@latest"*) pass "range satisfied: npm install -g npm@latest was called" ;;
  *) fail "range satisfied: npm install -g npm@latest was called" "calls=$CALLS out=$OUT" ;;
esac
case_end

case_begin "incompatible-node-skips-with-manual-command" "install/lib/npm-engine-check.js"
run_npm_step ">=999.0.0"
assert_eq "$RC" "0"
case "$CALLS" in
  *"install -g"*) fail "range not satisfied: npm install must not be called" "calls=$CALLS" ;;
  *) pass "range not satisfied: npm install was not called" ;;
esac
case "$OUT" in
  *"npm install -g npm@latest"*) pass "skip warning carries the manual npm install -g npm@latest command" ;;
  *) fail "skip warning carries the manual npm install -g npm@latest command" "out=$OUT" ;;
esac
case_end

case_begin "pick-highest-version-of-major-satisfying-range" "install/lib/npm-engine-check.js"
ENGINE_CHECK="$SCRIPT_CHECKOUT_ROOT/install/lib/npm-engine-check.js"
PICKED="$(printf 'v24.14.0\nv24.15.0\nv25.0.0\n' | node "$ENGINE_CHECK" --pick '^22.22.2 || ^24.15.0 || >=26.0.0' 24)"
PICK_RC=$?
assert_eq "$PICK_RC" "0"
assert_eq "$PICKED" "24.15.0"
NONE="$(printf 'v24.14.0\nv24.14.1\n' | node "$ENGINE_CHECK" --pick '^24.15.0' 24)"
NONE_RC=$?
assert_eq "$NONE_RC" "1"
assert_eq "$NONE" ""
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
