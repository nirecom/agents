#!/usr/bin/env bash
# Tests: hooks/workflow-state/resolve-worktree-path.js, bin/resolve-worktree-path, skills/review-tests/scripts/select-staged-files.sh
# Tags: scope:issue-specific, pwsh-not-required, worktree, session-id
# Part of tests/fix-882-resolve-worktree-path.sh (rules/coding/file-split.md).
# Cases A-L: the original #882 worktree-aware selection contract (A-H) plus the
# #950 state.session_worktree fallback (I-L). Fixture, env isolation and every
# shared helper live in the dispatcher; this part only holds the assertions.

# Helper: write state JSON with both cwd and optional session_worktree.
# $1: cwd value (node-form path)
# $2: session_worktree value (node-form path | "null" | "" to omit)
write_state_950() {
  local cwd_val="$1"
  local sw_val="$2"
  local sw_line=""
  if [[ "$sw_val" = "null" ]]; then
    sw_line='"session_worktree": null,'
  elif [[ -n "$sw_val" ]]; then
    sw_line="\"session_worktree\": \"$sw_val\","
  fi
  cat > "$WF_DIR/$SESSION_ID.json" <<EOF
{
  "version": 1,
  "session_id": "$SESSION_ID",
  "created_at": "2026-07-18T00:00:00.000Z",
  "cwd": "$cwd_val",
  $sw_line
  "git_branch": "wt-branch-a",
  "steps": {}
}
EOF
}

# Helper: invoke the JS resolver directly (not the bin wrapper) so we can
# inspect the resolveSessionWorktreePath() return value in isolation.
# Every session-identity variable the developer's live session exports is pinned
# here, not only the two id names: once H1's disagreement check lands, an
# inherited CLAUDE_CODE_SESSION_ID would fail-close these cases (false RED) and an
# inherited CLAUDE_ENV_FILE / CLAUDE_TRANSCRIPT_BASE_DIR would resolve the real
# session (false GREEN) — rules/test/fixture-isolation.md.
run_resolver_js() {
  local sid="$1"
  SESSION_ID="$sid" \
  CLAUDE_SESSION_ID="" \
  CLAUDE_CODE_SESSION_ID="" \
  CLAUDE_ENV_FILE="" \
  CLAUDE_TRANSCRIPT_BASE_DIR="$TRANSCRIPTS_NODE" \
  CLAUDE_WORKFLOW_DIR="$WF_DIR_NODE" \
  WORKFLOW_PLANS_DIR="$PLANS_DIR_NODE" \
  AGENTS_CONFIG_DIR="$AGENTS_NODE" \
    bash "$RUN_TIMEOUT" 30 node -e "
const { resolveSessionWorktreePath } = require('$AGENTS_NODE/hooks/workflow-state/resolve-worktree-path.js');
const result = resolveSessionWorktreePath('$sid');
process.stdout.write(result === null ? '' : result);
" 2>/dev/null
}

run_cases_882_950() {

# ---------------------------------------------------------------------------
# Case A: CLI returns linked worktree path when state.cwd is a linked worktree.
# The id reaches the CLI through CLAUDE_CODE_SESSION_ID (see run_resolver).
# ---------------------------------------------------------------------------
caseA_got="$(run_resolver "$SESSION_ID" "state" "wta")"
if [[ "$caseA_got" = "$WTA_NODE" ]]; then
  pass "Case A (linked worktree resolved): got '$caseA_got'"
else
  fail "Case A (linked worktree resolved): got '$caseA_got', expected '$WTA_NODE'"
fi

# ---------------------------------------------------------------------------
# Case B: CLI returns empty string when state.cwd is the main worktree.
# Case A pins that this very env resolves the session, so the emptiness here can
# only be the main-worktree rejection — not a session id that never resolved,
# which would make this case pass for the wrong reason.
# ---------------------------------------------------------------------------
caseB_got="$(run_resolver "$SESSION_ID" "state" "main")"
if [[ -z "$caseB_got" && "$caseA_got" = "$WTA_NODE" ]]; then
  pass "Case B (main worktree rejected, same env resolved in Case A): empty string as expected"
else
  fail "Case B (main worktree rejected): got '$caseB_got' (Case A control='$caseA_got'), expected empty with a resolving control"
fi

# ---------------------------------------------------------------------------
# Case C: no session id reaches the CLI from ANY of the three env vars
# (SESSION_ID, CLAUDE_SESSION_ID, CLAUDE_CODE_SESSION_ID) -> empty stdout.
# Must stay green after C1: widening the read to CLAUDE_CODE_SESSION_ID adds a
# supply source, it must not turn "nothing supplied" into a filesystem guess.
# ---------------------------------------------------------------------------
caseC_got="$(run_resolver "" "state" "wta")"
if [[ -z "$caseC_got" ]]; then
  pass "Case C (no session id in env): empty string as expected"
else
  fail "Case C (no session id in env): got '$caseC_got', expected empty"
fi

# ---------------------------------------------------------------------------
# Case D: CLI returns "NOSTATE" when state file is absent for the session
# ---------------------------------------------------------------------------
caseD_got="$(run_resolver "$SESSION_ID" "nostate" "wta")"
if [[ "$caseD_got" = "NOSTATE" ]]; then
  pass "Case D (state file absent): got 'NOSTATE' as expected"
else
  fail "Case D (state file absent): got '$caseD_got', expected 'NOSTATE'"
fi

# ---------------------------------------------------------------------------
# Case E [core]: process cwd = main worktree, state.cwd = linked worktree.
# stdout must contain ONLY wtA's staged files, NOT the main worktree's files.
# ---------------------------------------------------------------------------
run_select "$MAIN_REPO" "$SESSION_ID" "state" "wta"
caseE_got="$SELECT_OUT"
if echo "$caseE_got" | grep -q "fixture-wta.sh" && ! echo "$caseE_got" | grep -q "fixture-main.sh"; then
  pass "Case E (worktree-aware selection): wtA files only, no main files"
else
  fail "Case E (worktree-aware selection): got '$caseE_got' (expect fixture-wta.sh, NOT fixture-main.sh)"
fi

# ---------------------------------------------------------------------------
# Case F: state.cwd = main worktree -> exit code 3, empty stdout
# (no cwd fallback — explicit skip).
# ---------------------------------------------------------------------------
run_select "$WTA" "$SESSION_ID" "state" "main"
caseF_got="$SELECT_OUT"
if [[ "$SELECT_RC" -eq 3 && -z "$caseF_got" ]]; then
  pass "Case F (main worktree state -> skip): exit 3, empty stdout"
else
  fail "Case F (main worktree state -> skip): rc=$SELECT_RC out='$caseF_got', expected rc=3 empty"
fi

# ---------------------------------------------------------------------------
# Case G: state file absent (NOSTATE) -> falls back to process cwd.
# Run from cwd=wtA -> selects wtA's staged files.
# ---------------------------------------------------------------------------
run_select "$WTA" "$SESSION_ID" "nostate" "wta"
caseG_got="$SELECT_OUT"
if echo "$caseG_got" | grep -q "fixture-wta.sh"; then
  pass "Case G (NOSTATE -> cwd fallback): selected wtA files from cwd"
else
  fail "Case G (NOSTATE -> cwd fallback): got '$caseG_got' (rc=$SELECT_RC), expected fixture-wta.sh"
fi

# ---------------------------------------------------------------------------
# Case H: compute-staged-tests-token.js with $WORKTREE as argv[2] returns a
# non-empty token when the linked worktree has staged tests.
# The sibling of run_resolver_js's leak: argv[2] short-circuits resolveRepoDir()
# today, but an inherited session id would decide this token the moment that
# short-circuit is narrowed — and Case R compares against it, so a leak here
# false-greens two cases at once (rules/test/fixture-isolation.md).
# ---------------------------------------------------------------------------
caseH_got="$(SESSION_ID="" \
  CLAUDE_SESSION_ID="" \
  CLAUDE_CODE_SESSION_ID="" \
  CLAUDE_ENV_FILE="" \
  CLAUDE_TRANSCRIPT_BASE_DIR="$TRANSCRIPTS_NODE" \
  CLAUDE_WORKFLOW_DIR="$WF_DIR_NODE" \
  WORKFLOW_PLANS_DIR="$PLANS_DIR_NODE" \
  AGENTS_CONFIG_DIR="$AGENTS_NODE" \
  bash "$RUN_TIMEOUT" 30 node "$COMPUTE_JS" "$WTA_NODE" 2>/dev/null)"
if [[ -n "$caseH_got" ]]; then
  pass "Case H (token for linked worktree): non-empty token '$caseH_got'"
else
  fail "Case H (token for linked worktree): empty token, expected non-empty"
fi

# ---------------------------------------------------------------------------
# Case I: state.cwd=main + state.session_worktree=valid linked worktree path
# Expected: resolveSessionWorktreePath returns that linked worktree path.
# ---------------------------------------------------------------------------
write_state_950 "$MAIN_NODE" "$WTA_NODE"
caseI_got="$(run_resolver_js "$SESSION_ID")"
if [[ "$caseI_got" = "$WTA_NODE" ]]; then
  pass "Case I (session_worktree fallback): got '$caseI_got'"
else
  fail "Case I (session_worktree fallback): got '$caseI_got', expected '$WTA_NODE'"
fi

# ---------------------------------------------------------------------------
# Case J: state.cwd=main + state.session_worktree=null -> null (empty stdout).
# ---------------------------------------------------------------------------
write_state_950 "$MAIN_NODE" "null"
caseJ_got="$(run_resolver_js "$SESSION_ID")"
if [[ -z "$caseJ_got" ]]; then
  pass "Case J (session_worktree=null -> empty): got empty as expected"
else
  fail "Case J (session_worktree=null -> empty): got '$caseJ_got', expected empty"
fi

# ---------------------------------------------------------------------------
# Case K: state.cwd=main + state.session_worktree=nonexistent path -> empty.
# ---------------------------------------------------------------------------
NONEXISTENT_PATH="$TMPDIR_BASE/does-not-exist"
write_state_950 "$MAIN_NODE" "$NONEXISTENT_PATH"
caseK_got="$(run_resolver_js "$SESSION_ID")"
if [[ -z "$caseK_got" ]]; then
  pass "Case K (session_worktree=nonexistent -> empty): got empty as expected"
else
  fail "Case K (session_worktree=nonexistent -> empty): got '$caseK_got', expected empty"
fi

# ---------------------------------------------------------------------------
# Case L: state.cwd=main + state.session_worktree=main worktree path
# (isMainWorktree=true) -> must also be rejected, return empty.
# ---------------------------------------------------------------------------
write_state_950 "$MAIN_NODE" "$MAIN_NODE"
caseL_got="$(run_resolver_js "$SESSION_ID")"
if [[ -z "$caseL_got" ]]; then
  pass "Case L (session_worktree=main -> empty): got empty as expected"
else
  fail "Case L (session_worktree=main -> empty): got '$caseL_got', expected empty"
fi

}
