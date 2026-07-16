#!/usr/bin/env bash
# tests/fix-1443-1442-session-id-resolvers.sh
# Tests: hooks/lib/resolve-workflow-session-id.js, hooks/lib/workflow-state/session-id.js
# Tags: worktree-end, worktree-context, session-id, scope:issue-specific, pwsh-not-required
#
# Issue #1443 / #1442 — resolve the session id from sibling worktrees when env
# vars are absent. The detect-worktree-conflict.js hook, SKILL.md text, and
# settings.json registration (Sections A/D/E) live in
# tests/fix-1443-1442-worktree-context.sh.
#
# FAIL-BEFORE-FIX (BUGFIX session): the implementation does NOT exist yet.
#   - The sibling-worktree scan is not yet added to resolve-workflow-session-id.js
#     or workflow-state/session-id.js — Sections B/C FAIL because siblings do not
#     resolve (env-cleared cases return NULL instead of the sibling's id).
# Every FAIL below must be attributable to a missing implementation, never to a
# harness bug. B2 (no siblings -> null), B6/C5 (own-notes Priority 1/6 wins), and
# B3/B4/C2/C3 may PASS pre-implementation; they are regression guards that must
# continue to hold once the sibling scan lands.
#
# HIGH-1 own-worktree exclusion (codex review) — the sibling scan excludes only
# path.resolve(cwd), so a CWD in a SUBDIRECTORY of a linked worktree wrongly collects
# the own worktree root as a "sibling". Fix cases:
#   - B7/C6 (PASS now, regression guards): subdir CWD, sole worktree -> own id.
#   - B8/C7 (FAIL now): subdir CWD + a second sibling -> own id; today NULL (own root
#     collected → false ambiguity).
#
# L3 gap (what this L2 test does NOT catch):
# - Cross-session parallelism: the sibling scan is verified structurally against
#   fixture worktrees, not against two concurrently live Claude Code sessions
#   executing in parallel.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    AGENTS_DIR_NODE="$AGENTS_DIR"
fi

RESOLVE_WSID_NODE="$AGENTS_DIR_NODE/hooks/lib/resolve-workflow-session-id.js"
SESSION_ID_NODE="$AGENTS_DIR_NODE/hooks/lib/workflow-state/session-id.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# ===========================================================================
# Shared git-worktree fixture builder for Sections B and C.
# Builds a main repo + N linked worktrees, each with a WORKTREE_NOTES.md
# carrying "Session-ID: <id>". Prints the MAIN repo path.
# build_fixture <sid1> [<sid2>]
# ===========================================================================
# core.hooksPath is set globally to the agents hooks dir; every fixture repo would
# otherwise inherit the agents pre-commit hook and its worktree guard would block
# `git commit` / `git worktree add`. Disable hooks per-invocation with
# `-c core.hooksPath=` so the fixture builds deterministically (see feature-1316).
GIT_NOHOOK=(git -c core.hooksPath=)
build_fixture() {
    local main linked1 linked2 branch_suffix
    main="$(mktemp -d)"
    branch_suffix="$(basename "$main")"
    ( cd "$main" && "${GIT_NOHOOK[@]}" init -q \
        && "${GIT_NOHOOK[@]}" config user.email "test@example.com" \
        && "${GIT_NOHOOK[@]}" config user.name "Test" \
        && "${GIT_NOHOOK[@]}" commit -q --allow-empty -m init ) >/dev/null 2>&1
    if [ -n "${1:-}" ]; then
        linked1="${main}/wt1"
        ( cd "$main" && "${GIT_NOHOOK[@]}" worktree add -q "$linked1" -b "fixt-${branch_suffix}-1" ) >/dev/null 2>&1
        printf "Session-ID: %s\n" "$1" > "$linked1/WORKTREE_NOTES.md"
    fi
    if [ -n "${2:-}" ]; then
        linked2="${main}/wt2"
        ( cd "$main" && "${GIT_NOHOOK[@]}" worktree add -q "$linked2" -b "fixt-${branch_suffix}-2" ) >/dev/null 2>&1
        printf "Session-ID: %s\n" "$2" > "$linked2/WORKTREE_NOTES.md"
    fi
    printf '%s' "$main"
}

# ===========================================================================
# Section B — resolveWorkflowSessionId() sibling-worktree scan.
# Called from the MAIN worktree CWD with env cleared so only the sibling scan
# (the not-yet-implemented behavior) can resolve the id.
# ===========================================================================
echo ""
echo "=== Section B — resolveWorkflowSessionId sibling scan ==="

# call_wsid <plans_dir> <cwd> [extra env KEY=VAL ...]
# Env-cleared baseline: no CLAUDE_CODE_SESSION_ID, no CLAUDE_ENV_FILE, no CLAUDE_SESSION_ID.
call_wsid() {
    local plans="$1" cwd="$2"; shift 2
    ( cd "$cwd" && WORKFLOW_PLANS_DIR="$plans" "$@" \
        run_with_timeout 10 env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_ENV_FILE -u CLAUDE_SESSION_ID node -e "
const m = require('$RESOLVE_WSID_NODE');
const r = m.resolveWorkflowSessionId({});
process.stdout.write(r == null ? 'NULL' : r);
" 2>/dev/null )
}

# B1: one linked worktree with a Session-ID; call from main CWD, env cleared -> returns it.
b1_main="$(build_fixture "test-wsid-b1")"
b1_plans="$(mktemp -d)"
b1_out="$(call_wsid "$b1_plans" "$b1_main")"
if [ "$b1_out" = "test-wsid-b1" ]; then
    pass "B1. sibling scan resolves single Session-ID from main CWD"
else
    fail "B1. sibling scan resolves single Session-ID — want 'test-wsid-b1' got '$b1_out' (sibling scan not implemented)"
fi
rm -rf "$b1_main" "$b1_plans"

# B2: no linked worktrees, env cleared -> NULL (regression guard; may pass pre-impl).
b2_main="$(build_fixture "")"
b2_plans="$(mktemp -d)"
b2_out="$(call_wsid "$b2_plans" "$b2_main")"
if [ "$b2_out" = "NULL" ]; then
    pass "B2. no linked worktrees, env cleared -> NULL"
else
    fail "B2. no linked worktrees, env cleared -> NULL — got '$b2_out'"
fi
rm -rf "$b2_main" "$b2_plans"

# B3: CLAUDE_CODE_SESSION_ID (existence-guarded) beats a different sibling id.
# Priority 2 requires a <value>-*.md artifact in plans-dir; create one.
b3_main="$(build_fixture "test-wsid-b3-sibling")"
b3_plans="$(mktemp -d)"
: > "$b3_plans/env-sid-b3-intent.md"
b3_out="$( cd "$b3_main" && WORKFLOW_PLANS_DIR="$b3_plans" CLAUDE_CODE_SESSION_ID="env-sid-b3" \
    run_with_timeout 10 env -u CLAUDE_ENV_FILE -u CLAUDE_SESSION_ID node -e "
const m = require('$RESOLVE_WSID_NODE');
const r = m.resolveWorkflowSessionId({});
process.stdout.write(r == null ? 'NULL' : r);
" 2>/dev/null )"
if [ "$b3_out" = "env-sid-b3" ]; then
    pass "B3. CLAUDE_CODE_SESSION_ID (guarded) wins over sibling Session-ID"
else
    fail "B3. CLAUDE_CODE_SESSION_ID must win over sibling — want 'env-sid-b3' got '$b3_out'"
fi
rm -rf "$b3_main" "$b3_plans"

# B4: two linked worktrees with DIFFERENT ids, env cleared -> NULL (ambiguity fail-safe).
b4_main="$(build_fixture "test-wsid-b4-a" "test-wsid-b4-b")"
b4_plans="$(mktemp -d)"
b4_out="$(call_wsid "$b4_plans" "$b4_main")"
if [ "$b4_out" = "NULL" ]; then
    pass "B4. two distinct sibling Session-IDs -> NULL (ambiguity fail-safe)"
else
    fail "B4. two distinct sibling Session-IDs must be NULL — got '$b4_out' (fail-safe not implemented)"
fi
rm -rf "$b4_main" "$b4_plans"

# B5: two linked worktrees with the SAME id, env cleared -> returns it.
b5_main="$(build_fixture "test-wsid-b5" "test-wsid-b5")"
b5_plans="$(mktemp -d)"
b5_out="$(call_wsid "$b5_plans" "$b5_main")"
if [ "$b5_out" = "test-wsid-b5" ]; then
    pass "B5. two identical sibling Session-IDs -> returns it"
else
    fail "B5. two identical sibling Session-IDs must resolve — want 'test-wsid-b5' got '$b5_out'"
fi
rm -rf "$b5_main" "$b5_plans"

# B6: CWD = the linked worktree itself (own WORKTREE_NOTES.md) + a SECOND sibling
# with a DIFFERENT id -> Priority 1 returns the CWD's own id; the sibling scan
# must not turn this ambiguous. Regression guard — may PASS pre-implementation
# (Priority 1 already exists); post-fix it proves the scan does not preempt P1.
b6_main="$(build_fixture "test-wsid-b6-own" "test-wsid-b6-other")"
b6_plans="$(mktemp -d)"
b6_out="$(call_wsid "$b6_plans" "$b6_main/wt1")"
if [ "$b6_out" = "test-wsid-b6-own" ]; then
    pass "B6. CWD in linked worktree -> own Session-ID wins despite conflicting sibling"
else
    fail "B6. own WORKTREE_NOTES.md (Priority 1) must win — want 'test-wsid-b6-own' got '$b6_out' (sibling scan preempted P1)"
fi
rm -rf "$b6_main" "$b6_plans"

# B7: CWD = a SUBDIRECTORY inside the ONLY linked worktree, env cleared, no other
# sibling -> own Session-ID. Regression guard (currently passes by accident: the
# own worktree root is collected as the sole "sibling"). Post-fix it proves the
# own-worktree identification still returns own's id when own is the only entry.
b7_main="$(build_fixture "test-wsid-b7-own")"
b7_plans="$(mktemp -d)"
mkdir -p "$b7_main/wt1/sub/dir"
b7_out="$(call_wsid "$b7_plans" "$b7_main/wt1/sub/dir")"
if [ "$b7_out" = "test-wsid-b7-own" ]; then
    pass "B7. CWD in linked-worktree subdir, sole worktree -> own Session-ID"
else
    fail "B7. CWD in linked-worktree subdir must resolve own id — want 'test-wsid-b7-own' got '$b7_out'"
fi
rm -rf "$b7_main" "$b7_plans"

# B8: CWD = a SUBDIRECTORY inside linked worktree A (own id 'sid-own-b8'), PLUS a
# second linked worktree B ('sid-other-b8'). The scan must identify A as "own"
# (its root contains CWD), return own's id first, and exclude own from the sibling
# set — so B is the only true sibling and A's id wins. HIGH-1 bug: the scan excludes
# only path.resolve(cwd), so A's root is wrongly collected as a sibling alongside B
# → two distinct ids → NULL (false ambiguity).
b8_main="$(build_fixture "sid-own-b8" "sid-other-b8")"
b8_plans="$(mktemp -d)"
mkdir -p "$b8_main/wt1/sub/dir"
b8_out="$(call_wsid "$b8_plans" "$b8_main/wt1/sub/dir")"
if [ "$b8_out" = "sid-own-b8" ]; then
    pass "B8. CWD in linked-worktree subdir + other sibling -> own Session-ID (not ambiguous)"
else
    fail "B8. own worktree must be excluded from sibling set — want 'sid-own-b8' got '$b8_out' (HIGH-1: own root wrongly collected as sibling → false ambiguity)"
fi
rm -rf "$b8_main" "$b8_plans"

# ===========================================================================
# Section C — resolveSessionId() (workflow-state/session-id.js) symmetric scan.
# Priority 7 (JSONL mtime scan) is neutralized: point CLAUDE_TRANSCRIPT_BASE_DIR
# and CLAUDE_PROJECT_DIR at empty fixture dirs so it cannot accidentally resolve.
# ===========================================================================
echo ""
echo "=== Section C — resolveSessionId sibling scan ==="

# call_sid <cwd> <transcript_base> [extra env KEY=VAL ...]
# ctx = {} (no sessionIdFromInput). Env cleared for CC session vars.
call_sid() {
    local cwd="$1" tbase="$2"; shift 2
    ( cd "$cwd" && CLAUDE_TRANSCRIPT_BASE_DIR="$tbase" CLAUDE_PROJECT_DIR="$cwd" "$@" \
        run_with_timeout 10 env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_ENV_FILE -u CLAUDE_SESSION_ID node -e "
const m = require('$SESSION_ID_NODE');
const r = m.resolveSessionId({});
process.stdout.write(r == null ? 'NULL' : r);
" 2>/dev/null )
}

# C1: sibling scan resolves from main CWD when ctx empty and env cleared.
c1_main="$(build_fixture "test-sid-c1")"
c1_tbase="$(mktemp -d)"
c1_out="$(call_sid "$c1_main" "$c1_tbase")"
if [ "$c1_out" = "test-sid-c1" ]; then
    pass "C1. sibling scan resolves session id from main CWD"
else
    fail "C1. sibling scan resolves session id — want 'test-sid-c1' got '$c1_out' (sibling scan not implemented)"
fi
rm -rf "$c1_main" "$c1_tbase"

# C2: CLAUDE_CODE_SESSION_ID set -> wins over sibling notes.
c2_main="$(build_fixture "test-sid-c2-sibling")"
c2_tbase="$(mktemp -d)"
c2_out="$( cd "$c2_main" && CLAUDE_TRANSCRIPT_BASE_DIR="$c2_tbase" CLAUDE_PROJECT_DIR="$c2_main" CLAUDE_CODE_SESSION_ID="env-sid-c2" \
    run_with_timeout 10 env -u CLAUDE_ENV_FILE -u CLAUDE_SESSION_ID node -e "
const m = require('$SESSION_ID_NODE');
const r = m.resolveSessionId({});
process.stdout.write(r == null ? 'NULL' : r);
" 2>/dev/null )"
if [ "$c2_out" = "env-sid-c2" ]; then
    pass "C2. CLAUDE_CODE_SESSION_ID wins over sibling notes"
else
    fail "C2. CLAUDE_CODE_SESSION_ID must win over sibling — want 'env-sid-c2' got '$c2_out'"
fi
rm -rf "$c2_main" "$c2_tbase"

# C3: two conflicting siblings, env cleared, Priority 7 neutralized -> NULL.
c3_main="$(build_fixture "test-sid-c3-a" "test-sid-c3-b")"
c3_tbase="$(mktemp -d)"
c3_out="$(call_sid "$c3_main" "$c3_tbase")"
if [ "$c3_out" = "NULL" ]; then
    pass "C3. two conflicting siblings -> NULL (no fall-through to Priority 7)"
else
    fail "C3. two conflicting siblings must be NULL — got '$c3_out' (ambiguity fail-safe not implemented)"
fi
rm -rf "$c3_main" "$c3_tbase"

# C4: two siblings with IDENTICAL ids, env cleared -> returns it (CPR-5 counterpart of B5).
c4_main="$(build_fixture "test-sid-c4" "test-sid-c4")"
c4_tbase="$(mktemp -d)"
c4_out="$(call_sid "$c4_main" "$c4_tbase")"
if [ "$c4_out" = "test-sid-c4" ]; then
    pass "C4. two identical sibling Session-IDs -> returns it"
else
    fail "C4. two identical sibling Session-IDs must resolve — want 'test-sid-c4' got '$c4_out' (sibling scan not implemented)"
fi
rm -rf "$c4_main" "$c4_tbase"

# C5: CWD = the linked worktree itself + conflicting second sibling -> own id via
# Priority 6 (WORKTREE_NOTES.md in CWD). CPR-5 counterpart of B6. Regression guard —
# may PASS pre-implementation (Priority 6 already exists); post-fix it proves the
# sibling scan does not preempt the CWD notes read or turn it ambiguous.
c5_main="$(build_fixture "test-sid-c5-own" "test-sid-c5-other")"
c5_tbase="$(mktemp -d)"
c5_out="$(call_sid "$c5_main/wt1" "$c5_tbase")"
if [ "$c5_out" = "test-sid-c5-own" ]; then
    pass "C5. CWD in linked worktree -> own Session-ID wins despite conflicting sibling"
else
    fail "C5. own WORKTREE_NOTES.md (Priority 6) must win — want 'test-sid-c5-own' got '$c5_out' (sibling scan preempted P6)"
fi
rm -rf "$c5_main" "$c5_tbase"

# C6: CPR-5 counterpart of B7 for resolveSessionId(). CWD = a subdirectory inside
# the ONLY linked worktree, env cleared, Priority 7 neutralized, no other sibling
# -> own Session-ID. Regression guard (currently passes by accident).
c6_main="$(build_fixture "test-sid-c6-own")"
c6_tbase="$(mktemp -d)"
mkdir -p "$c6_main/wt1/sub/dir"
c6_out="$(call_sid "$c6_main/wt1/sub/dir" "$c6_tbase")"
if [ "$c6_out" = "test-sid-c6-own" ]; then
    pass "C6. CWD in linked-worktree subdir, sole worktree -> own Session-ID"
else
    fail "C6. CWD in linked-worktree subdir must resolve own id — want 'test-sid-c6-own' got '$c6_out'"
fi
rm -rf "$c6_main" "$c6_tbase"

# C7: CPR-5 counterpart of B8. CWD = a subdirectory inside linked worktree A
# ('sid-own-c7'), PLUS a second linked worktree B ('sid-other-c7'). Expect own id.
# HIGH-1 bug: own root wrongly collected as sibling → false ambiguity → NULL.
c7_main="$(build_fixture "sid-own-c7" "sid-other-c7")"
c7_tbase="$(mktemp -d)"
mkdir -p "$c7_main/wt1/sub/dir"
c7_out="$(call_sid "$c7_main/wt1/sub/dir" "$c7_tbase")"
if [ "$c7_out" = "sid-own-c7" ]; then
    pass "C7. CWD in linked-worktree subdir + other sibling -> own Session-ID (not ambiguous)"
else
    fail "C7. own worktree must be excluded from sibling set — want 'sid-own-c7' got '$c7_out' (HIGH-1: own root wrongly collected as sibling → false ambiguity)"
fi
rm -rf "$c7_main" "$c7_tbase"

# ===========================================================================
# Results
# ===========================================================================
echo ""
TOTAL=$((PASS + FAIL))
echo "Results: $PASS passed, $FAIL failed ($TOTAL total)"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
