#!/usr/bin/env bash
# tests/refactor-1692-hooks-lib-orphan-dirs.sh
# Tests: hooks/supervisor-guard.js, hooks/supervisor-guard/arbitrate.js, hooks/supervisor-guard/collect-audit-triggers.js, hooks/supervisor-guard/format-integrated.js
# Tags: refactor, file-split, supervisor-guard, scope:issue-specific, pwsh-not-required, TL1
#
# Issue #1692 — the three supervisor-guard submodules moved out of the shared
# hooks/lib/ tree into hooks/supervisor-guard/
# (rules/coding/file-split.md Pattern A: entrypoint-private modules live in a
# sibling <name>/ folder, not the shared lib/). C1-C5 assert the move landed
# whole: directory placement, internal requires still resolving, and zero stale
# references left behind.
#
# L3 gap (what this test does NOT catch):
# - The moved modules being reached through a real Claude Code Stop hook
#   invocation (settings.json entry actually firing hooks/supervisor-guard.js)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
SELF_BASENAME="$(basename "${BASH_SOURCE[0]}")"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

# The pre-move path is assembled at runtime so this file never contains the
# literal string C4 greps for (otherwise the test would flag itself).
OLD_DIR_REF="hooks/lib/""supervisor-guard"

# ---------------------------------------------------------------------------
# C1: hooks/supervisor-guard/ exists; the pre-move directory under the shared
#     lib/ tree does NOT (moved, not copied)
# ---------------------------------------------------------------------------
run_C1() {
    local new_dir="$AGENTS_DIR/hooks/supervisor-guard"
    local old_dir="$AGENTS_DIR/$OLD_DIR_REF"
    if [ -d "$new_dir" ] && [ ! -e "$old_dir" ]; then
        pass "C1: hooks/supervisor-guard/ exists and the pre-move lib/ directory is gone"
    else
        fail "C1: expected new dir present + old dir absent (new=$([ -d "$new_dir" ] && echo yes || echo no), old=$([ -e "$old_dir" ] && echo present || echo absent))"
    fi
}

# ---------------------------------------------------------------------------
# C2: every moved module require()s cleanly from the repo root — proves the
#     internal relative requires inside the moved folder survived the move
# ---------------------------------------------------------------------------
run_C2() {
    local out
    out=$(cd "$AGENTS_DIR" && "$RWT" 15 node -e "
require('./hooks/supervisor-guard/arbitrate');
require('./hooks/supervisor-guard/collect-audit-triggers');
require('./hooks/supervisor-guard/format-integrated');
process.stdout.write('OK');" 2>&1)
    if [ "$out" = "OK" ]; then
        pass "C2: all three moved modules require cleanly from repo root"
    else
        fail "C2: moved-module require failed; got: $out"
    fi
}

# ---------------------------------------------------------------------------
# C3: collect-audit-triggers.js's require of the schema module resolves after
#     the move (Risk #3 — the relative-require depth changed by one level)
# ---------------------------------------------------------------------------
run_C3() {
    local out src
    src="$AGENTS_DIR/hooks/supervisor-guard/collect-audit-triggers.js"
    if [ ! -f "$src" ]; then
        fail "C3: hooks/supervisor-guard/collect-audit-triggers.js not found"
        return
    fi
    # a) the literal require path in the source points at the post-move location
    if grep -q 'require("\.\./lib/supervisor-state-schema")' "$src"; then
        pass "C3a: collect-audit-triggers.js requires ../lib/supervisor-state-schema (post-move depth)"
    else
        fail "C3a: expected require(\"../lib/supervisor-state-schema\") in $src"
    fi
    # b) the require actually resolves and yields the expected exports
    out=$(cd "$AGENTS_DIR" && "$RWT" 15 node -e "
const s = require('./hooks/supervisor-guard/collect-audit-triggers');
const sc = require('./hooks/lib/supervisor-state-schema');
const ok = typeof s.collectAuditCandidates === 'function' &&
  sc.AUDIT_SEVERITY_THRESHOLD !== undefined && sc.SEVERITY_RANK !== undefined;
process.stdout.write(ok ? 'OK' : 'BAD');" 2>&1)
    if [ "$out" = "OK" ]; then
        pass "C3b: the schema require resolves and collectAuditCandidates is exported"
    else
        fail "C3b: schema require did not resolve post-move; got: $out"
    fi
}

# ---------------------------------------------------------------------------
# C4: zero stale references to the pre-move path anywhere in the repo
#     (excludes .git/, node_modules/, and this test file itself)
# ---------------------------------------------------------------------------
run_C4() {
    local hits
    hits=$(cd "$AGENTS_DIR" && grep -rn \
        --exclude-dir=.git --exclude-dir=node_modules --exclude="$SELF_BASENAME" \
        -e "$OLD_DIR_REF" . 2>/dev/null || true)
    if [ -z "$hits" ]; then
        pass "C4: zero stale references to the pre-move path across the repo"
    else
        fail "C4: stale pre-move references remain:
$hits"
    fi
}

# ---------------------------------------------------------------------------
# C5: the C2-consumer entrypoint hooks/supervisor-guard.js loads as a Node
#     module (its top-level requires of the moved folder resolve)
# ---------------------------------------------------------------------------
run_C5() {
    local out
    out=$(cd "$AGENTS_DIR" && "$RWT" 15 node -e "
require('./hooks/supervisor-guard');
process.stdout.write('OK');" </dev/null 2>&1)
    if [ "$out" = "OK" ]; then
        pass "C5: hooks/supervisor-guard.js entrypoint requires cleanly"
    else
        fail "C5: entrypoint require failed; got: $out"
    fi
}

run_C1
run_C2
run_C3
run_C4
run_C5

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
