# Part of tests/feature-1638-resolve-merge-base.sh (sourced, not standalone).
# Tests: bin/workflow/record-merge-base-baseline, bin/resolve-merge-base.sh, bin/select-tests.sh
# Tags: merge-base, baseline, approval, cli, security, recovery, scope:issue-specific, pwsh-not-required, TL2
#
# A — THE APPROVAL CLI'S ARGUMENTS, and P — THE RECOVERY IT EXISTS FOR.
#
# record-merge-base-baseline is the ONE sanctioned way to overwrite a write-once record. R16/R17
# cover the two interesting values of --base (a good one and two bad ones). What they do not
# cover is everything else about a CLI that is invited into the workflow by a stderr hint the
# model is told to run: a missing flag, an empty --reason, an unknown flag, and three inputs
# that arrive as text from a session the tool does not control (session id, reason, repo path).
#
# WHY THE ARGUMENT ROWS ARE SECURITY ROWS. The session id becomes part of a FILE PATH under the
# workflow directory, and the repo path is handed to git. A session id containing `..` writes
# outside the workflow directory; one containing shell metacharacters is only safe if nothing
# ever interpolates it into a command. Both are asserted by side effect (did a file appear where
# it must not?) rather than by inspecting the implementation.
#
# AND EVERY REJECTION IS ALSO AN INTEGRITY ROW. `--reason` is mandatory because the override is
# an audited decision; a rejected request that had already written the base would make the
# validation cosmetic. So each rejection row re-reads the stored baseline afterwards.
#
# P1-P4 are the other half: the recovery path END TO END. The stderr hint select-tests.sh prints
# on SUSPECT tells the user to approve a base and re-run, and nothing today proves that
# sequence actually terminates in a successful selection. P1-P4 run it: approve → resolve →
# select. Without them the hint is a documented procedure with no test behind it.

A_RC=0
A_OUT=""
A_ERR=""

run_record_cli() { # [args...]
  local o e
  o="$(mktemp "$TMPROOT/a-out.XXXXXX")"
  e="$(mktemp "$TMPROOT/a-err.XXXXXX")"
  A_RC=0
  env "CLAUDE_WORKFLOW_DIR=$WFDIR" node "$RECORD_CLI" "$@" >"$o" 2>"$e" || A_RC=$?
  A_OUT="$(cat "$o")"
  A_ERR="$(cat "$e")"
  rm -f "$o" "$e"
}

# A session whose baseline is already recorded, so "unchanged" is a comparison against a real
# value rather than against absence.
A_REPO=""
A_SID="sid-approve"
A_STORED=""
setup_approval_fixture() {
  A_REPO="$(repo_with_main)"
  node_state init "$A_SID" "$A_REPO" work >/dev/null
  node_state record "$A_SID" "$A_REPO" >/dev/null
  A_STORED="$(env "AGENTS_DIR=$AGENTS_DIR" "CLAUDE_WORKFLOW_DIR=$WFDIR" \
    node "$STATE_JS" field "$A_SID" base 2>/dev/null)"
}

stored_base() {
  env "AGENTS_DIR=$AGENTS_DIR" "CLAUDE_WORKFLOW_DIR=$WFDIR" \
    node "$STATE_JS" field "$A_SID" base 2>/dev/null
}

# One rejection row: the request must fail AND the stored baseline must survive it.
expect_rejected() { # <row-id> <desc>
  check "$1: $2 is rejected" "1" "$A_RC"
  check "$1-intact: and the stored baseline is untouched" "$A_STORED" "$(stored_base)"
}

a0_success_is_the_control() {
  local want
  want="$(git -C "$A_REPO" rev-parse HEAD~1)"
  run_record_cli --session "$A_SID" --base "$want" --reason "control row: a well-formed request" --repo "$A_REPO"
  check "A0-rc: a well-formed request succeeds" "0" "$A_RC"
  check_match "A0-out: and says what it recorded" 'RECORDED[[:space:]]+base=' "$A_OUT"
  check "A0-stored: with the requested base stored" "$want" "$(stored_base)"
  # Re-baseline the "unchanged" comparison for the rejection rows that follow.
  A_STORED="$(stored_base)"
}

a1_reason_is_mandatory() {
  local other
  other="$(git -C "$A_REPO" rev-parse HEAD)"
  run_record_cli --session "$A_SID" --base "$other" --repo "$A_REPO"
  expect_rejected "A1" "an override with no --reason"
  run_record_cli --session "$A_SID" --base "$other" --reason "" --repo "$A_REPO"
  expect_rejected "A2" "an override with an empty --reason"
  run_record_cli --session "$A_SID" --base "$other" --reason "   " --repo "$A_REPO"
  expect_rejected "A3" "an override whose --reason is only whitespace"
}

a4_required_flags_and_unknown_flags() {
  local other
  other="$(git -C "$A_REPO" rev-parse HEAD)"
  run_record_cli --base "$other" --reason "no session" --repo "$A_REPO"
  expect_rejected "A4" "a request with no --session"
  run_record_cli --session "$A_SID" --reason "no base" --repo "$A_REPO"
  expect_rejected "A5" "a request with no --base"
  run_record_cli
  expect_rejected "A6" "a request with no arguments at all"
  run_record_cli --session "$A_SID" --base "$other" --reason "unknown flag" --repo "$A_REPO" --force
  expect_rejected "A7" "a request carrying an unrecognised flag"
  # A silent rejection is a rejection nobody can act on: the caller is a model reading stderr.
  if [ -n "$A_ERR" ]; then
    pass "A7-stderr: and every rejection says why on stderr"
  else
    fail "A7-stderr: the rejection produced no message on stderr"
  fi
}

# The session id becomes a path under the workflow directory. `..` must not escape it, and
# metacharacters must not be interpreted. Both are checked by looking for the file the attack
# would create, not by reading the implementation.
a8_malicious_session_id() {
  local other canary="$TMPROOT/canary-session"
  other="$(git -C "$A_REPO" rev-parse HEAD~1)"
  rm -f "$canary" "$TMPROOT/escaped.json"

  run_record_cli --session "../escaped" --base "$other" --reason "path traversal" --repo "$A_REPO"
  if [ -e "$TMPROOT/escaped.json" ]; then
    fail "A8-traversal: a session id containing .. wrote outside the workflow directory"
  else
    pass "A8-traversal: a session id containing .. cannot write outside the workflow directory"
  fi
  check "A8-intact: and the real session's baseline is untouched" "$A_STORED" "$(stored_base)"

  run_record_cli --session "x; touch $canary" --base "$other" --reason "metacharacters" --repo "$A_REPO"
  if [ -e "$canary" ]; then
    rm -f "$canary"
    fail "A9-exec: a session id containing shell metacharacters was executed"
  else
    pass "A9-exec: a session id containing shell metacharacters is never executed"
  fi
}

# The reason is stored and later read back by a human. It must survive verbatim if accepted and
# must never be executed; those are different properties and an implementation can get one
# right while getting the other wrong.
a10_malicious_reason() {
  local other canary="$TMPROOT/canary-reason" reason
  other="$(git -C "$A_REPO" rev-parse HEAD~1)"
  reason="\$(touch $canary) && \`touch $canary\` | 'quoted'"
  rm -f "$canary"
  run_record_cli --session "$A_SID" --base "$other" --reason "$reason" --repo "$A_REPO"
  if [ -e "$canary" ]; then
    rm -f "$canary"
    fail "A10-exec: the --reason text was evaluated by a shell"
  else
    pass "A10-exec: a --reason containing shell metacharacters is never evaluated"
  fi
  if [ "$A_RC" = "0" ]; then
    check "A10-verbatim: an accepted reason is stored exactly as given" "$reason" \
      "$(env "AGENTS_DIR=$AGENTS_DIR" "CLAUDE_WORKFLOW_DIR=$WFDIR" \
        node "$STATE_JS" field "$A_SID" approved_reason 2>/dev/null)"
    A_STORED="$(stored_base)"
  else
    check "A10-intact: a rejected reason leaves the stored baseline alone" "$A_STORED" "$(stored_base)"
  fi
}

# --repo is handed to git. A path that is not a repository, and a path built to be executed if
# it is ever interpolated into a command line.
a11_repository_argument() {
  local other notrepo canary="$TMPROOT/canary-repo"
  other="$(git -C "$A_REPO" rev-parse HEAD~1)"
  notrepo="$(mktemp -d "$TMPROOT/notrepo-a.XXXXXX")"
  run_record_cli --session "$A_SID" --base "$other" --reason "not a git repo" --repo "$notrepo"
  expect_rejected "A11" "an override against a directory that is not a git repository"

  rm -f "$canary"
  run_record_cli --session "$A_SID" --base "$other" --reason "repo injection" --repo "$notrepo; touch $canary"
  if [ -e "$canary" ]; then
    rm -f "$canary"
    fail "A12-exec: the --repo value was executed"
  else
    pass "A12-exec: a --repo value containing shell metacharacters is never executed"
  fi
  check "A12-intact: and the stored baseline is untouched" "$A_STORED" "$(stored_base)"
}

# ============================================================================
# P — the approved base, end to end: approve → resolve → select.
# ============================================================================

# select-tests.sh resolves its siblings from its OWN location, so the recovery path can only be
# exercised inside a tree that has all of them. bin/ and hooks/ are copied REAL — the resolver
# especially, since the whole point is that the approved record reaches it — and only
# resolve-session-id is stubbed, because a throwaway session id cannot be discovered the way a
# live Claude Code session's is.
P_TREE=""
setup_recovery_tree() { # <sid>
  P_TREE="$(mktemp -d "$TMPROOT/ptree.XXXXXX")"
  cp -r "$AGENTS_DIR/bin" "$P_TREE/bin"
  cp -r "$AGENTS_DIR/hooks" "$P_TREE/hooks"
  mkdir -p "$P_TREE/tests"
  : > "$P_TREE/tests/feature-689-select-tests.sh"
  printf '#!/usr/bin/env bash\necho "%s"\n' "$1" > "$P_TREE/bin/resolve-session-id"
  chmod +x "$P_TREE/bin/resolve-session-id" 2>/dev/null || true
}

# A repository whose only post-base change touches bin/select-tests.sh, so a correct selection
# is a specific, nameable file rather than "something".
recovery_repo() { # ; prints the repo path
  local r
  r="$(new_repo main)"
  commit_file "$r" seed.txt 1 seed
  git -C "$r" switch -q -c work >/dev/null 2>&1
  commit_file "$r" bin/select-tests.sh 4 "the change under review"
  printf '%s' "$r"
}

p_recovery_end_to_end() {
  local repo approved sid="sid-p1" o e rc
  repo="$(recovery_repo)"
  approved="$(git -C "$repo" rev-parse main)"
  node_state init "$sid" "$repo" work >/dev/null
  node_state record "$sid" "$repo" >/dev/null
  setup_recovery_tree "$sid"

  run_record_cli --session "$sid" --base "$approved" --reason "user confirmed the branch point during run-tests" --repo "$repo"
  if [ "$A_RC" != "0" ]; then
    fail "P1: the approval itself failed (rc=$A_RC), so the recovery path cannot be exercised -- stderr [$A_ERR]"
    return
  fi
  pass "P1: the user's approval is accepted"

  # The resolver, unstubbed, reading the record the approval just wrote.
  HELPER_ENV=()
  run_helper "$repo" "$sid"
  check "P2-state: the approved base is adopted as a recorded baseline" "RECORDED" "$(kv state)"
  check "P2-source: labelled as the user's decision rather than a guess" "user-approved" "$(kv source)"
  check "P2-base: and it is the base the user approved" "$approved" "$(kv base)"

  # And the consumer that sent the user here in the first place now succeeds.
  o="$(mktemp "$TMPROOT/p-out.XXXXXX")"
  e="$(mktemp "$TMPROOT/p-err.XXXXXX")"
  rc=0
  (
    cd "$repo" || exit 1
    export CLAUDE_WORKFLOW_DIR="$WFDIR" AGENTS_CONFIG_DIR="$P_TREE"
    bash "$AGENTS_DIR/bin/run-with-timeout.sh" 60 bash "$P_TREE/bin/select-tests.sh" --auto
  ) >"$o" 2>"$e" || rc=$?
  local sel serr
  sel="$(cat "$o")"
  serr="$(cat "$e")"
  rm -f "$o" "$e"
  check "P3-rc: select-tests.sh --auto no longer aborts" "0" "$rc"
  if printf '%s\n' "$sel" | grep -q "feature-689-select-tests.sh"; then
    pass "P4: and it selects the test that matches the change in the approved range"
  else
    fail "P4: the selection does not contain the expected test
--- stdout ---
$sel
--- stderr ---
$serr"
  fi
}
