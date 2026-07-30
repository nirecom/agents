# ============================================================================
# Layer 2 — RESOLVED / FALLBACK / UNRESOLVED
# ============================================================================

r5_resolved_against_main() {
  local repo want
  repo="$(repo_with_main)"
  want="$(git -C "$repo" merge-base main HEAD)"
  HELPER_ENV=()
  run_helper "$repo" -
  check "R5-state: no record + a local main resolves normally" "RESOLVED" "$(kv state)"
  check "R5-base: and the base is the merge-base against main" "$want" "$(kv base)"
  check_match "R5-lines: the anomaly detector ran, so diff_lines is an integer" '^[0-9]+$' "$(kv diff_lines)"
  check_match "R5-files: and so is diff_files" '^[0-9]+$' "$(kv diff_files)"
}

r6_fallback_to_head_parent() {
  local repo
  repo="$(repo_no_main)"
  HELPER_ENV=()
  run_helper "$repo" -
  check "R6-state: no main and no remote degrades to HEAD~1" "FALLBACK" "$(kv state)"
  check "R6-rc: degradation is not an error — exit stays 0" "0" "$HB_RC"
  if git -C "$repo" rev-parse --verify --quiet "$(kv base)^{commit}" >/dev/null 2>&1; then
    pass "R6-real: the fallback base is a revision that exists"
  else
    fail "R6-real: the fallback base does not resolve -- base=[$(kv base)]"
  fi
}

r7_unresolved_on_root_commit() {
  local repo
  repo="$(repo_root_only)"
  HELPER_ENV=()
  run_helper "$repo" -
  check "R7-state: a root-commit repo has no usable base" "UNRESOLVED" "$(kv state)"
  check "R7-base: and base is empty rather than a revision that does not exist" "" "$(kv base)"
  check "R7-rc: UNRESOLVED is the one state that exits non-zero" "3" "$HB_RC"
}

# ============================================================================
# Anomaly detection — two independent axes, and the layer-1 asymmetry
# ============================================================================

r8_suspect_on_line_threshold() {
  local repo
  repo="$(repo_with_main)"
  HELPER_ENV=(MERGE_BASE_MAX_DIFF_LINES=1 MERGE_BASE_MAX_DIFF_FILES=500)
  run_helper "$repo" -
  check "R8-state: a diff over the line threshold is SUSPECT" "SUSPECT" "$(kv state)"
  check "R8-rc: SUSPECT still exits 0 — the helper reports, it does not decide" "0" "$HB_RC"
}

r9_suspect_on_file_threshold() {
  local repo
  repo="$(repo_with_main)"
  HELPER_ENV=(MERGE_BASE_MAX_DIFF_LINES=1000000 MERGE_BASE_MAX_DIFF_FILES=0)
  run_helper "$repo" -
  check "R9: the file-count axis triggers SUSPECT independently of the line axis" \
    "SUSPECT" "$(kv state)"
}

r10_recorded_is_exempt_from_thresholds() {
  local repo base head sid="sid-r10"
  repo="$(repo_with_main)"
  base="$(git -C "$repo" rev-parse HEAD~1)"
  head="$(git -C "$repo" rev-parse HEAD)"
  put_baseline "$sid" "$repo" \
    "{\"base\":\"$base\",\"branch\":\"work\",\"branch_head\":\"$head\",\"repo_root\":\"$repo\",\"source\":\"recorded-baseline\",\"post_session_head\":false,\"alt_base\":null}"
  HELPER_ENV=(MERGE_BASE_MAX_DIFF_LINES=1 MERGE_BASE_MAX_DIFF_FILES=0)
  run_helper "$repo" "$sid"
  check "R10: the threshold check never runs on a recorded baseline" "RECORDED" "$(kv state)"
}

r11_post_session_head_is_a_note() {
  local repo base head alt sid="sid-r11"
  repo="$(repo_with_main)"
  base="$(git -C "$repo" rev-parse HEAD~1)"
  head="$(git -C "$repo" rev-parse HEAD)"
  alt="$(git -C "$repo" merge-base main HEAD)"
  put_baseline "$sid" "$repo" \
    "{\"base\":\"$base\",\"branch\":\"work\",\"branch_head\":\"$head\",\"repo_root\":\"$repo\",\"source\":\"recorded-baseline\",\"post_session_head\":true,\"alt_base\":\"$alt\"}"
  HELPER_ENV=(MERGE_BASE_MAX_DIFF_LINES=1 MERGE_BASE_MAX_DIFF_FILES=0)
  run_helper "$repo" "$sid"
  check "R11-state: post_session_head does not demote the record" "RECORDED" "$(kv state)"
  check "R11-warn: it surfaces as a warn field instead" "post-session-head" "$(kv warn)"
  check_match "R11-alt: and the alternative base is carried through as a sha" \
    '^[0-9a-f]{40}$' "$(kv alt_base)"
}

# ============================================================================
# Output contracts
# ============================================================================

r12_format_base() {
  local repo kvbase out lines
  repo="$(repo_with_main)"
  HELPER_ENV=()
  run_helper "$repo" -
  kvbase="$(kv base)"
  run_helper "$repo" - --format base
  out="$HB_OUT"
  lines="$(printf '%s\n' "$out" | grep -c . || true)"
  # Comparing two empty strings would pass forever, so the non-empty premise is its own row.
  if [ -n "$kvbase" ]; then
    check "R12-value: --format base prints the same base the kv form reports" "$kvbase" "$out"
  else
    fail "R12-value: the kv form produced no base to compare against"
  fi
  check "R12-shape: and nothing else" "1" "$lines"
}

r13_all_kv_keys_present() {
  local repo k missing=""
  repo="$(repo_with_main)"
  HELPER_ENV=()
  run_helper "$repo" -
  for k in base state source safe_base diff_lines diff_files threshold_lines threshold_files \
    branch warn alt_base detail; do
    printf '%s\n' "$HB_OUT" | grep -qE "^$k=" || missing="$missing $k"
  done
  check "R13: every field a consumer parses is present in the kv output" "" "$missing"
  check "R13-safe: safe_base names the uncommitted-only range" "HEAD" "$(kv safe_base)"
}

