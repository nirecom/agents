#!/usr/bin/env bash
# Tests: bin/resolve-worktree-path, hooks/workflow-state/session-id.js
# Tags: scope:issue-specific, pwsh-not-required, worktree, session-id, ssot
# Part of tests/fix-882-resolve-worktree-path.sh (rules/coding/file-split.md).
# Cases (i)-(viii) (#2270 S2-1): the `--session <id>` CLI contract. A valid value
# outranks the env; an empty value means "omitted" and may fall back to the env;
# a malformed value, an unknown flag and a missing value are CLI contract
# violations that stop at exit 2 WITHOUT silently resolving another session.
ARG_SID_A="arg-2270-sid-a"
ARG_SID_B="arg-2270-sid-b"
ARG_SID_NOSTATE="arg-2270-sid-nostate"

ARG_RC=0
ARG_OUT=""
ARG_ERR=""
# Run bin/resolve-worktree-path with RAW argv, keeping rc and stderr — the
# dispatcher's run_resolver_env discards both, and exit 2 plus its one-line
# diagnostic IS the contract these cases assert.
#   $1: CLAUDE_CODE_SESSION_ID value ("" for none); $2.. : argv for the CLI
run_resolver_argv() {
  local ccsid="$1"
  shift
  local outf="$TMPDIR_BASE/arg-2270.out"
  local errf="$TMPDIR_BASE/arg-2270.err"
  (
    cd "$TMPDIR_BASE" || exit 1
    SESSION_ID="" \
    CLAUDE_SESSION_ID="" \
    CLAUDE_CODE_SESSION_ID="$ccsid" \
    CLAUDE_ENV_FILE="" \
    CLAUDE_TRANSCRIPT_BASE_DIR="$TRANSCRIPTS_NODE" \
    CLAUDE_WORKFLOW_DIR="$WF_DIR_NODE" \
    WORKFLOW_PLANS_DIR="$PLANS_DIR_NODE" \
    AGENTS_CONFIG_DIR="$AGENTS_NODE" \
      bash "$RUN_TIMEOUT" 30 "$RESOLVER_BIN" "$@"
  ) >"$outf" 2>"$errf"
  ARG_RC=$?
  ARG_OUT="$(cat "$outf")"
  ARG_ERR="$(cat "$errf")"
}

# $1 label, $2 want stdout — a resolving call also has to exit 0.
check_arg_ok() {
  if [[ "$ARG_OUT" = "$2" && "$ARG_RC" -eq 0 ]]; then
    pass "$1: got '$ARG_OUT' with rc 0"
  else
    fail "$1: got '$ARG_OUT' rc=$ARG_RC stderr='$ARG_ERR', want '$2' rc=0"
  fi
}

# $1 label, $2 substring required on stderr ("" = any) — a rejected call must
# exit 2 with NOTHING on stdout, so no caller can mistake it for a resolution.
check_arg_rejected() {
  if [[ "$ARG_RC" -eq 2 && -z "$ARG_OUT" ]] && echo "$ARG_ERR" | grep -q "${2:-resolve-worktree-path}"; then
    pass "$1: rc=2, empty stdout, stderr='$ARG_ERR'"
  else
    fail "$1: rc=$ARG_RC out='$ARG_OUT' stderr='$ARG_ERR', want rc=2 + empty stdout + stderr matching '${2:-resolve-worktree-path}'"
  fi
}

run_cases_2270_arg() {

rm -f "$WF_DIR"/*.json
write_state_for "$ARG_SID_A" "$WTA_NODE"
write_state_for "$ARG_SID_B" "$WTB_NODE"

# ---------------------------------------------------------------------------
# (i) --session alone, nothing in the env: the flag is a full supply channel,
# which is what lets /review-tests hand the bridge an id it read itself.
# ---------------------------------------------------------------------------
run_resolver_argv "" --session "$ARG_SID_A"
check_arg_ok "Case (i) (--session only -> that session's worktree)" "$WTA_NODE"

# ---------------------------------------------------------------------------
# (ii) --session for a session with no state file keeps the documented
# "id but no state" answer, so callers keep their cwd fallback.
# ---------------------------------------------------------------------------
run_resolver_argv "" --session "$ARG_SID_NOSTATE"
check_arg_ok "Case (ii) (--session, no state -> NOSTATE)" "NOSTATE"

# ---------------------------------------------------------------------------
# (iii) the argument outranks the env: an explicit id is the caller stating
# WHICH session it means, and the ambient env must not override that.
# ---------------------------------------------------------------------------
run_resolver_argv "$ARG_SID_B" --session "$ARG_SID_A"
check_arg_ok "Case (iii) (--session beats CLAUDE_CODE_SESSION_ID)" "$WTA_NODE"

# ---------------------------------------------------------------------------
# (iv) --session "" is the omitted case, matching callers written as
# ${CC_SID:+--session "$CC_SID"}: the env still supplies the id, rc stays 0.
# ---------------------------------------------------------------------------
run_resolver_argv "$ARG_SID_B" --session ""
check_arg_ok "Case (iv) (--session '' -> omitted, env supplies)" "$WTB_NODE"

# ---------------------------------------------------------------------------
# (v) a malformed value is a contract violation, NOT a reason to fall back:
# falling back would answer with the CURRENT session's worktree while the
# caller asked about another one — silently reviewing the wrong tree.
# ---------------------------------------------------------------------------
run_resolver_argv "$ARG_SID_B" --session "../../etc"
check_arg_rejected "Case (v) (--session malformed -> exit 2, no env fallback)" "malformed"
if [[ "$ARG_OUT" != "$WTB_NODE" ]]; then
  pass "Case (v') (malformed --session never answers with the env session's worktree)"
else
  fail "Case (v') (malformed --session fell back to the env session): got '$ARG_OUT'"
fi

# ---------------------------------------------------------------------------
# (vi) an unknown flag is refused rather than ignored — an ignored flag turns a
# caller's typo into a silent answer about a different session.
# ---------------------------------------------------------------------------
run_resolver_argv "$ARG_SID_B" --bogus
check_arg_rejected "Case (vi) (unknown flag -> exit 2, empty stdout)" ""

# ---------------------------------------------------------------------------
# (vii) the value travels to node through the environment, never through string
# interpolation, so quotes and $(...) are inert text that the validator refuses.
# ---------------------------------------------------------------------------
run_resolver_argv "$ARG_SID_B" --session "a'b\$(echo pwned)"
check_arg_rejected "Case (vii) (shell metacharacters are data, not code)" ""
if ! echo "$ARG_OUT$ARG_ERR" | grep -q "pwned"; then
  pass "Case (vii') (no shell evaluation of the --session value)"
else
  fail "Case (vii') (--session value was evaluated): out='$ARG_OUT' err='$ARG_ERR'"
fi

# ---------------------------------------------------------------------------
# (viii) a trailing --session with no value is the same CLI contract violation
# as an unknown flag; it must not degrade into "omitted".
# ---------------------------------------------------------------------------
run_resolver_argv "$ARG_SID_B" --session
check_arg_rejected "Case (viii) (--session with a missing value -> exit 2)" ""

}
