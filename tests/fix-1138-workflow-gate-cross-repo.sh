#!/usr/bin/env bash
# fix-1138-workflow-gate-cross-repo.sh
# Tests: hooks/workflow-gate.js, hooks/workflow-gate/repo-resolution.js
# Tags: scope:issue-specific
# L3 gap (what this test does NOT catch):
# - Real Claude Code PreToolUse hook firing path (only exercises node hook directly)
# - Windows-vs-WSL CWD drift behavior in the real VS Code extension host
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration
#
# Covers two issues:
#   #1138 — cross-repo bypass: commits to a repo OTHER than the agents session
#           repo must skip agents workflow-state enforcement (approve).
#   #1112 — cleanup exemption: cleanup=pending must be exempted in a linked
#           worktree context (parallel to the user_verification exemption),
#           but must still block in the main worktree context.
#
# TDD status: the source changes (isAgentsSessionRepo + cross-repo bypass for
# #1138, and the cleanup isWorktreeContext() exemption for #1112) do NOT exist
# yet. Cases marked "RED until impl" are expected to FAIL against current source.
# Each such case prints "(expected RED until <issue> implemented)" on failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE_HOOK="$AGENTS_DIR/hooks/workflow-gate.js"

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
# subprocesses can chdir into the repo. Mirrors tests/fix-953-split-robust-workflow.sh.
TMP_ROOT="$(run_with_timeout node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))")"
TEST_ROOT="$TMP_ROOT/fix-1138-cross-repo-$$"
mkdir -p "$TEST_ROOT"
trap 'rm -rf "$TEST_ROOT" 2>/dev/null || true' EXIT

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
# $1=workflow_dir $2=project_dir $3=agents_config_dir $4=hook_input_json
run_gate_win() {
    local wfdir="$1" projdir="$2" agentsdir="$3" json="$4"
    echo "$json" | CLAUDE_PROJECT_DIR="$projdir" CLAUDE_WORKFLOW_DIR="$wfdir" \
        AGENTS_CONFIG_DIR="$agentsdir" run_with_timeout node "$GATE_HOOK" 2>/dev/null || true
}

# Per-case workflow dir + state writer.
new_wf() {
    local wf="$TEST_ROOT/wf-$1"
    mkdir -p "$wf"
    printf '%s' "$2" > "$wf/sess.json"
    echo "$wf"
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

# Case 1: git -C <foreign-repo> + INCOMPLETE agents workflow → approve (bypass).
# RED until #1138: foreign repo is not the agents session repo, so workflow
# enforcement must be skipped even though `detail` is pending.
AGENTS1=$(mk_repo "$TEST_ROOT/c1-agents")
FOREIGN1=$(mk_repo "$TEST_ROOT/c1-foreign")
WF1=$(new_wf "c1" "$(state_with detail pending)")
R1=$(run_gate_win "$WF1" "$FOREIGN1" "$AGENTS1" "$(COMMIT_JSON_TARGET "$FOREIGN1")")
assert_approve "1. foreign repo + incomplete agents workflow → approve (cross-repo bypass)" "$R1" \
    "(expected RED until #1138 implemented)"

# Case 2: git -C <foreign-repo> + COMPLETE agents workflow → approve (always exempt).
# GREEN now (complete state approves) and after #1138 (bypass). Pins that a
# foreign-repo commit is never harder to land than an agents-repo commit.
AGENTS2=$(mk_repo "$TEST_ROOT/c2-agents")
FOREIGN2=$(mk_repo "$TEST_ROOT/c2-foreign")
WF2=$(new_wf "c2" "$(state_with)")
R2=$(run_gate_win "$WF2" "$FOREIGN2" "$AGENTS2" "$(COMMIT_JSON_TARGET "$FOREIGN2")")
assert_approve "2. foreign repo + complete agents workflow → approve (always exempt)" "$R2"

# Case 3: git -C <linked-worktree-of-agents> + INCOMPLETE → block (enforce).
# A linked worktree of the agents repo shares the same git common-dir, so it IS
# the agents session repo — enforcement must apply. GREEN now and after #1138.
AGENTS3=$(mk_repo "$TEST_ROOT/c3-agents")
WT3=$(add_worktree "$AGENTS3" "$TEST_ROOT/c3-wt" "fix1138-c3")
WF3=$(new_wf "c3" "$(state_with detail pending)")
R3=$(run_gate_win "$WF3" "$WT3" "$AGENTS3" "$(COMMIT_JSON_TARGET "$WT3")")
assert_block "3. linked worktree of agents + incomplete → block (same git common-dir → enforce)" "$R3"

# Case 4: git -C <nonexistent-path> + INCOMPLETE → block (fail-closed).
# A nonexistent target cannot be proven to be a foreign (non-agents) repo, so the
# bypass must NOT engage; the gate falls through to state enforcement and blocks.
# GREEN now and after #1138 (fail-closed is the safe default).
AGENTS4=$(mk_repo "$TEST_ROOT/c4-agents")
NONEXIST4="$TEST_ROOT/c4-does-not-exist-xyz"
WF4=$(new_wf "c4" "$(state_with detail pending)")
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
echo "PASS: $PASS, FAIL: $FAIL (Cases 1 and 5 are expected RED until #1138/#1112 source impl is done)"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
