#!/usr/bin/env bash
# tests/hooks/feature-2631-precommit-size-gate/cases-merge.sh — #2631 stage 9 body of
# tests/hooks/feature-2631-precommit-size-gate.sh (run by lane.sh): the real hooks/pre-commit,
# during an uncommitted merge, passes a HARD+1 file staged equal to MERGE_HEAD and blocks one that
# differs from it. Two pre-commit runs, so the case has a lane of its own.
# Sourced after fixture.sh (new_cfg, run_pc, expect_pass, expect_block) and
# tests/lib/size-merge-fixture.sh (smf_start_merge, smf_grow, smf_hard).

merge_case_incoming_equal_passes_differing_blocks() {
  local cfg hard
  cfg="$(new_cfg)"
  hard="$(smf_hard code)"
  if ! smf_start_merge "$cfg" "src/big.js=$((hard + 1))"; then fail "fixture: merge in the install repo" "smf_start_merge failed"; return; fi
  if git -C "$cfg" diff --cached --name-only | grep -qx 'src/big.js'; then pass "premise: the merge stages src/big.js ($((hard + 1)) lines)"
  else fail "premise: the merge stages src/big.js" "$(git -C "$cfg" status --short | head -c 300)"; fi
  run_pc "$cfg" "$cfg"
  expect_pass "pre-commit: a HARD+1 src/big.js staged equal to MERGE_HEAD passes"
  smf_grow "$cfg" src/big.js
  run_pc "$cfg" "$cfg"
  expect_block "pre-commit: src/big.js differing from MERGE_HEAD by one line blocks" src/big.js
}
