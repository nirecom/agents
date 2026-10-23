#!/usr/bin/env bash
# tests/hooks/feature-2631-precommit-size-gate/cases-edges.sh — the size gate's edge bodies of
# tests/hooks/feature-2631-precommit-size-gate.sh (the case markers stay in the entry file).
# Sourced by lane.sh after fixture.sh. A WORKFLOW_OFF or stateless sid passes, WORKTREE_OFF and an
# unresolved sid are checked, a foreign repo is untouched, bin/size-check rc 2 / rc 3 block (fail
# closed), a newline-named path is judged, and an agents repo's first commit (no HEAD) is judged.

# edge_put_state <sid> — the workflow state file that makes <sid> a known workflow session.
edge_put_state() { printf '{"session_id":"%s","events":[]}\n' "$1" > "$WORKFLOW_STATE_DIR/$1.json"; }

edge_case_session_markers_and_unresolved_sid() {
  local cfg
  edge_put_state sess-2631-workflow-off
  : > "$WORKFLOW_STATE_DIR/sess-2631-workflow-off.workflow-off"
  cfg="$(new_cfg)"
  stage "$cfg" src/new.js 501
  run_pc "$cfg" "$cfg" CLAUDE_CODE_SESSION_ID=sess-2631-workflow-off
  expect_pass "known sid with a .workflow-off marker: HARD+1 passes"
  # WORKTREE_OFF lifts the worktree isolation only; it exempts no size check.
  edge_put_state sess-2631-worktree-off
  : > "$WORKFLOW_STATE_DIR/sess-2631-worktree-off.worktree-off"
  cfg="$(new_cfg)"
  stage "$cfg" src/new.js 501
  run_pc "$cfg" "$cfg" CLAUDE_CODE_SESSION_ID=sess-2631-worktree-off
  expect_block "known sid with a .worktree-off marker: HARD+1 still blocks" src/new.js
  cfg="$(new_cfg)"
  stage "$cfg" src/new.js 501
  run_pc "$cfg" "$cfg" CLAUDE_CODE_SESSION_ID=sess-2631-no-state
  expect_pass "sid with no workflow state: HARD+1 passes"
  edge_put_state sess-2631-plain
  cfg="$(new_cfg)"
  stage "$cfg" src/new.js 501
  run_pc "$cfg" "$cfg" CLAUDE_CODE_SESSION_ID=sess-2631-plain
  expect_block "control: known sid with state and no marker: HARD+1 blocks" src/new.js
  cfg="$(new_cfg)"
  stage "$cfg" src/new.js 501
  run_pc "$cfg" "$cfg"
  expect_block "unresolved sid (no CLAUDE_CODE_SESSION_ID): HARD+1 is still checked and blocks" src/new.js
}

edge_case_non_agents_repo_is_a_no_op() {
  local plain="$TMP_ROOT/plain"
  init_repo "$plain"
  echo init > "$plain/README.md"
  git -C "$plain" add README.md
  git -C "$plain" commit -q -m init
  git -C "$plain" remote add origin "$NON_GITHUB"
  stage "$plain" src/new.js 501
  run_pc "$plain" "$(new_cfg)"
  expect_pass "a foreign repo routed through the agents hook: HARD+1 passes"
  if printf '%s\n%s\n' "$OUT" "$ERR" | grep -q HARD; then fail "a foreign repo gets no size verdict output" "$OUT $ERR"
  else pass "a foreign repo gets no size verdict output"; fi
}

edge_case_size_check_rc2_and_rc3_block() {
  local cfg
  cfg="$(new_cfg 2)"
  stage "$cfg" src/small.js 10
  run_pc "$cfg" "$cfg"
  if [ "$RC" = 1 ] && printf '%s\n%s\n' "$OUT" "$ERR" | grep -q size-check; then pass "size-check rc 2 (usage error) blocks the commit, naming size-check"
  else fail "size-check rc 2 (usage error) blocks the commit, naming size-check" "rc=$RC out=$OUT err=$ERR"; fi
  cfg="$(new_cfg 3)"
  stage "$cfg" src/small.js 10
  run_pc "$cfg" "$cfg"
  if [ "$RC" = 1 ]; then pass "size-check rc 3 (infrastructure error) blocks the commit (fail closed)"
  else fail "size-check rc 3 (infrastructure error) blocks the commit (fail closed)" "rc=$RC out=$OUT err=$ERR"; fi
  if printf '%s\n' "$ERR" | grep -F size-check | grep -F 'rc=3' | grep -q 'Commit blocked'; then pass "size-check rc 3: stderr says the commit is blocked, naming size-check rc=3"
  else fail "size-check rc 3: stderr says the commit is blocked, naming size-check rc=3" "err=$ERR"; fi
}

# A newline in a name rides neither the line-based records nor a Windows file system: staged
# through the index alone, it must still be read and judged, never skipped.
EDGE_NL_PATH=$'src/new\nline.js'

edge_case_newline_path() {
  local cfg
  cfg="$(new_cfg)"
  if stage_blob "$cfg" "$EDGE_NL_PATH" 501; then pass "premise: a 501-line path holding a newline is staged"
  else fail "premise: a 501-line path holding a newline is staged"; fi
  run_pc "$cfg" "$cfg"
  if [ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -q 'exceed the HARD size limit'; then pass "a staged 501-line newline path blocks the commit by its HARD verdict"
  else fail "a staged 501-line newline path blocks the commit by its HARD verdict" "rc=$RC out=$OUT err=$ERR"; fi
  unstage_blob "$cfg" "$EDGE_NL_PATH"
  cfg="$(new_cfg)"
  stage_blob "$cfg" "$EDGE_NL_PATH" 10
  run_pc "$cfg" "$cfg"
  expect_pass "control: the same newline path at 10 lines passes (read, not refused)"
  unstage_blob "$cfg" "$EDGE_NL_PATH"
}

# The first commit of an agents repo: bin/size-check takes its no-HEAD branch (every file is new).
edge_case_initial_commit() {
  local cfg
  cfg="$(new_nohead_cfg)"
  if git -C "$cfg" rev-parse -q --verify HEAD >/dev/null 2>&1; then fail "premise: the fresh install has no HEAD" "HEAD resolves"
  else pass "premise: the fresh install has no HEAD"; fi
  stage "$cfg" src/small.js 10
  stage "$cfg" src/new.js 501
  run_pc "$cfg" "$cfg"
  expect_block "initial commit: a new 501-line src/new.js blocks" src/new.js
  if printf '%s\n%s\n' "$OUT" "$ERR" | grep -F src/small.js | grep -q HARD; then fail "initial commit: no HARD verdict names the 10-line src/small.js" "out=$OUT err=$ERR"
  else pass "initial commit: no HARD verdict names the 10-line src/small.js"; fi
  cfg="$(new_nohead_cfg)"
  stage "$cfg" src/small.js 10
  stage "$cfg" src/new.js 500
  run_pc "$cfg" "$cfg"
  expect_pass "initial commit: a new src/new.js at exactly HARD (500) passes"
}
