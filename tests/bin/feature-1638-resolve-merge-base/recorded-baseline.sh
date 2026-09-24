# ============================================================================
# Layer 1 — the recorded baseline, and the three checks that must demote it
# ============================================================================

r1_recorded_is_adopted() {
  local repo base head sid="sid-r1"
  repo="$(repo_with_main)"
  base="$(git -C "$repo" rev-parse HEAD~1)"
  head="$(git -C "$repo" rev-parse HEAD)"
  put_baseline "$sid" "$repo" \
    "{\"base\":\"$base\",\"branch\":\"work\",\"branch_head\":\"$head\",\"repo_root\":\"$repo\",\"source\":\"recorded-baseline\",\"post_session_head\":false,\"alt_base\":null}"
  HELPER_ENV=()
  run_helper "$repo" "$sid"
  check "R1-state: a matching recorded baseline is adopted" "RECORDED" "$(kv state)"
  check "R1-base: and the base is the recorded value" "$base" "$(kv base)"
  check "R1-source: reported as recorded-baseline" "recorded-baseline" "$(kv source)"
}

r2_branch_mismatch_demotes() {
  local repo base head sid="sid-r2"
  repo="$(repo_with_main)"
  base="$(git -C "$repo" rev-parse HEAD~1)"
  head="$(git -C "$repo" rev-parse HEAD)"
  put_baseline "$sid" "$repo" \
    "{\"base\":\"$base\",\"branch\":\"some-other-branch\",\"branch_head\":\"$head\",\"repo_root\":\"$repo\",\"source\":\"recorded-baseline\",\"post_session_head\":false,\"alt_base\":null}"
  HELPER_ENV=()
  run_helper "$repo" "$sid"
  check "R2-state: a baseline recorded on another branch is ignored" "RESOLVED" "$(kv state)"
  check_match "R2-detail: and the demotion reason names the branch check" "[Bb]ranch" "$(kv detail)"
}

r3_stale_branch_head_demotes() {
  local repo base side sid="sid-r3"
  repo="$(repo_with_main)"
  base="$(git -C "$repo" rev-parse HEAD~1)"
  side="$(side_commit "$repo")"
  put_baseline "$sid" "$repo" \
    "{\"base\":\"$base\",\"branch\":\"work\",\"branch_head\":\"$side\",\"repo_root\":\"$repo\",\"source\":\"recorded-baseline\",\"post_session_head\":false,\"alt_base\":null}"
  HELPER_ENV=()
  run_helper "$repo" "$sid"
  check "R3: a baseline whose branch_head is not an ancestor of HEAD is ignored" "RESOLVED" "$(kv state)"
}

r4_non_ancestor_base_demotes() {
  local repo head side sid="sid-r4"
  repo="$(repo_with_main)"
  head="$(git -C "$repo" rev-parse HEAD)"
  side="$(side_commit "$repo")"
  put_baseline "$sid" "$repo" \
    "{\"base\":\"$side\",\"branch\":\"work\",\"branch_head\":\"$head\",\"repo_root\":\"$repo\",\"source\":\"recorded-baseline\",\"post_session_head\":false,\"alt_base\":null}"
  HELPER_ENV=()
  run_helper "$repo" "$sid"
  check "R4: a baseline whose base is not an ancestor of HEAD is ignored" "RESOLVED" "$(kv state)"
}

