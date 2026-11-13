# shellcheck shell=bash
# tests/bin/feature-2431-run-tests-baseline/cli-unsupported.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-exec.sh
# Tags: run-tests, baseline, cli, exec, test-language-registry, scope:issue-specific, pwsh-not-required, TL2
# Sourced by the dispatcher; never run standalone.
# A base launcher that declines (rc 78, RUN_ALL_EXEC_LAUNCHED=0) gives no verdict: undetermined
# unsupported-at-base, recorded in the ledger as `und:unsupported-at-base` (never pass/fail) and
# auto-accepted (#2688). A launched test exiting 78 itself is an ordinary failure.

run_cli_unsupported_at_base_cases() {
  local repo="$TMPROOT/repo-unsup" t_uns="tests/bin/test-unsup.test.ts" t_78="tests/bin/test-exit78.sh"
  local cache base logdir n_uns idx f
  mk_fixture_repo "$repo" >/dev/null
  git -C "$repo" checkout -q main
  # *.test.ts is recognized-only (test-naming-convention; js is supported since #2501), so
  # run_all_exec reports UNSUPPORTED and never runs it.
  printf 'process.exit(1);\n' > "$repo/$t_uns"
  printf '#!/usr/bin/env bash\nexit 78\n' > "$repo/$t_78"
  chmod +x "$repo/$t_78"
  git -C "$repo" add tests/
  git -C "$repo" commit -q -m "unsupported test and exit-78 test at base"
  base="$(git -C "$repo" rev-parse main)"
  git -C "$repo" checkout -q feature
  git -C "$repo" merge -q --no-edit main

  cache="$(cli_case_cache uns)"
  seed_failing "uns-$$" "$t_uns" "$t_78"
  rtb_cli_run "$cache" "$repo" "uns-$$"

  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: undetermined[[:space:]]+$t_uns[[:space:]]+unsupported-at-base\$"; then
    pass "C3-unsupported-at-base: not-launched base test classified undetermined unsupported-at-base"
  else
    fail "C3-unsupported-at-base: expected undetermined unsupported-at-base; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: preexisting[^ ]*[[:space:]]+$t_uns"; then
    fail "C3-unsupported-at-base: $t_uns must not be classified preexisting ($(cli_baseline_lines))"
  else
    pass "C3-unsupported-at-base: $t_uns not classified preexisting"
  fi
  # The exit-78 test writes no case records on either side (#2956 S8 table 1): an ordinary base
  # failure judged at file level, not an unsupported one.
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: file-verdict-preexisting[[:space:]]+$t_78[[:space:]]+no-case-records\$"; then
    pass "C3-exit-78-launched: a launched test exiting 78 is file-verdict-preexisting no-case-records"
  else
    fail "C3-exit-78-launched: expected file-verdict-preexisting no-case-records; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qxF "$(baseline_summary 0 0 0 1 1 0)" \
    && [ "$RTB_CLI_RC" -eq 0 ]; then
    pass "C3-unsupported-at-base: summary undetermined=1 file_verdict=1 and exit 0 (auto + auto)"
  else
    fail "C3-unsupported-at-base: summary/exit mismatch; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi

  # Ledger: the unsupported test is recorded only as undetermined, never as a pass/fail verdict.
  local got_uns got_78
  # v3 (#2956 S7) may print the fingerprint after the result; only the result token is compared.
  got_uns="$(ledger_call "$cache" "$repo" rtb_ledger_lookup_same_base "$base" "$t_uns" 2>/dev/null)"
  got_78="$(ledger_call "$cache" "$repo" rtb_ledger_lookup_same_base "$base" "$t_78" 2>/dev/null)"
  got_uns="${got_uns%%[[:space:]]*}" got_78="${got_78%%[[:space:]]*}"
  if [ "$got_uns" = "und:unsupported-at-base" ] && [ "$got_78" = "fail" ]; then
    pass "C3-unsupported-at-base: unsupported test recorded und:unsupported-at-base; exit-78 test recorded fail"
  else
    fail "C3-unsupported-at-base: ledger mismatch; unsupported=[$got_uns] exit78=[$got_78]"
  fi

  # Exec layer: exactly one <i>.unsupported marker, beside the launcher's UNSUPPORTED: output.
  logdir="$(printf '%s\n' "$RTB_CLI_OUT" | sed -n 's/^run-tests-baseline: base-run logs: //p' | head -n 1)"
  n_uns=0; idx=""
  if [ -n "$logdir" ] && [ -d "$logdir" ]; then
    for f in "$logdir"/*.unsupported; do
      [ -e "$f" ] || continue
      n_uns=$((n_uns + 1)); idx="${f##*/}"; idx="${idx%.unsupported}"
    done
  fi
  if [ "$n_uns" -eq 1 ] && grep -qF "UNSUPPORTED: " "$logdir/$idx.out" 2>/dev/null \
    && grep -qF "test-unsup.test.ts" "$logdir/$idx.out" 2>/dev/null; then
    pass "C3-unsupported-at-base: one .unsupported marker, for the not-launched test only"
  else
    fail "C3-unsupported-at-base: expected one .unsupported marker for $t_uns; logdir=[$logdir] count=$n_uns"
  fi
  cli_assert_auto_accepted "C3-unsupported-at-base" "uns-$$" "$t_uns"
}
