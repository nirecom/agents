# Part of tests/feature-1638-resolve-merge-base.sh (sourced, not standalone).
# Tests: bin/resolve-merge-base.sh, hooks/workflow-state/merge-base-baseline.js
# Tags: merge-base, baseline, error-handling, degradation, scope:issue-specific, pwsh-not-required, TL2
#
# E — THE RECORDED BASELINE WHEN THE EVIDENCE IS BAD.
#
# R1-R4 cover a well-formed record and the three identity checks that demote it. Every row
# there hands layer 1 a record it can reason about. The rows below hand it the inputs that
# exist in the field instead: no state file at all, a state file that is not JSON, a record
# missing a field the identity checks need, a git command that fails while the checks are
# running, and a null alt_base.
#
# THE ONE RULE THEY ALL SHARE: layer 1 not answering is NORMAL. It is the reason layer 2
# exists. So none of these inputs may crash, none may exit non-zero on a repository where a
# base is available, and none may be adopted anyway. The failure this guards against is not a
# stack trace — it is an implementation that treats a half-read record as good enough, which
# is how a base from another branch becomes the range every gate is scoped by.
#
# The two writer rows (E6/E7) are here rather than with R14-R17 because they are about the
# writer's EVIDENCE — the timestamp comparison that decides post_session_head — and about the
# writer failing without corrupting what was already stored.

# Every row that expects a fall-through asserts the same three things, so the shape is shared:
# layer 2 answered, layer 1 did not, and the output is still the machine-readable contract.
expect_fell_through_to_layer2() { # <row-id>
  local row="$1" st
  st="$(kv state)"
  if [ "$st" = "RECORDED" ]; then
    fail "$row: the bad record was adopted anyway (state=RECORDED)"
  elif [ "$st" = "RESOLVED" ]; then
    pass "$row: layer 1 declined and layer 2 answered"
  else
    fail "$row: expected RESOLVED from layer 2, got state=[$st] rc=$HB_RC"
  fi
  check "$row-rc: and a declined baseline is not an error" "0" "$HB_RC"
  check_match "$row-base: with a real sha on stdout" '^[0-9a-f]{7,40}$' "$(kv base)"
}

e1_absent_state_file() {
  local repo
  repo="$(repo_with_main)"
  HELPER_ENV=()
  # A session id that has never been written. This is every session before branching.
  run_helper "$repo" "sid-e1-never-existed"
  expect_fell_through_to_layer2 "E1"
}

e2_corrupt_state_file() {
  local repo sid="sid-e2"
  repo="$(repo_with_main)"
  node_state init "$sid" "$repo" work >/dev/null
  printf '{"session_id": "sid-e2", "merge_base_baseline": {tru' > "$WFDIR/$sid.json"
  HELPER_ENV=()
  run_helper "$repo" "$sid"
  expect_fell_through_to_layer2 "E2"
  # Guarded on there being output at all: "no stack trace" is trivially true of no output, and
  # the row is about what the helper PRINTS, not about it failing to run.
  if [ -z "$HB_OUT" ]; then
    fail "E2-clean: the helper printed nothing, so stdout cannot be shown to be free of parse errors"
  elif printf '%s' "$HB_OUT" | grep -qiE 'SyntaxError|Unexpected token|at Object\.'; then
    fail "E2-clean: a parse error leaked into the machine-readable stdout -- [$HB_OUT]"
  else
    pass "E2-clean: and the parse failure never reaches stdout"
  fi
}

# The identity checks need branch, branch_head and base. A record missing any one of them
# cannot be verified, and "cannot be verified" is the same answer as "failed verification".
e3_missing_required_fields() {
  local repo base head sid
  repo="$(repo_with_main)"
  base="$(git -C "$repo" rev-parse HEAD~1)"
  head="$(git -C "$repo" rev-parse HEAD)"

  sid="sid-e3a"
  put_baseline "$sid" "$repo" \
    "{\"base\":\"$base\",\"branch_head\":\"$head\",\"repo_root\":\"$repo\",\"source\":\"recorded-baseline\"}"
  HELPER_ENV=()
  run_helper "$repo" "$sid"
  expect_fell_through_to_layer2 "E3a-no-branch"

  sid="sid-e3b"
  put_baseline "$sid" "$repo" \
    "{\"base\":\"$base\",\"branch\":\"work\",\"repo_root\":\"$repo\",\"source\":\"recorded-baseline\"}"
  HELPER_ENV=()
  run_helper "$repo" "$sid"
  expect_fell_through_to_layer2 "E3b-no-branch-head"

  sid="sid-e3c"
  put_baseline "$sid" "$repo" \
    "{\"branch\":\"work\",\"branch_head\":\"$head\",\"repo_root\":\"$repo\",\"source\":\"recorded-baseline\"}"
  HELPER_ENV=()
  run_helper "$repo" "$sid"
  expect_fell_through_to_layer2 "E3c-no-base"
}

# A git command that fails or hangs while the identity checks run. The helper wraps its git
# calls, and the question is what it concludes when one of them does not answer: adopting the
# record without verification is the one unacceptable outcome.
#
# The failure is injected with a `git` shim that refuses exactly `merge-base` — the subcommand
# both ancestry checks use — and delegates everything else to the real binary, so the rest of
# the run is unaffected and the row is about the check rather than about a broken repository.
e4_git_failure_during_verification() {
  local repo base head sid="sid-e4" shim real_git st
  repo="$(repo_with_main)"
  base="$(git -C "$repo" rev-parse HEAD~1)"
  head="$(git -C "$repo" rev-parse HEAD)"
  put_baseline "$sid" "$repo" \
    "{\"base\":\"$base\",\"branch\":\"work\",\"branch_head\":\"$head\",\"repo_root\":\"$repo\",\"source\":\"recorded-baseline\",\"post_session_head\":false,\"alt_base\":null}"

  real_git="$(command -v git)"
  shim="$(mktemp -d "$TMPROOT/gitshim.XXXXXX")"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'REAL=%q\n' "$real_git"
    cat <<'SHIM'
for a in "$@"; do
  if [ "$a" = "merge-base" ]; then
    echo "fatal: injected merge-base failure" >&2
    exit 128
  fi
done
exec "$REAL" "$@"
SHIM
  } > "$shim/git"
  chmod +x "$shim/git" 2>/dev/null || true
  if "$shim/git" merge-base HEAD HEAD >/dev/null 2>&1; then
    skip_case "E4 (this host ignores the execute bit, so the git shim cannot be installed)"
    return
  fi

  HELPER_ENV=("PATH=$shim:$PATH")
  run_helper "$repo" "$sid"
  st="$(kv state)"
  if [ -z "$st" ]; then
    # No state at all is not "correctly declined" — it is the helper never answering.
    fail "E4: the helper reported no state, so declining cannot be distinguished from crashing"
  elif [ "$st" = "RECORDED" ]; then
    fail "E4: the record was adopted although its ancestry could not be verified"
  else
    pass "E4: an unverifiable record is not adopted (state=$st)"
  fi
  check_match "E4-contract: and stdout is still the kv contract rather than a crash" \
    '^[A-Z-]+$' "$st"
  if [ "$HB_RC" = "0" ] || [ "$HB_RC" = "3" ]; then
    pass "E4-rc: exiting with a documented code (rc=$HB_RC), not a shell error"
  else
    fail "E4-rc: undocumented exit code $HB_RC -- stderr [$HB_ERR]"
  fi
}

# alt_base is null whenever there is no alternative to offer, which is the ordinary case. The
# kv format has no null: the absent marker is `-`, and printing the string `null` (or the empty
# string, or `undefined`) hands every consumer a value it will try to use as a revision.
e5_null_alt_base_is_the_absent_marker() {
  local repo base head sid="sid-e5" got
  repo="$(repo_with_main)"
  base="$(git -C "$repo" rev-parse HEAD~1)"
  head="$(git -C "$repo" rev-parse HEAD)"
  put_baseline "$sid" "$repo" \
    "{\"base\":\"$base\",\"branch\":\"work\",\"branch_head\":\"$head\",\"repo_root\":\"$repo\",\"source\":\"recorded-baseline\",\"post_session_head\":false,\"alt_base\":null}"
  HELPER_ENV=()
  run_helper "$repo" "$sid"
  got="$(kv alt_base)"
  check "E5: a null alt_base is reported as the absent marker" "-" "$got"
  check "E5-warn: and with no alternative there is nothing to warn about" "none" "$(kv warn)"
}

# post_session_head on both sides of the boundary it is derived from. The writer compares the
# session's start with the commit time of the HEAD it is recording: a HEAD committed BEFORE the
# session started is the branch point (no note owed), one committed AFTER it means the session
# has already moved on and the recorded base is behind the current HEAD (note owed).
#
# The fixture controls the SESSION side, not the commit side: state.created_at is an input the
# state driver takes, so both sides of the boundary are reachable without waiting on a clock.
e6_post_session_head_boundary() {
  local repo sid
  repo="$(repo_with_main)"

  sid="sid-e6-before"
  node_state init "$sid" "$repo" work "2099-01-01T00:00:00.000Z" >/dev/null
  node_state record "$sid" "$repo" >/dev/null
  check "E6-before: a HEAD committed before the session started owes no note" "false" \
    "$(env "AGENTS_DIR=$AGENTS_DIR" "CLAUDE_WORKFLOW_DIR=$WFDIR" node "$STATE_JS" field "$sid" post_session_head 2>/dev/null)"

  sid="sid-e6-after"
  node_state init "$sid" "$repo" work "1990-01-01T00:00:00.000Z" >/dev/null
  node_state record "$sid" "$repo" >/dev/null
  check "E6-after: a HEAD committed after it does" "true" \
    "$(env "AGENTS_DIR=$AGENTS_DIR" "CLAUDE_WORKFLOW_DIR=$WFDIR" node "$STATE_JS" field "$sid" post_session_head 2>/dev/null)"
}

# A write that cannot complete must leave what was already stored intact. A baseline is read by
# every subsequent gate invocation; a half-written or emptied record is worse than the old one,
# because layer 1 would then adopt whatever survived.
e7_write_failure_leaves_state_intact() {
  local repo before after sid="sid-e7"
  repo="$(repo_with_main)"
  node_state init "$sid" "$repo" work >/dev/null
  node_state record "$sid" "$repo" >/dev/null
  before="$(cat "$WFDIR/$sid.json")"
  if [ -z "$before" ]; then
    fail "E7: nothing was recorded, so a failed write cannot be shown to preserve it"
    return
  fi

  chmod a-w "$WFDIR/$sid.json" 2>/dev/null || true
  # The redirection is placed after 2>/dev/null so that bash's own "Permission denied" for the
  # failed redirect is suppressed too — the probe is expected to fail and must be quiet.
  if [ -w "$WFDIR/$sid.json" ] || printf 'probe\n' 2>/dev/null >> "$WFDIR/$sid.json"; then
    # Git Bash on a mount with no POSIX permissions, and root everywhere, ignore `chmod a-w`.
    # The row would then be asserting the ordinary approve path under a misleading name.
    printf '%s' "$before" > "$WFDIR/$sid.json"
    chmod u+w "$WFDIR/$sid.json" 2>/dev/null || true
    skip_case "E7 (this host ignores chmod a-w, so a write failure cannot be induced)"
    return
  fi

  local log out
  log="$(mktemp "$TMPROOT/e7.XXXXXX")"
  node_state approve "$sid" "$repo" "$(git -C "$repo" rev-parse HEAD~1)" "row E7" > "$log"
  out="$(cat "$log")"
  rm -f "$log"
  chmod u+w "$WFDIR/$sid.json" 2>/dev/null || true
  # A missing module also exits 1, which would make this row pass with nothing implemented. The
  # exit code only means "the write failed" once the module was actually reachable.
  if printf '%s' "$out" | grep -qE '^ERR:require:|is not a function|undefined'; then
    fail "E7-rc: the writer is not reachable, so a write failure was never reached -- [$out]"
  else
    check "E7-rc: the writer reports the failure rather than claiming success" "1" "$NODE_RC"
  fi
  after="$(cat "$WFDIR/$sid.json")"
  check "E7-intact: and the stored baseline is byte-for-byte what it was" "$before" "$after"
}
