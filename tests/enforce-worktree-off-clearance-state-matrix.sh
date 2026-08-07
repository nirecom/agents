#!/usr/bin/env bash
# tests/enforce-worktree-off-clearance-state-matrix.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/handle-bash-write.js, hooks/enforce-worktree/handle-edit-write.js, hooks/enforce-worktree/bash-write-scope.js, hooks/lib/write-tools.js
# Tags: enforce-worktree, off-clearance, workflow-state-dir, clearance-validation, tool-parity, runinterminal, runcommands, notebookedit, editfiles, pretooluse, enforce-worktree-off, protected-branch, main-worktree, security, scope:issue-specific, pwsh-not-required, TL2, hook-registration
#
# LAYER NOTE: the reviewer filed this gap as "TL3". Per rules/test.md the TL3
# prefix is reserved for real-environment seams gated on RUN_TL3 (a live
# `claude -p`); this file drives the hook as a real PreToolUse SUBPROCESS with
# piped stdin — the same substrate as its two style references
# (tests/fix-1709-workflow-dir-write-allow.sh, tests/fix-1780-round4-write-tool-parity.sh),
# both tagged TL2. It is therefore filed as TL2 and named without the TL3
# prefix, so `ls tests/TL3-*` keeps meaning "gated, expensive, real host".
#
# TL3 gap (what this test does NOT catch):
# - Claude Code actually dispatching PreToolUse for these 8 tool names inside a
#   live session, and the OFF-clearance pipeline's real read/write of
#   <workflowDir>/<sid>.off-clearance flowing through the registered hook.
#   Registration itself is asserted statically in
#   tests/fix-1780-round4-write-tool-parity.sh section R.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
#
# ---------------------------------------------------------------------------
# WHAT THIS FILE DEFENDS
#
# #1709: enforce-worktree.js is a worktree-LOCATION guard, but the OFF-clearance
# pipeline lives in the workflow STATE dir (<CLAUDE_WORKFLOW_DIR>, canonically
# $HOME/.claude/projects/workflow) — outside any repo, and it must stay reachable
# from wherever the session happens to be standing, including the MAIN checkout
# and a PROTECTED branch. If the guard blocks the pipeline's own reads or its
# bookkeeping writes, clearance validation cannot run at all and the OFF path
# fails shut in a way no unit test of the helper functions can see.
#
# Existing coverage and why it is not enough:
#   - fix-1709-workflow-dir-write-allow.sh  : Bash ONLY, non-git CWD ONLY,
#     ENFORCE_WORKTREE=on ONLY, WRITES only. It never reads, never stands in a
#     repo, and never exercises runInTerminal/runCommands.
#   - fix-1780-round4-write-tool-parity.sh  : all 8 tool names, but only
#     in-REPO targets and only ENFORCE_WORKTREE=on. Nothing about the workflow
#     state dir and nothing about the off switch.
# This file is the cross-product of the two axes neither covers:
#   {read, state-write, marker-write} x {main, linked-feature, protected}
#   x {Bash, runInTerminal, runCommands} x {ENFORCE_WORKTREE on, off}
# plus the edit-write class writing into the state dir (CPR-ORTH: the clearance
# staging path must behave the same for every write-capable tool class).
#
# ASSERTION CONTRACT (strict, inherited from fix-1709): enforce-worktree.js
# always exits 0 and prints either `{}` (allow) or a `"decision":"block"` object.
# A crash, a timeout, or empty output is its OWN verdict token — never folded
# into "allow" — so a hook that dies scores as a failure, not a false green.
#
# HERMETICITY (rules/test/fixture-isolation.md): throwaway git repos under a
# temp dir with core.hooksPath disabled, a throwaway session id, and
# CLAUDE_WORKFLOW_DIR / WORKFLOW_PLANS_DIR BOTH pinned (dual-pin) at DISTINCT
# temp dirs — distinct so that an allow for the state dir cannot be scored by
# the plans-dir fast-path instead. CLAUDE_SESSION_ID / CLAUDE_CODE_SESSION_ID /
# SCRATCHPAD / DEFAULT_BRANCHES are unset per invocation so no inherited session
# marker, scratchpad allow, or branch override can decide an assertion.
# ---------------------------------------------------------------------------

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
GUARD="$_AGENTS_DIR_NODE/hooks/enforce-worktree.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
SID="wtclearsid"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"; else fail "$name - want=$want got=$got"; fi
}

if [ ! -f "$AGENTS_DIR/hooks/enforce-worktree.js" ]; then
    fail "H0 hooks/enforce-worktree.js missing - every case below is vacuous"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi
pass "H0 enforce-worktree.js present"

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t 'wtclear')
cleanup() { chmod -R u+w "$TMP" 2>/dev/null; rm -r -f "$TMP" 2>/dev/null; return 0; }
trap cleanup EXIT

# Workflow STATE dir (the off-clearance token / marker home) and a SEPARATE
# plans dir, both outside any git repo.
WFDIR="$TMP/state/workflow"; mkdir -p "$WFDIR"
PLANS="$TMP/plans";          mkdir -p "$PLANS"
WF_N=$(node_path "$WFDIR"); PLANS_N=$(node_path "$PLANS")
# A pre-existing clearance token, so the READ cases read something real.
echo '{"token":"x"}' > "$WFDIR/$SID.off-clearance"

# ── git fixtures: main checkout, linked worktree on a feature branch, linked
# worktree on a PROTECTED branch name ───────────────────────────────────────
MAIN="$TMP/repo"; mkdir -p "$MAIN"
git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.email "test@example.com"
git -C "$MAIN" config user.name "Test"
git -C "$MAIN" config core.hooksPath /dev/null
echo init > "$MAIN/README.md"
git -C "$MAIN" add README.md
git -C "$MAIN" commit -q -m initial
WT="$TMP/repo-wt"
git -C "$MAIN" worktree add -q -b feature/off-clearance "$WT" 2>/dev/null
WTP="$TMP/repo-wt-protected"
git -C "$MAIN" worktree add -q -b master "$WTP" 2>/dev/null

if { [ ! -d "$WT/.git" ] && [ ! -f "$WT/.git" ]; } || { [ ! -d "$WTP/.git" ] && [ ! -f "$WTP/.git" ]; }; then
    fail "H1 worktree fixtures not created - the linked/protected halves would be vacuous"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi
pass "H1 main checkout + linked feature worktree + protected-branch worktree fixtures created"

# ── payload builder ─────────────────────────────────────────────────────────
DRV="$TMP/mk-input.js"
cat > "$DRV" <<'DRV_EOF'
"use strict";
const [, , tool, target, cwd, shape, sid] = process.argv;
const EDIT_WRITE = ["Edit", "Write", "MultiEdit", "editFiles", "NotebookEdit"];
let ti;
if (EDIT_WRITE.indexOf(tool) !== -1) {
  const key = tool === "NotebookEdit" ? "notebook_path" : "file_path";
  ti = shape === "batch" ? { edits: [{ [key]: target }] } : { [key]: target };
} else {
  // Command class. runCommands carries an ARRAY; the payload under test is
  // placed at index 2 so a joined-text-only reader cannot pass by accident.
  // The two leading decoys must be READ-ONLY commands: enforce-worktree.js
  // classifies the JOINED text, so a decoy that is itself a write (e.g. the
  // `npm test` used by tests/fix-1780-round4-write-tool-parity.sh, which
  // detectWritePredicate reports as isPkgMgrWriteIR) would make even a pure-read
  // payload arrive as a write and score the READ cases for the wrong reason.
  ti = tool === "runCommands"
    ? { commands: ["git status", "git log --oneline -1", target], cwd }
    : { command: target, cwd };
}
process.stdout.write(JSON.stringify({ session_id: sid, tool_name: tool, cwd, tool_input: ti }));
DRV_EOF

# run_guard <tool> <payload> <run-dir> <shape> <enforce-mode>
#   -> block | allow | crash:<rc> | timeout | empty | unrecognized
run_guard() {
    local tool="$1" target="$2" dir="$3" shape="$4" mode="$5" payload out rc
    payload=$("$RWT" 10 node "$DRV" "$tool" "$target" "$(node_path "$dir")" "$shape" "$SID" 2>/dev/null)
    out=$(cd "$dir" && printf '%s' "$payload" | \
        env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u SCRATCHPAD -u DEFAULT_BRANCHES \
        ENFORCE_WORKTREE="$mode" CLAUDE_WORKFLOW_DIR="$WF_N" WORKFLOW_PLANS_DIR="$PLANS_N" \
        AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        "$RWT" 25 node "$GUARD" 2>/dev/null)
    rc=$?
    case "$rc" in
        124) printf 'timeout'; return ;;
        0)   ;;
        *)   printf 'crash:%s' "$rc"; return ;;
    esac
    out=$(printf '%s' "$out" | tr -d '\r\n')
    [ -z "$out" ] && { printf 'empty'; return; }
    case "$out" in
        *'"decision":"block"'*) printf 'block' ;;
        '{}')                   printf 'allow' ;;
        *)                      printf 'unrecognized' ;;
    esac
}

COMMAND_TOOLS="Bash runInTerminal runCommands"
EDIT_WRITE_TOOLS="Edit Write MultiEdit editFiles NotebookEdit"
# scenario triples: <label>|<dir>
SCENARIOS="main|$MAIN linked|$WT protected|$WTP"

# ===========================================================================
# Section R - READS of the workflow STATE dir must be ALLOWED from EVERYWHERE.
#
# This is the #1709 regression shape. OFF-clearance validation reads
# <workflowDir>/<sid>.off-clearance; the read happens wherever the session is
# standing, which very often IS the main checkout (that is the whole reason a
# WORKFLOW_OFF is being requested). A guard that blocks it does not degrade the
# clearance check - it removes it.
#
# Both a bare read and a SEQUENCED read (`test -f ... && cat ...`, the shape the
# validation actually uses) are covered: sequencing is what routes a command past
# the fast-path allows in the write branch, so a future change that starts
# treating a sequenced command as a write would break clearance validation here
# first.
# ===========================================================================
for sc in $SCENARIOS; do
    lbl="${sc%%|*}"; dir="${sc#*|}"
    for t in $COMMAND_TOOLS; do
        got=$(run_guard "$t" "cat $WF_N/$SID.off-clearance" "$dir" single on)
        assert_eq "R1 [$lbl/$t] bare read of the clearance token is allowed (ENFORCE_WORKTREE=on)" "allow" "$got"
    done
    got=$(run_guard Bash "test -f $WF_N/$SID.off-clearance && cat $WF_N/$SID.off-clearance" "$dir" single on)
    assert_eq "R2 [$lbl/Bash] SEQUENCED read of the clearance token is allowed (ENFORCE_WORKTREE=on)" "allow" "$got"
done

# ===========================================================================
# Section W - the pipeline's own BOOKKEEPING WRITES into the workflow state dir
# must be allowed from every location, for every command-class tool.
#
# fix-1709-workflow-dir-write-allow.sh pins this for Bash from a NON-GIT cwd
# only. Standing inside a repo takes a different route through
# handle-bash-write.js (repoRoot is non-null, so the non-git fail-closed branch
# is never reached), and runInTerminal/runCommands were not covered at all -
# runCommands in particular carries its command in an ARRAY, the exact shape
# that used to read as "" and be waved through / mis-handled (#1780 round-4 H-2).
# ===========================================================================
for sc in $SCENARIOS; do
    lbl="${sc%%|*}"; dir="${sc#*|}"
    for t in $COMMAND_TOOLS; do
        got=$(run_guard "$t" "mkdir -p $WF_N && echo x > $WF_N/$SID.json" "$dir" single on)
        assert_eq "W1 [$lbl/$t] sequenced state-dir bookkeeping write is allowed" "allow" "$got"
    done
done

# W2 control (non-vacuity): the same sequenced shape, but with ONE target moved
# out of the state dir and into the repo, must still block. Without this, a hook
# that allowed every sequenced write would pass all of section W.
#
# The target has to be IN-REPO, not merely a sibling directory of the state dir:
# an out-of-session-scope sibling is legitimately allowed for Bash by the
# universal target-aware rule (#1045, hooks/enforce-worktree/universal-target-allow.js),
# which by its own contract applies to `Bash` only — so a sibling-dir control
# would assert the #1045 rule's tool coverage rather than state-dir containment.
for t in $COMMAND_TOOLS; do
    got=$(run_guard "$t" "mkdir -p $WF_N && echo x > $(node_path "$MAIN")/leak.json" "$MAIN" single on)
    assert_eq "W2 [main/$t] control: sequenced write mixing the state dir with an IN-REPO target blocks" "block" "$got"
done

# ===========================================================================
# Section K - protected clearance-MARKER basenames (.workflow-off etc.) inside
# the state dir. The assertion is PARITY across the command class first: a
# marker forge that one tool name blocks and its sibling allows is a bypass, not
# a partial guard (CPR-ORTH).
#
# Behaviour lock on the absolute verdicts, per the module header of
# hooks/block-clearance-token-write.js: enforce-worktree.js is a LOCATION guard,
# so its marker gate blocks from the main checkout and from a protected branch
# but is INERT inside a linked feature worktree - which is exactly why
# block-clearance-token-write.js exists as the primary, location-independent gate
# (marker-gate.js is defence in depth). Locking `linked -> allow` here documents
# that division of labour; it is NOT a statement that forging a marker from a
# worktree is permitted overall.
# ===========================================================================
for sc in $SCENARIOS; do
    lbl="${sc%%|*}"; dir="${sc#*|}"
    case "$lbl" in
        linked) want=allow ;;
        *)      want=block ;;
    esac
    ref=$(run_guard Bash "mkdir -p $WF_N && echo x > $WF_N/$SID.workflow-off" "$dir" single on)
    assert_eq "K1 [$lbl/Bash] reference verdict for a .workflow-off marker forge" "$want" "$ref"
    for t in runInTerminal runCommands; do
        got=$(run_guard "$t" "mkdir -p $WF_N && echo x > $WF_N/$SID.workflow-off" "$dir" single on)
        assert_eq "K2 [$lbl/$t] marker-forge verdict matches Bash" "$ref" "$got"
    done
done

# ===========================================================================
# Section E - the EDIT-WRITE class writing into the workflow state dir.
#
# The state dir is outside every git repo, so handle-edit-write.js fail-OPENs
# there (that is deliberate: clearance/staging writes by Edit/Write must not be
# blocked). The property under test is that all five members agree - editFiles
# and NotebookEdit reached this hook with no coverage at all before #1780
# round-4, and the batched `edits[]` form is a second entry point into the same
# decision.
# ===========================================================================
EREF=$(run_guard Edit "$WF_N/$SID.json" "$MAIN" single on)
assert_eq "E0 reference: Edit into the workflow state dir is allowed (fail-open, non-git target)" "allow" "$EREF"
for t in $EDIT_WRITE_TOOLS; do
    got=$(run_guard "$t" "$WF_N/$SID.json" "$MAIN" single on)
    assert_eq "E1 [$t single] state-dir write matches Edit" "$EREF" "$got"
done
for t in MultiEdit editFiles NotebookEdit; do
    got=$(run_guard "$t" "$WF_N/$SID.json" "$MAIN" batch on)
    assert_eq "E2 [$t batched edits[]] state-dir write matches Edit" "$EREF" "$got"
done

# ===========================================================================
# Section O - ENFORCE_WORKTREE=off must disarm the guard for EVERY write-capable
# tool, in every blocking scenario.
#
# The off switch is read once, before any tool-name dispatch, so a regression
# here is not "one tool leaks" but "the documented opt-out silently stops
# working for the tools nobody wrote a case for". Controls in section C prove
# the same payloads really do block when the switch is on, so a hook that
# allowed everything cannot pass both sections.
# ===========================================================================
for sc in "main|$MAIN" "protected|$WTP"; do
    lbl="${sc%%|*}"; dir="${sc#*|}"
    for t in $EDIT_WRITE_TOOLS; do
        got=$(run_guard "$t" "$(node_path "$dir")/notes.txt" "$dir" single off)
        assert_eq "O1 [$lbl/$t] ENFORCE_WORKTREE=off allows the in-repo write" "allow" "$got"
    done
    for t in $COMMAND_TOOLS; do
        got=$(run_guard "$t" "echo x > $(node_path "$dir")/notes.txt" "$dir" single off)
        assert_eq "O2 [$lbl/$t] ENFORCE_WORKTREE=off allows the in-repo write" "allow" "$got"
    done
done

# O3 - falsy spellings of the switch (the recognised set in
# enforce-worktree/config.js: off|0|false|no|disabled). A guard that only
# honoured the literal string "off" would leave the documented spellings armed.
for v in 0 false no disabled; do
    got=$(run_guard Bash "echo x > $(node_path "$MAIN")/notes.txt" "$MAIN" single "$v")
    assert_eq "O3 [main/Bash] ENFORCE_WORKTREE=$v is honoured as off" "allow" "$got"
done
# O4 - an UNRECOGNISED value must fail SAFE (enforcement stays ON).
got=$(run_guard Bash "echo x > $(node_path "$MAIN")/notes.txt" "$MAIN" single "maybe")
assert_eq "O4 [main/Bash] unrecognised ENFORCE_WORKTREE value keeps enforcement ON" "block" "$got"

# ===========================================================================
# Section C - non-vacuity controls for section O: same payloads, switch ON.
# ===========================================================================
got=$(run_guard Edit "$(node_path "$MAIN")/notes.txt" "$MAIN" single on)
assert_eq "C1 control: Edit in the main checkout blocks when ENFORCE_WORKTREE=on" "block" "$got"
got=$(run_guard Bash "echo x > $(node_path "$MAIN")/notes.txt" "$MAIN" single on)
assert_eq "C2 control: Bash write in the main checkout blocks when ENFORCE_WORKTREE=on" "block" "$got"
got=$(run_guard runCommands "echo x > $(node_path "$WTP")/notes.txt" "$WTP" single on)
assert_eq "C3 control: runCommands write on a protected branch blocks when ENFORCE_WORKTREE=on" "block" "$got"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
