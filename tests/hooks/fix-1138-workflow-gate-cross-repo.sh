#!/usr/bin/env bash
# fix-1138-workflow-gate-cross-repo.sh
# Tests: hooks/workflow-gate.js, hooks/workflow-gate/repo-resolution.js
# Tags: scope:issue-specific
# L3 gap (what this test does NOT catch): the real Claude Code PreToolUse hook firing path (only exercises node hook directly); Windows-vs-WSL CWD drift behavior in the real VS Code extension host.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration

# Covers two issues:
#   #1138 — cross-repo bypass: a commit to a repo OTHER than the session's work-target repo skips workflow-state enforcement.
#   #1112 — cleanup exemption: cleanup=pending must be exempted in a linked worktree context (parallel to the user_verification exemption), but must still block in the main worktree context.

# #1633: checked only once the WF has begun AND the target is in the WF target repo set (state cwd + intent worktrees); no cwd → set unknown → checked.
# The gate-checkout attach + AGENTS_MAIN_ROOT stay as a regression guard: they must no longer bypass.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE_HOOK="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-gate.js"

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
    else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

# Source the shared helpers (provides run_gate_cross_repo, JSON builders, etc.).
# NOTE: helpers.sh creates an MSYS-style ($TMPDIR_BASE) WORKFLOW_DIR on source.
# MSYS paths (/tmp/...) are NOT resolvable by Windows-native node's execSync, so
# git-subprocess-dependent checks (isWorktreeContext) silently fail there. For the
# worktree/cleanup cases below we therefore build repos under a Windows-native
# temp root and override WORKFLOW_DIR per-test.
# shellcheck source=feature-robust-workflow/helpers.sh
source "$SCRIPT_DIR/feature-robust-workflow/helpers.sh"

# Windows-native temp root (forward-slashed) so isWorktreeContext()'s git
# subprocesses can chdir into the repo. Mirrors tests/bin/fix-953-split-robust-workflow.sh.
TMP_ROOT="$(run_with_timeout node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))")"
TEST_ROOT="$TMP_ROOT/fix-1138-cross-repo-$$"
mkdir -p "$TEST_ROOT"
# This trap replaces the helpers.sh one, so it also removes that file's $TMPDIR_BASE (#2512).
trap 'rm -rf "$TEST_ROOT" "$TMPDIR_BASE" 2>/dev/null || true' EXIT

# Plans-dir isolation (#1799): supervisor-emit must never write into the
# developer's real ~/.workflow-plans/. Pinned alongside WORKFLOW_STATE_DIR.
WORKFLOW_PLANS_DIR="$TEST_ROOT/plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
export WORKFLOW_PLANS_DIR
# isolation (#2512): the state dir is pinned file-wide too, not only per hook call.
export WORKFLOW_STATE_DIR="$TEST_ROOT/workflow-state"
mkdir -p "$WORKFLOW_STATE_DIR"

# The gate treats the repo its own checkout belongs to as the session repo: the hook is launched
# from a copy of this checkout, attached per case to that case's "agents" repo.
# shellcheck source=tests/lib/session-repo-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/session-repo-fixture.sh"
GATE_CHECKOUT="$TEST_ROOT/gate-checkout"
session_repo_fixture_create "$GATE_CHECKOUT" || { echo "FAIL: cannot copy the checkout for the gate"; exit 1; }
GATE_HOOK="$(session_repo_fixture_path "$GATE_CHECKOUT" hooks/workflow-gate.js)"

# Build a fresh git repo at $1. core.hooksPath is emptied so the agents
# pre-commit hook (ENFORCE_WORKTREE / scan-outbound) does not fire on the
# throwaway repo's commit.
mk_repo() {
    local r="$1"
    mkdir -p "$r"
    git -C "$r" init -q
    git -C "$r" config core.hooksPath ""
    git -C "$r" config user.email "test@example.com"
    git -C "$r" config user.name "Test"
    echo "init" > "$r/README.md"
    git -C "$r" add README.md
    git -C "$r" commit -q -m "initial" 2>/dev/null
    echo "$r"
}

# Add a linked worktree of $1 at $2 on a fresh non-default branch.
add_worktree() {
    local main="$1" wt="$2" branch="$3"
    git -C "$main" worktree add -q -b "$branch" "$wt" 2>/dev/null
    git -C "$wt" config core.hooksPath ""
    echo "$wt"
}

# State JSON: every gated step complete EXCEPT $1, which is set to $2.
# Omit $1/$2 to get an all-complete state. `research` is a NON_GATE_STEP so it
# is always complete here (its status never gates).
state_with() {
    local odd_step="${1:-}" odd_status="${2:-}"
    local s_detail=complete s_cleanup=complete s_uv=complete s_wt=complete
    case "$odd_step" in
        detail)  s_detail="$odd_status" ;;
        cleanup) s_cleanup="$odd_status" ;;
        user_verification) s_uv="$odd_status" ;;
        write_tests) s_wt="$odd_status" ;;
    esac
    cat <<JSON
{
  "version": 1,
  "session_id": "sess",
  "created_at": "2026-06-27T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete"},
    "outline":           {"status": "complete"},
    "detail":            {"status": "$s_detail"},
    "write_tests":       {"status": "$s_wt"},
    "review_tests":      {"status": "skipped"},
    "review_security":   {"status": "complete"},
    "run_tests":         {"status": "complete"},
    "docs":              {"status": "complete"},
    "user_verification": {"status": "$s_uv"},
    "cleanup":           {"status": "$s_cleanup"}
  }
}
JSON
}

# Run the gate against an explicit Windows-native WORKFLOW_DIR.
# $1=workflow_dir $2=project_dir $3=script_checkout_root $4=hook_input_json
run_gate_win() {
    local wfdir="$1" projdir="$2" agentsdir="$3" json="$4"
    session_repo_fixture_attach "$GATE_CHECKOUT" "$agentsdir" || return 1
    echo "$json" | CLAUDE_PROJECT_DIR="$projdir" WORKFLOW_STATE_DIR="$wfdir" \
        AGENTS_MAIN_ROOT="$agentsdir" run_with_timeout node "$GATE_HOOK" 2>/dev/null || true
}

# Per-case workflow dir + state writer.
new_wf() {
    local wf="$TEST_ROOT/wf-$1"
    mkdir -p "$wf"
    printf '%s' "$2" > "$wf/sess.json"
    echo "$wf"
}

# with_cwd <state-json> <cwd> — the same state carrying the session-start cwd (#1633 target set).
with_cwd() {
    local s="$1"
    printf '%s' "${s/\"created_at\"/\"cwd\": \"$2\", \"created_at\"}"
}

assert_approve() {
    local desc="$1" result="$2" red_note="${3:-}"
    if echo "$result" | grep -q '"approve"'; then pass "$desc"
    else
        if [ -n "$red_note" ]; then
            fail "$desc  $red_note — got: $result"
        else
            fail "$desc — expected approve, got: $result"
        fi
    fi
}

assert_block() {
    local desc="$1" result="$2"
    if echo "$result" | grep -q '"block"'; then pass "$desc"
    else fail "$desc — expected block, got: $result"; fi
}

COMMIT_JSON_TARGET() {
    # $1 = repo path to embed in `git -C <path> commit`
    printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m x"},"session_id":"sess"}' "$1"
}

echo "=== fix-1138 / fix-1112: cross-repo bypass + cleanup exemption ==="

# ---------------------------------------------------------------------------
# Cross-repo bypass (#1138)
# ---------------------------------------------------------------------------

# Case 1: begun, cwd=work repo, git -C <foreign-repo> + INCOMPLETE workflow → approve (outside the set).
AGENTS1=$(mk_repo "$TEST_ROOT/c1-agents")
FOREIGN1=$(mk_repo "$TEST_ROOT/c1-foreign")
WF1=$(new_wf "c1" "$(with_cwd "$(state_with detail pending)" "$AGENTS1")")
R1=$(run_gate_win "$WF1" "$FOREIGN1" "$AGENTS1" "$(COMMIT_JSON_TARGET "$FOREIGN1")")
assert_approve "1. cwd=work repo + foreign repo commit + incomplete workflow → approve (outside the WF target set)" "$R1"

# Case 1b: same commit with NO cwd in the state → block. The target set cannot be built,
# so the gate cannot prove the target is outside it and applies.
AGENTS1B=$(mk_repo "$TEST_ROOT/c1b-agents")
FOREIGN1B=$(mk_repo "$TEST_ROOT/c1b-foreign")
WF1B=$(new_wf "c1b" "$(state_with detail pending)")
R1B=$(run_gate_win "$WF1B" "$FOREIGN1B" "$AGENTS1B" "$(COMMIT_JSON_TARGET "$FOREIGN1B")")
assert_block "1b. no cwd (target set unknown) + foreign repo commit + incomplete → block" "$R1B"

# Case 1c: workflow_init pending (the WF has not begun) + commit to the work repo → approve.
AGENTS1C=$(mk_repo "$TEST_ROOT/c1c-agents")
# Build the fixture with node: bash ${.../pattern/replacement} closes at the first }
# in the replacement string, so {"status": "pending"} produced malformed JSON.
WF1C="$TEST_ROOT/wf-c1c"
mkdir -p "$WF1C"
WF1C_HELPER="$TEST_ROOT/c1c-state.js"
cat >"$WF1C_HELPER" <<'JS'
"use strict";
const [, , root, out, cwd] = process.argv;
const { VALID_STEPS } = require(root + "/hooks/workflow-state");
const steps = {};
for (const s of VALID_STEPS) steps[s] = { status: "complete", updated_at: "2026-06-27T10:00:00.000Z" };
steps.workflow_init = { status: "pending", updated_at: "2026-06-27T10:00:00.000Z" };
steps.detail = { status: "pending", updated_at: "2026-06-27T10:00:00.000Z" };
const st = { version: 1, session_id: "sess", cwd, created_at: "2026-06-27T10:00:00.000Z", steps };
require("fs").writeFileSync(out, JSON.stringify(st));
JS
run_with_timeout node "$WF1C_HELPER" "$SCRIPT_CHECKOUT_ROOT" "$WF1C/sess.json" "$AGENTS1C"
R1C=$(run_gate_win "$WF1C" "$AGENTS1C" "$AGENTS1C" "$(COMMIT_JSON_TARGET "$AGENTS1C")")
assert_approve "1c. workflow_init pending (not begun) + work repo commit + incomplete → approve" "$R1C"

# Case 2: cwd=work repo, git -C <foreign-repo> + COMPLETE workflow → approve (always exempt).
# Pins that a foreign-repo commit is never harder to land than a work-repo commit.
AGENTS2=$(mk_repo "$TEST_ROOT/c2-agents")
FOREIGN2=$(mk_repo "$TEST_ROOT/c2-foreign")
WF2=$(new_wf "c2" "$(with_cwd "$(state_with)" "$AGENTS2")")
R2=$(run_gate_win "$WF2" "$FOREIGN2" "$AGENTS2" "$(COMMIT_JSON_TARGET "$FOREIGN2")")
assert_approve "2. foreign repo + complete agents workflow → approve (always exempt)" "$R2"

# Case 3: cwd=work repo, git -C <linked-worktree-of-work-repo> + INCOMPLETE → block.
# A linked worktree shares the git common-dir, so it is the same repo in the target set.
AGENTS3=$(mk_repo "$TEST_ROOT/c3-agents")
WT3=$(add_worktree "$AGENTS3" "$TEST_ROOT/c3-wt" "fix1138-c3")
WF3=$(new_wf "c3" "$(with_cwd "$(state_with detail pending)" "$AGENTS3")")
R3=$(run_gate_win "$WF3" "$WT3" "$AGENTS3" "$(COMMIT_JSON_TARGET "$WT3")")
assert_block "3. linked worktree of agents + incomplete → block (same git common-dir → enforce)" "$R3"

# Case 4: cwd=work repo, git -C <nonexistent-path> + INCOMPLETE → block (fail-closed).
# A nonexistent target cannot be proven outside the set, so it is checked.
AGENTS4=$(mk_repo "$TEST_ROOT/c4-agents")
NONEXIST4="$TEST_ROOT/c4-does-not-exist-xyz"
WF4=$(new_wf "c4" "$(with_cwd "$(state_with detail pending)" "$AGENTS4")")
R4=$(run_gate_win "$WF4" "$NONEXIST4" "$AGENTS4" "$(COMMIT_JSON_TARGET "$NONEXIST4")")
assert_block "4. nonexistent target path + incomplete → block (fail-closed)" "$R4"

# ---------------------------------------------------------------------------
# cleanup isWorktreeContext() exemption (#1112)
# ---------------------------------------------------------------------------

# Case 5: commit from linked-worktree context + cleanup=pending (all else complete)
# → approve. RED until #1112: cleanup must be deferred to the /worktree-end
# boundary in worktree context (parallel to user_verification's exemption).
AGENTS5=$(mk_repo "$TEST_ROOT/c5-agents")
WT5=$(add_worktree "$AGENTS5" "$TEST_ROOT/c5-wt" "fix1112-c5")
WF5=$(new_wf "c5" "$(state_with cleanup pending)")
# Provide cwd so the hook can confirm worktree context (mirrors real Claude Code).
J5=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m x","cwd":"%s"},"session_id":"sess"}' "$WT5" "$WT5")
R5=$(run_gate_win "$WF5" "$WT5" "$AGENTS5" "$J5")
assert_approve "5. linked-worktree context + cleanup=pending → approve (isWorktreeContext exempts cleanup)" "$R5" \
    "(expected RED until #1112 implemented)"

# Case 6: commit from MAIN worktree context + cleanup=pending (all else complete)
# → block. The cleanup exemption is worktree-scoped: in the main worktree the
# cleanup gate still fires. GREEN now and after #1112.
AGENTS6=$(mk_repo "$TEST_ROOT/c6-agents")
WF6=$(new_wf "c6" "$(state_with cleanup pending)")
J6='{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"session_id":"sess"}'
R6=$(run_gate_win "$WF6" "$AGENTS6" "$AGENTS6" "$J6")
assert_block "6. main worktree context + cleanup=pending → block (cleanup not exempted outside worktree)" "$R6"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Cross-repo bypass + cleanup exemption tests ==="
echo "PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
