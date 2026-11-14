# shellcheck shell=bash
# tests/bin/feature-2956-baseline-compare-cli/timeout-cache.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, cli, compare, timeout, scope:issue-specific, pwsh-not-required, TL2
# #3015: a cached branch timeout (`timeout-after-<N>s`) is a cache hit — the branch copy is not
# re-run, and the comparison treats the branch side as having no case records.
# Sourced by feature-2956-baseline-compare-cli.sh after _lib.sh; never run standalone.

# tc_body <side> — exits 1 with no case records and leaves a <side> marker, so a run is observable.
tc_body() { printf '#!/usr/bin/env bash\ntouch "%s/%s"\nexit 1\n' "$TC_MARKS" "$1"; }

# tc_build <repo> — main and feature each carry tests/bin/t-tmo.sh, each touching its own marker.
tc_build() {
  local repo="$1"
  mk_fixture_repo "$repo" >/dev/null || return 1
  git -C "$repo" checkout -q main
  tc_body base >"$repo/tests/bin/t-tmo.sh"; chmod +x "$repo/tests/bin/t-tmo.sh"
  git -C "$repo" add -A; git -C "$repo" commit -q -m "timeout base"
  git -C "$repo" checkout -q feature
  git -C "$repo" merge -q --no-edit main
  tc_body branch >"$repo/tests/bin/t-tmo.sh"
  git -C "$repo" add -A; git -C "$repo" commit -q -m "timeout branch"
}

# tc_rewrite_row <cache> <rel> <result> — the branch cache row for <rel> gets <result> and fp `-`,
# written raw: the put path is what the case does not trust.
tc_rewrite_row() {
  local seg n=0
  for seg in "$1"/branch.v2.*.seg; do
    [ -f "$seg" ] || continue
    awk -F'\t' -v OFS='\t' -v rel="$2" -v res="$3" '$4 == rel { $5 = res; $6 = "-" } { print }' "$seg" >"$seg.tmp" \
      && mv "$seg.tmp" "$seg" && n=$((n + 1))
  done
  [ "$n" -gt 0 ] && grep -qs "	$3	" "$1"/branch.v2.*.seg
}

run_compare_cli_timeout_cache_cases() {
  local repo="$TMPROOT/repo-tmo" cache t="tests/bin/t-tmo.sh"
  TC_MARKS="$TMPROOT/marks-tmo"; mkdir -p "$TC_MARKS"
  cache="$(cli_case_cache tmo)"
  tc_build "$repo" || fail "fixture: timeout-cache repo not built"
  seed_failing "tmo1-$$" "$t"
  rtb_cli_run "$cache" "$repo" "tmo1-$$" --per-test-timeout 20
  if [ -f "$TC_MARKS/branch" ] && tc_rewrite_row "$cache" "$t" "timeout-after-300s"; then
    pass "setup: run 1 ran the branch copy and its cache row now reads timeout-after-300s"
  else
    fail "setup: no branch cache row to rewrite for $t; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
  rm -f "$TC_MARKS/base" "$TC_MARKS/branch"
  rm -rf "$cache/baseline"
  seed_failing "tmo2-$$" "$t"
  rtb_cli_run "$cache" "$repo" "tmo2-$$" --per-test-timeout 20
  if [ ! -f "$TC_MARKS/branch" ]; then pass "a cached timeout-after-300s row is a hit: the branch copy did not run"
  else fail "the branch copy ran again despite a cached timeout-after-300s row"; fi
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qF "run-tests-baseline: branch re-run: $t"; then
    fail "a 'branch re-run: $t' line was printed on a cache hit"
  else pass "no 'branch re-run' line on the cached timeout"; fi
  if [ -f "$TC_MARKS/base" ]; then pass "the base copy still ran (the ledger was cleared)"
  else fail "the base copy did not run after the ledger was cleared; rc=$RTB_CLI_RC"; fi
  cmp_expect "a cached branch timeout reads as no case records on the branch" \
    "new-case-failure-on-branch tests/bin/t-tmo\.sh case-records-missing-on-branch([[:space:]]|\$)"
}
