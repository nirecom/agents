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
    branch warn alt_base detail base_is_head uncommitted_lines uncommitted_files untracked_files; do
    printf '%s\n' "$HB_OUT" | grep -qE "^$k=" || missing="$missing $k"
  done
  check "R13: every field a consumer parses is present in the kv output" "" "$missing"
  check "R13-safe: safe_base names the uncommitted-only range" "HEAD" "$(kv safe_base)"
}

# ============================================================================
# #1779 — the zero-commit branch
#
# A branch cut from main with nothing committed yet resolves to a base that IS HEAD. The base
# is correct; the range it implies is empty. The rows below pin the reporting of that fact
# (R20/R21) and the working-tree census the consumers fall back to (R22/R23) — not a new state,
# because RESOLVED is exactly what happened and a new state value would break every consumer's
# case statement for a condition that is not a resolution failure.
# ============================================================================

r20_base_is_head_false_when_ahead() {
  local repo
  repo="$(repo_with_main)"
  HELPER_ENV=()
  run_helper "$repo" -
  # The negative case is its own row: a field that only ever reads `true` is indistinguishable
  # from a field hardcoded to `true`, and every ordinary branch depends on the false answer.
  check "R20: a branch with commits of its own reports base_is_head=false" "false" "$(kv base_is_head)"
}

r21_base_is_head_true_on_zero_commit() {
  local repo head base
  repo="$(repo_zero_commit)"
  HELPER_ENV=()
  run_helper "$repo" -
  head="$(git -C "$repo" rev-parse HEAD)"
  base="$(kv base)"
  # Fixture premise first: if the fixture ever stopped producing base == HEAD, both assertions
  # below would be testing an ordinary branch under a misleading name.
  check "R21-fixture: the zero-commit fixture really resolves base to HEAD" "$head" "$base"
  check "R21-flag: and the resolver reports it" "true" "$(kv base_is_head)"
  # NOT a new state. base==HEAD is a successful resolution of a branch that has not committed,
  # so anything that switches on state must keep seeing RESOLVED.
  check "R21-state: base==HEAD is still a RESOLVED base, not a new state" "RESOLVED" "$(kv state)"
  check "R21-rc: and it is not an error" "0" "$HB_RC"
}

r22_uncommitted_counts_match_git() {
  local repo want_lines want_files
  repo="$(repo_zero_commit)"
  printf 'changed line\n' >> "$repo/seed.txt"
  printf 'another changed line\n' >> "$repo/second.txt"
  # Expectations come from git, not from a constant: a hardcoded number would keep passing
  # after the fixture changed and stop describing anything real.
  want_files="$(git -C "$repo" diff --numstat HEAD | grep -c . || true)"
  want_lines="$(git -C "$repo" diff --numstat HEAD | awk '{ n += $1 + $2 } END { print n + 0 }')"
  HELPER_ENV=()
  run_helper "$repo" -
  if [ "$want_files" -lt 1 ] || [ "$want_lines" -lt 1 ]; then
    fail "R22-fixture: the fixture produced no tracked modification (files=$want_files lines=$want_lines)"
    return
  fi
  check "R22-files: uncommitted_files counts the tracked files git diff HEAD reports" \
    "$want_files" "$(kv uncommitted_files)"
  check "R22-lines: uncommitted_lines matches git diff --numstat HEAD" \
    "$want_lines" "$(kv uncommitted_lines)"
}

r23_untracked_is_counted_separately() {
  local repo tracked_files
  repo="$(repo_zero_commit)"
  printf 'changed line\n' >> "$repo/seed.txt"
  tracked_files="$(git -C "$repo" diff --numstat HEAD | grep -c . || true)"
  printf 'brand new\n' > "$repo/untracked-new.txt"
  HELPER_ENV=()
  run_helper "$repo" -
  check "R23-untracked: an untracked file is counted on its own axis" "1" "$(kv untracked_files)"
  # The separation is the point: `git diff HEAD` cannot see an untracked file, so a consumer
  # that only reads uncommitted_files would silently drop brand-new work from the fallback set.
  check "R23-tracked: and it does not inflate the tracked count" \
    "$tracked_files" "$(kv uncommitted_files)"
}

# ---- the counters at their edges ------------------------------------------
#
# R22/R23 pin the counters where there is something to count. The three rows below pin the
# cases a naive implementation gets wrong in the OTHER direction: nothing to count at all,
# a change that lives only in the index, and more than one of the same kind.

# R24: zero is a real answer and has to be printed as one. `-` means "could not tell", and a
# consumer that saw `-` where the truth is 0 would degrade a branch that has nothing to degrade
# to. The zero-commit fixture is clean by construction, so all three counters must read 0.
r24_clean_tree_counts_are_zero() {
  local repo
  repo="$(repo_zero_commit)"
  # Premise: nothing was written into the fixture. If that ever changed the row would be
  # asserting zeros against a dirty tree and would fail for the wrong reason.
  if [ -n "$(git -C "$repo" status --porcelain)" ]; then
    fail "R24-fixture: the zero-commit fixture is not clean, so 'all counters are zero' is not the case under test"
    return
  fi
  HELPER_ENV=()
  run_helper "$repo" -
  check "R24-lines: a clean tree reports zero uncommitted lines, not '-'" "0" "$(kv uncommitted_lines)"
  check "R24-files: and zero uncommitted files" "0" "$(kv uncommitted_files)"
  check "R24-untracked: and zero untracked files" "0" "$(kv untracked_files)"
  check "R24-state: a clean zero-commit branch is still an ordinary RESOLVED" "RESOLVED" "$(kv state)"
}

# R25: the change is STAGED and nothing else. This is #1779 as reported, and it is the row that
# separates `git diff HEAD` from a bare `git diff`: the latter compares the index to the working
# tree and reports NOTHING here, so an implementation built on it reads a fully-staged branch as
# clean. The empty-`git diff` premise below is what keeps that distinction load-bearing.
r25_staged_only_change_is_counted() {
  local repo want_lines want_files
  repo="$(repo_zero_commit)"
  printf 'staged line\n' >> "$repo/seed.txt"
  git -C "$repo" add seed.txt >/dev/null 2>&1
  if [ -n "$(git -C "$repo" diff --numstat)" ]; then
    fail "R25-fixture: the change is not fully staged, so the row cannot tell 'git diff HEAD' from 'git diff'"
    return
  fi
  want_files="$(git -C "$repo" diff --numstat HEAD | grep -c . || true)"
  want_lines="$(git -C "$repo" diff --numstat HEAD | awk '{ n += $1 + $2 } END { print n + 0 }')"
  if [ "$want_files" -lt 1 ]; then
    fail "R25-fixture: git diff HEAD reports nothing, so the fixture staged nothing"
    return
  fi
  HELPER_ENV=()
  run_helper "$repo" -
  check "R25-files: a staged-only change counts toward uncommitted_files" "$want_files" "$(kv uncommitted_files)"
  check "R25-lines: and toward uncommitted_lines" "$want_lines" "$(kv uncommitted_lines)"
}

# R26: an exact count, not "at least one". A `[ -n ... ]`-style implementation that reports 1 for
# any non-empty listing passes R23 forever; three files is the smallest input that catches it.
r26_untracked_count_is_exact() {
  local repo
  repo="$(repo_zero_commit)"
  printf 'a\n' > "$repo/new-a.txt"
  printf 'b\n' > "$repo/new-b.txt"
  mkdir -p "$repo/nested"
  printf 'c\n' > "$repo/nested/new-c.txt"
  HELPER_ENV=()
  run_helper "$repo" -
  check "R26: three untracked files are counted as three, not as 'some'" "3" "$(kv untracked_files)"
}

# R27: an ignored file is NOT untracked work. `--exclude-standard` is what makes that true, and
# without it a build directory or a local scratch file would inflate the census and, downstream,
# pull whole tiers of tests into the degraded selection. The .gitignore is staged rather than
# committed so the branch stays zero-commit — git reads it from the working tree either way.
r27_gitignored_file_is_not_untracked() {
  local repo
  repo="$(repo_zero_commit)"
  printf 'ignored-*.txt\n' > "$repo/.gitignore"
  git -C "$repo" add .gitignore >/dev/null 2>&1
  printf 'noise\n' > "$repo/ignored-scratch.txt"
  # Premise: git really is ignoring it. A typo in the pattern would make the row pass for the
  # wrong reason, by counting a file that was never ignored in the first place.
  if git -C "$repo" ls-files --others --exclude-standard | grep -q 'ignored-scratch'; then
    fail "R27-fixture: the .gitignore pattern did not take effect, so nothing is being excluded"
    return
  fi
  HELPER_ENV=()
  run_helper "$repo" -
  check "R27: a gitignored file is excluded from the untracked census" "0" "$(kv untracked_files)"
}

