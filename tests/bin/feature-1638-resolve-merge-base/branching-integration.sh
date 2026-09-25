# Part of tests/feature-1638-resolve-merge-base.sh (sourced, not standalone).
# Tests: hooks/workflow-mark/branching-handler.js, hooks/workflow-state/merge-base-baseline.js
# Tags: merge-base, baseline, branching-handler, workflow-mark, integration, scope:issue-specific, pwsh-not-required, TL2
#
# B — the WRITER'S ONLY CALLER, exercised through a real sentinel dispatch.
#
# R14-R17 pin the module contract by calling recordMergeBaseBaseline directly. That leaves the
# single most likely failure untested: the module is correct and nothing ever calls it. There
# is exactly one automatic writer — branching-handler.js on BRANCHING_COMPLETE — so the wiring
# is a cross-module seam (skills/_shared/test-design.md: subprocess boundaries and cross-module
# wiring are mandatory integration triggers), and these rows drive the real hook entrypoint
# with a real JSON payload rather than requiring the handler and calling handle() by hand.
#
# THREE THINGS ARE PINNED, and they fail independently:
#   B1  WHICH REPOSITORY the base is recorded for. The session's state.cwd is the MAIN
#       worktree; the branch point that matters is in the LINKED worktree named by the
#       decision's `worktree:` segment. Recording the main worktree's HEAD would produce a
#       baseline that is a real sha, adopted by layer 1 forever, and wrong — the #1638 shape
#       exactly. The fixture gives the two worktrees DIFFERENT HEADs so the two answers are
#       distinguishable.
#   B2  WRITE-ONCE through the real dispatch. R14 proves the module refuses a second write;
#       this proves a second sentinel (a re-emitted BRANCHING_COMPLETE, which happens) does
#       not route around it.
#   B3  A RECORDING FAILURE IS A WARNING, NEVER FATAL. signalFatal makes workflow-mark exit 2,
#       which aborts the step the user was in the middle of. A merge-base baseline is an
#       optimisation over guessing; losing it must degrade to guessing, not stop the workflow.
#   B4  The main-worktree session — no `worktree:` segment — still gets a baseline, recorded
#       for state.cwd. Without this row an implementation that only handles the linked-worktree
#       case satisfies B1 and silently records nothing for every main-worktree session.

MARK_HOOK="$AGENTS_DIR/hooks/workflow-mark.js"

# node on Git Bash needs forward-slash paths; on POSIX this is the identity.
to_node_path() { # <path>
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

BI_RC=0
BI_OUT=""
BI_ERR=""

# Drives the real hook entrypoint the way Claude Code does: a PostToolUse payload whose
# tool_input.command is the sentinel echo.
dispatch_branching() { # <sid> <decision>
  local sid="$1" decision="$2" cmd payload esc o e
  cmd="echo \"<<WORKFLOW_BRANCHING_COMPLETE: $decision>>\""
  esc="$(printf '%s' "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  payload="$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":0},"session_id":"%s"}' \
    "$esc" "$sid")"
  o="$(mktemp "$TMPROOT/bi-out.XXXXXX")"
  e="$(mktemp "$TMPROOT/bi-err.XXXXXX")"
  BI_RC=0
  printf '%s' "$payload" | env \
    "CLAUDE_WORKFLOW_DIR=$(to_node_path "$WFDIR")" \
    "AGENTS_CONFIG_DIR=$(to_node_path "$AGENTS_DIR")" \
    node "$MARK_HOOK" >"$o" 2>"$e" || BI_RC=$?
  BI_OUT="$(cat "$o")"
  BI_ERR="$(cat "$e")"
  rm -f "$o" "$e"
}

baseline_field() { # <sid> <field>
  env "AGENTS_DIR=$(to_node_path "$AGENTS_DIR")" "CLAUDE_WORKFLOW_DIR=$(to_node_path "$WFDIR")" \
    node "$STATE_JS" field "$1" "$2" 2>/dev/null
}

# A main worktree with its own HEAD plus a linked worktree that is one commit ahead of it, so
# "which repository was measured" is answerable from the recorded sha alone.
repo_with_linked_worktree() { # ; prints "<main-path>|<worktree-path>|<branch>"
  local r wt
  r="$(new_repo main)"
  commit_file "$r" seed.txt 1 seed
  commit_file "$r" second.txt 1 second
  wt="$(mktemp -d "$TMPROOT/wt.XXXXXX")"
  rm -rf "$wt"
  git -C "$r" worktree add -q -b bi-work "$wt" >/dev/null 2>&1
  git -C "$wt" config core.hooksPath "$wt/.git-no-such-hooks" >/dev/null 2>&1
  git -C "$wt" config user.email test@example.com >/dev/null 2>&1
  git -C "$wt" config user.name test >/dev/null 2>&1
  commit_file "$wt" wt-only.txt 3 "work in the linked worktree"
  printf '%s|%s|%s' "$r" "$wt" bi-work
}

b1_records_for_the_resolved_worktree() {
  local trio main wt branch main_head wt_head got sid="sid-b1"
  trio="$(repo_with_linked_worktree)"
  main="${trio%%|*}"; trio="${trio#*|}"
  wt="${trio%%|*}"; branch="${trio#*|}"
  main_head="$(git -C "$main" rev-parse HEAD)"
  wt_head="$(git -C "$wt" rev-parse HEAD)"
  if [ "$main_head" = "$wt_head" ]; then
    fail "B1-fixture: the two worktrees share a HEAD, so the row cannot tell them apart"
    return
  fi
  # The session started in the MAIN worktree — the mid-session /worktree-start shape.
  node_state init "$sid" "$(to_node_path "$main")" main >/dev/null
  dispatch_branching "$sid" "branch:$branch worktree:$(to_node_path "$wt")"

  got="$(baseline_field "$sid" base)"
  check "B1-base: the baseline is recorded for the worktree named by the decision" "$wt_head" "$got"
  # Guarded so the row cannot pass on "nothing was recorded": NONE is also != main_head, and a
  # vacuous pass here is exactly the shape of the bug this row exists to catch.
  if ! printf '%s' "$got" | grep -qE '^[0-9a-f]{40}$'; then
    fail "B1-not-cwd: no sha was recorded ([$got]), so the row cannot show which worktree was measured"
  elif [ "$got" = "$main_head" ]; then
    fail "B1-not-cwd: the base is the MAIN worktree's HEAD -- state.cwd was measured instead of the resolved worktree"
  else
    pass "B1-not-cwd: and NOT the HEAD of the main worktree in state.cwd"
  fi
  check "B1-branch: and the record names the worktree's branch" "$branch" "$(baseline_field "$sid" branch)"
  check "B1-rc: a successful recording is invisible to the caller — no fatal, exit 0" "0" "$BI_RC"
}

b2_second_dispatch_does_not_overwrite() {
  local trio main wt branch first second sid="sid-b2"
  trio="$(repo_with_linked_worktree)"
  main="${trio%%|*}"; trio="${trio#*|}"
  wt="${trio%%|*}"; branch="${trio#*|}"
  node_state init "$sid" "$(to_node_path "$main")" main >/dev/null
  dispatch_branching "$sid" "branch:$branch worktree:$(to_node_path "$wt")"
  first="$(baseline_field "$sid" base)"
  # A new commit changes what a second recording would compute, so an overwrite is visible.
  commit_file "$wt" later.txt 1 "a commit after branching"
  dispatch_branching "$sid" "branch:$branch worktree:$(to_node_path "$wt")"
  second="$(baseline_field "$sid" base)"
  if [ -z "$first" ] || [ "$first" = "NONE" ] || [ "$first" = "undefined" ]; then
    fail "B2: the first dispatch recorded nothing, so a second one cannot be shown to preserve it"
  else
    check "B2: a re-emitted BRANCHING_COMPLETE does not move the recorded base" "$first" "$second"
  fi
}

b3_recording_failure_is_not_fatal() {
  local main notrepo sid="sid-b3"
  main="$(new_repo main)"
  commit_file "$main" seed.txt 1 seed
  # An existing directory that is NOT a git repository: every git command the writer needs
  # fails there, which is the recording failure without breaking anything else.
  notrepo="$(mktemp -d "$TMPROOT/notrepo.XXXXXX")"
  node_state init "$sid" "$(to_node_path "$main")" main >/dev/null
  dispatch_branching "$sid" "branch:bi-work worktree:$(to_node_path "$notrepo")"

  if [ "$BI_RC" = "2" ]; then
    fail "B3-rc: workflow-mark exited 2 -- a failed baseline recording called signalFatal and aborted the step"
  else
    pass "B3-rc: a failed baseline recording does not abort workflow-mark (exit $BI_RC, not 2)"
  fi
  # The step itself must still be recorded: the baseline is an optimisation, branching_complete
  # is the fact the workflow depends on.
  check "B3-step: and branching_complete is still marked" "complete" \
    "$(env "AGENTS_DIR=$(to_node_path "$AGENTS_DIR")" "CLAUDE_WORKFLOW_DIR=$(to_node_path "$WFDIR")" \
      node -e 'const path=require("path");let ws;try{ws=require(path.join(process.env.AGENTS_DIR,"hooks","workflow-state"));const st=ws.readState("'"$sid"'");process.stdout.write(String(st.steps.branching_complete.status));}catch(e){process.stdout.write("READ_ERROR");}' 2>/dev/null)"
  # And the failure is not silent. Whichever stream workflow-mark uses, the reason has to be
  # somewhere a reader can find it.
  if printf '%s\n%s\n' "$BI_OUT" "$BI_ERR" | grep -qiE "merge.?base|baseline"; then
    pass "B3-warn: the failure is reported as a warning rather than swallowed"
  else
    fail "B3-warn: nothing on stdout or stderr mentions the failed baseline
--- stdout ---
$BI_OUT
--- stderr ---
$BI_ERR"
  fi
}

b4_main_worktree_session_still_records() {
  local repo head sid="sid-b4"
  repo="$(repo_with_main)"
  head="$(git -C "$repo" rev-parse HEAD)"
  node_state init "$sid" "$(to_node_path "$repo")" work >/dev/null
  # No `worktree:` segment — the session works directly in the repository at state.cwd.
  dispatch_branching "$sid" "main: trivial change, no worktree"
  check "B4: a decision with no worktree segment records the baseline for state.cwd" \
    "$head" "$(baseline_field "$sid" base)"
}
