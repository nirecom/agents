# shellcheck shell=bash
# tests/bin/feature-2956-baseline-compare-cli/rename-reuse.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, rename, ledger, scope:issue-specific, pwsh-not-required, TL2
# #3015: the ledger row a renamed test's base run writes is keyed on the path the base ran (the old
# path), so the ledger stage must look it up there. A second run on the same cache then reuses the
# row instead of running the old path at base again, and the detail keeps `-via-rename:<old>`.
# TL3 gap: only a committed rename on a single-test session is exercised.
# Sourced by feature-2956-baseline-compare-cli-missing.sh after _lib.sh; never run standalone.

# rr_body <marker> — touches the marker and exits 1; the shared lines make rename detection kick in.
rr_body() {
  printf '#!/usr/bin/env bash\n# fixture test for #3015 rename lookup\n# line a\n# line b\n# line c\n# line d\n'
  printf 'touch "%s"\nexit 1\n' "$1"
}

# rr_build <repo> — main carries tests/bin/old-t.sh; feature renames it to tests/bin/new-t.sh.
rr_build() {
  local repo="$1"
  mk_fixture_repo "$repo" >/dev/null || return 1
  git -C "$repo" checkout -q main
  rr_body "$RR_MARKS/old-at-base" >"$repo/tests/bin/old-t.sh"; chmod +x "$repo/tests/bin/old-t.sh"
  git -C "$repo" add -A; git -C "$repo" commit -q -m "rename base"
  git -C "$repo" checkout -q feature
  git -C "$repo" merge -q --no-edit main
  git -C "$repo" mv tests/bin/old-t.sh tests/bin/new-t.sh
  rr_body "$RR_MARKS/new-on-branch" >"$repo/tests/bin/new-t.sh"
  git -C "$repo" add -A; git -C "$repo" commit -q -m "rename branch"
}

run_compare_cli_rename_reuse_cases() {
  local repo="$TMPROOT/repo-rr" cache t="tests/bin/new-t.sh"
  RR_MARKS="$TMPROOT/marks-rr"; mkdir -p "$RR_MARKS"
  cache="$(cli_case_cache rr)"
  rr_build "$repo" || fail "fixture: rename-reuse repo not built"
  seed_failing "rr1-$$" "$t"
  rtb_cli_run "$cache" "$repo" "rr1-$$" --per-test-timeout 20
  if [ -f "$RR_MARKS/old-at-base" ]; then pass "run 1: the old path ran at base"
  else fail "run 1: the old path did not run at base; rc=$RTB_CLI_RC ($(cli_baseline_lines))"; fi
  cmp_expect "run 1: the detail names the old path" ".*-via-rename:tests/bin/old-t\.sh"
  rm -f "$RR_MARKS/old-at-base" "$RR_MARKS/new-on-branch"
  seed_failing "rr2-$$" "$t"
  rtb_cli_run "$cache" "$repo" "rr2-$$" --per-test-timeout 20
  if [ -f "$RR_MARKS/old-at-base" ]; then
    fail "run 2: the old path ran at base again despite its ledger row; ($(cli_baseline_lines))"
  else pass "run 2: the ledger row on the old path is reused (the base does not run again)"; fi
  cmp_expect "run 2: the reused verdict keeps the via-rename detail" \
    "file-verdict-preexisting tests/bin/new-t\.sh test-file-changed-via-rename:tests/bin/old-t\.sh"
}
