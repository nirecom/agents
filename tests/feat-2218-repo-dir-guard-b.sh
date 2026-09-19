#!/usr/bin/env bash
# tests/feat-2218-repo-dir-guard-b.sh
# Tests: bin/workflow/lib/next-step/repo-dir-guard.js, bin/workflow/lib/next-step/verdict.js, bin/workflow/next-step
# Tags: next-step, repo-dir, fail-fast, session-close, worktree-identity, regression-2316, scope:issue-specific, pwsh-not-required, TL1, dup-group-keep:size-hard-limit

# R7b — worktree-end→session-close boundary (#2316). Isolated from the main
# feat-2218 file because the append would have exceeded the HARD line limit.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'wf2218b'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"

TARGET="bin/workflow/lib/next-step/repo-dir-guard.js"

PRELUDE="
const guard = require('$AGENTS_DIR_NODE/$TARGET');
function verdictOf(v) { return (v && typeof v === 'object') ? (v.verdict || v.result || JSON.stringify(v)) : String(v); }
function outcome(fn) {
  try { const r = fn(); if (r && r.ok === false) return 'fail-fast'; return 'continue'; }
  catch (e) { return 'fail-fast'; }
}
"

require_module() {
    if [ -f "$AGENTS_DIR/$1" ]; then return 0; fi
    fail "MODULE NOT FOUND: $1 — expected per issue #2218 Step 9, not yet implemented (write_code has not run)"
    return 1
}

init_repo() {
    git init -q "$1" 2>/dev/null
    git -C "$1" config core.hooksPath /dev/null
    git -C "$1" config user.email 't@example.com'
    git -C "$1" config user.name 'fixture'
    git -C "$1" config commit.gpgsign false
    printf 'seed\n' > "$1/f.txt"
    git -C "$1" add -A
    GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' \
        git -C "$1" commit -q -m init
}

# R4b — #2316 delete-path fail-open. Distinct from R4: here the recorded cwd is a
# linked worktree that has been PHYSICALLY DELETED, so git cannot speak for it
# (INDETERMINATE) but the cause is a legitimate worktree-end, not a broken-git
# bypass. The Step-5 boundary opens INDETERMINATE only for this "recorded path
# absent" case — symmetric with UNKNOWN — while R4 (recorded path present) stays
# fail-fast. Self-call (override=false) fails OPEN with reason repo-context-worktree-deleted;
# a cross-session override (override=true) fails FAST (#2319 — symmetric with SIBLING),
# reason indeterminate.
run_R4b() {
    require_module "$TARGET" || return 0
    local tmp main wt out
    tmp="$(make_tmp)"
    main="$tmp/main"; wt="$tmp/wt"
    init_repo "$main"
    git -C "$main" worktree add -q -b feature/del "$wt" 2>/dev/null
    if [ ! -d "$wt" ]; then
        rm -rf "$tmp" 2>/dev/null || true
        fail "R4b: fixture setup failed — could not create a linked worktree"
        return 0
    fi
    # #2316: the recorded worktree is gone from disk (a completed /worktree-end).
    rm -rf "$wt" 2>/dev/null || true
    out=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PROJECT_DIR \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 60 node -e "
$PRELUDE
const { writeState, createInitialState } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const problems = [];
const main = '$(node_path "$main")';
const wt = '$(node_path "$wt")';
const v = verdictOf(guard.compareRepoIdentity(wt, main));
if (v !== 'indeterminate') problems.push('verdict:' + v);
writeState('sid-r4b', createInitialState('sid-r4b', { cwd: wt }));
// self-call: a deleted recorded worktree fails OPEN (#2316).
const rSelf = guard.assertRepoDirMatchesSession('sid-r4b', main, { isExplicitSessionOverride: false });
if (!rSelf || typeof rSelf !== 'object') problems.push('self:no-object');
else {
  if (!('ok' in rSelf) || !('verdict' in rSelf)) problems.push('self:shape:' + JSON.stringify(rSelf));
  if (rSelf.ok !== true) problems.push('self:not-fail-open:' + JSON.stringify(rSelf));
  else if (rSelf.reason !== 'repo-context-worktree-deleted') problems.push('self:reason:' + String(rSelf.reason));
}
// cross-session override: the deleted-path pass is NOT granted — fails FAST (#2319).
const rCross = guard.assertRepoDirMatchesSession('sid-r4b', main, { isExplicitSessionOverride: true });
if (!rCross || typeof rCross !== 'object') problems.push('cross:no-object');
else {
  if (!('ok' in rCross) || !('verdict' in rCross)) problems.push('cross:shape:' + JSON.stringify(rCross));
  if (rCross.ok !== false) problems.push('cross:not-fail-fast:' + JSON.stringify(rCross));
  else if (rCross.reason !== 'indeterminate') problems.push('cross:reason:' + String(rCross.reason));
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    # The fail-open path writes a stderr diagnostic ahead of stdout (2>&1 merges);
    # match the trailing marker, not exact equality (as R3 does).
    case "$out" in
        *BAD:*|"") fail "R4b: expected 'OK', got '${out:-<err>}'" ;;
        *OK) pass "R4b: a deleted recorded worktree (INDETERMINATE) fails OPEN for a self-call (reason repo-context-worktree-deleted) but fails FAST for a cross-session override (#2319)" ;;
        *) fail "R4b: expected 'OK', got '${out:-<err>}'" ;;
    esac
}

# R4c — CPR-ORTH boundary: the delete-path fail-open must NOT leak to DIFFERENT.
# Two unrelated real repos (recorded cwd present, git identity provably distinct)
# stay fail-fast, both call shapes. Guards against a Step-5 over-broadening that
# would fail-open on a genuine cross-repo mismatch.
run_R4c() {
    require_module "$TARGET" || return 0
    local tmp a b out
    tmp="$(make_tmp)"
    a="$tmp/repo-a"; b="$tmp/repo-b"
    init_repo "$a"
    init_repo "$b"
    out=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PROJECT_DIR \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 60 node -e "
$PRELUDE
const { writeState, createInitialState } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const problems = [];
const a = '$(node_path "$a")';
const b = '$(node_path "$b")';
const v = verdictOf(guard.compareRepoIdentity(a, b));
if (v !== 'different-repo') problems.push('verdict:' + v);
writeState('sid-r4c', createInitialState('sid-r4c', { cwd: a }));
for (const override of [false, true]) {
  const o = outcome(() => guard.assertRepoDirMatchesSession('sid-r4c', b, { isExplicitSessionOverride: override }));
  if (o !== 'fail-fast') problems.push('override=' + override + ':' + o);
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "R4c: DIFFERENT (present recorded cwd, distinct repo) stays fail-fast — the delete-path fail-open does not leak"
    else
        fail "R4c: expected 'OK', got '${out:-<err>}'"
    fi
}

# R7-cli — #2316 primary regression, end to end. The user-visible path: a session
# recorded its linked worktree, /worktree-end removed it, then next-step runs from
# the MAIN checkout. verdict.js evaluates the repo-dir guard BEFORE step selection,
# so pre-fix it aborts with repo-dir-mismatch; post-fix the deleted-path fail-open
# lets next-step route PAST the repo-dir-mismatch abort to a legitimate next workflow
# action (ACTION=invoke). This is a SELF-call (override=false), so #2319 preserves it.
# The point proven is "the #2316 guard does not abort," not the specific destination.
run_R7_cli() {
    require_module "$TARGET" || return 0
    local tmp main wt sid out rc r7
    tmp="$(make_tmp)"
    main="$tmp/main"; wt="$tmp/wt"
    init_repo "$main"
    git -C "$main" worktree add -q -b feature/del2 "$wt" 2>/dev/null
    if [ ! -d "$wt" ]; then
        rm -rf "$tmp" 2>/dev/null || true
        fail "R7-cli: fixture setup failed — could not create a linked worktree"
        return 0
    fi
    sid="del-sid-r7"
    env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const { writeState, createInitialState, markStep } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const st = createInitialState('$sid', { cwd: '$(node_path "$wt")' });
st.closes_issues = [2218];
writeState('$sid', st);
markStep('$sid', 'workflow_init', 'complete');
" >/dev/null 2>&1
    # /worktree-end has removed the linked worktree from disk.
    rm -rf "$wt" 2>/dev/null || true
    out=$(env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="$sid" \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        CLAUDE_PROJECT_DIR="$main" HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 60 node "$AGENTS_DIR/bin/workflow/next-step" 2>&1)
    # Capture the CLI exit code before any other command can clobber $?.
    rc=$?
    rm -rf "$tmp" 2>/dev/null || true
    # Post-fix contract, asserted in full so "green" means the deleted-path
    # fail-open actually ROUTED — not merely that the abort text is absent:
    #  (a) exit 0 (next-step's always-0 next-step-mode contract holds through it),
    #  (b) no repo-dir-mismatch and no ACTION=abort (the #2316 regression itself),
    #  (c) ACTION=invoke present — a legitimate next workflow action past the
    #      repo-dir-mismatch abort, which a bare "not abort" check cannot separate
    #      from blocked/paused.
    r7=""
    [ "$rc" -eq 0 ] || r7="$r7 nonzero-exit:$rc"
    case "$out" in *repo-dir-mismatch*) r7="$r7 repo-dir-mismatch-abort" ;; esac
    case "$out" in *ACTION=abort*) r7="$r7 action-abort" ;; esac
    [ -n "$out" ] || r7="$r7 no-output"
    case "$out" in *ACTION=invoke*) : ;; *) r7="$r7 no-invoke-action" ;; esac
    if [ -z "$r7" ]; then
        pass "R7-cli: a deleted recorded worktree exits 0 and routes PAST the repo-dir-mismatch abort to ACTION=invoke — a legitimate next workflow action"
    else
        fail "R7-cli:$r7 — got (rc=$rc): ${out:-<empty>}"
    fi
}

# R7b-cli — #2316 worktree-end→SESSION-CLOSE boundary, end to end. R7-cli proves the
# guard is STEP-AGNOSTIC at the EARLIEST step (only workflow_init complete → some
# invoke); R7b proves the SAME guard-pass at the boundary #2316 names — cleanup done,
# worktree deleted, next action is session-close. Steps workflow_init..cleanup are
# marked complete, leaving pre_final_report_gate (step 15, session-close) first
# non-complete; the assertion binds to REASON='pre_final_report_gate'.
# Robustness: next-step read mode picks the first non-complete step by STATUS and does
# NOT re-run write-time evidence/CONFIRM gates (only --advance does), so markStep is
# sufficient. outline/detail are approval-gated on WRITE (sanctioned token); cleanup is
# NOT gated, so a plain markStep completes it.
run_R7b_cli() {
    require_module "$TARGET" || return 0
    local tmp main wt sid out rc r7b
    tmp="$(make_tmp)"
    main="$tmp/main"; wt="$tmp/wt"
    init_repo "$main"
    git -C "$main" worktree add -q -b feature/del3 "$wt" 2>/dev/null
    if [ ! -d "$wt" ]; then
        rm -rf "$tmp" 2>/dev/null || true
        fail "R7b-cli: fixture setup failed — could not create a linked worktree"
        return 0
    fi
    sid="del-sid-r7b"
    env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const { writeState, createInitialState, markStep } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const st = createInitialState('$sid', { cwd: '$(node_path "$wt")' });
st.closes_issues = [2218];
writeState('$sid', st);
// Mark steps 1..14 (workflow_init through cleanup) complete, leaving
// pre_final_report_gate (step 15, session-close) as the first non-complete step.
// outline/detail are approval-gated on write, so they carry a sanctioned token;
// cleanup is NOT gated, so a plain markStep completes it.
const steps = ['workflow_init','clarify_intent','research','outline','detail','branching_complete','write_tests','review_tests','write_code','run_tests','review_security','docs','user_verification','cleanup'];
const gated = new Set(['outline','detail']);
for (const s of steps) { markStep('$sid', s, 'complete', {}, gated.has(s) ? { sanctioned: 'reset-sentinel' } : {}); }
" >/dev/null 2>&1
    # /worktree-end has removed the linked worktree from disk.
    rm -rf "$wt" 2>/dev/null || true
    out=$(env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="$sid" \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        CLAUDE_PROJECT_DIR="$main" HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 60 node "$AGENTS_DIR/bin/workflow/next-step" 2>&1)
    # Capture the CLI exit code before any other command can clobber $?.
    rc=$?
    rm -rf "$tmp" 2>/dev/null || true
    # Post-fix contract at the worktree-end→session-close boundary:
    #  (a) exit 0, (b) no repo-dir-mismatch and no ACTION=abort (the #2316 regression),
    #  (c) non-empty output, (d) ACTION=invoke bound to the session-close step via
    #  REASON='pre_final_report_gate' (verdict.js emits REASON=<currentStep>). A generic
    #  invoke is NOT enough — a misroute to any other step carries a different REASON.
    r7b=""
    [ "$rc" -eq 0 ] || r7b="$r7b nonzero-exit:$rc"
    case "$out" in *repo-dir-mismatch*) r7b="$r7b repo-dir-mismatch-abort" ;; esac
    case "$out" in *ACTION=abort*) r7b="$r7b action-abort" ;; esac
    [ -n "$out" ] || r7b="$r7b no-output"
    case "$out" in *ACTION=invoke*) : ;; *) r7b="$r7b no-invoke-action" ;; esac
    case "$out" in *"REASON='pre_final_report_gate'"*) : ;; *) r7b="$r7b not-session-close-routing" ;; esac
    if [ -z "$r7b" ]; then
        pass "R7b-cli: faithful #2316 worktree-end→session-close boundary — deleted recorded worktree, cleanup done (steps workflow_init..cleanup complete), routes PAST the repo-dir-mismatch abort to ACTION=invoke REASON='pre_final_report_gate' (the session-close step)"
    else
        fail "R7b-cli:$r7b — got (rc=$rc): ${out:-<empty>}"
    fi
}

run_R4b
run_R4c
run_R7_cli
run_R7b_cli

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
