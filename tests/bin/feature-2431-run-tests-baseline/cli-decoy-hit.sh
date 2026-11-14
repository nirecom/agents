# shellcheck shell=bash
# tests/bin/feature-2431-run-tests-baseline/cli-decoy-hit.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-exec.sh
# Tags: run-tests, baseline, cli, exec, root-names, scope:issue-specific, pwsh-not-required, TL2
# Sourced by the dispatcher after root-names.sh (uses its _RN_NEW_NAME); never run standalone.
# #2561: a base run that reached the root decoy gives no verdict, whatever it exits with:
# undetermined root-decoy-hit-at-base, recorded in the ledger as und:root-decoy-hit-at-base
# (#3037) and restored, not re-run at base, on a re-run at the same base SHA; auto-accepted
# since #2688. A base failure without a hit in the same run is still preexisting and recorded.

run_cli_decoy_hit_cases() {
  local repo="$TMPROOT/repo-decoy-hit" sid="dhit-$$" t_pre="tests/bin/test-preexisting.sh"
  local decoy cache base logdir t n got
  local -a hits=(tests/bin/test-decoy-exit0.sh tests/bin/test-decoy-exit3.sh)
  mk_fixture_repo "$repo" >/dev/null
  git -C "$repo" checkout -q main
  for n in 0 3; do
    printf '#!/usr/bin/env bash\nnode "$%s/hooks/lib/load-env.js" >/dev/null 2>&1 || true\nexit %s\n' \
      "$_RN_NEW_NAME" "$n" > "$repo/tests/bin/test-decoy-exit$n.sh"
  done
  chmod +x "$repo/tests/bin/"*.sh
  git -C "$repo" add tests/
  git -C "$repo" commit -q -m "decoy-reaching tests at base"
  base="$(git -C "$repo" rev-parse main)"
  git -C "$repo" checkout -q feature
  git -C "$repo" merge -q --no-edit main
  # The hits must come from the base copies: the branch stage runs the branch copies first.
  feat_commit_failing "$repo" "${hits[@]}"

  # A decoy of this case's own: the hits must not land in the tree the running suite watches.
  decoy="$(np "$TMPROOT/decoy-cli-hit")"
  cache="$(cli_case_cache dhit)"
  seed_failing "$sid" "${hits[@]}" "$t_pre"
  ROOT_DECOY_DIR="$decoy" rtb_cli_run "$cache" "$repo" "$sid"

  for t in "${hits[@]}"; do
    if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: undetermined[[:space:]]+$t[[:space:]]+root-decoy-hit-at-base\$"; then
      pass "C3-root-decoy-hit: $t classified undetermined root-decoy-hit-at-base"
    else
      fail "C3-root-decoy-hit: expected undetermined root-decoy-hit-at-base for $t; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
    fi
    if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: (preexisting[^ ]*|broken)[[:space:]]+$t"; then
      fail "C3-root-decoy-hit: $t must be neither preexisting nor broken ($(cli_baseline_lines))"
    else
      pass "C3-root-decoy-hit: $t is neither preexisting nor broken"
    fi
    got="$(ledger_call "$cache" "$repo" rtb_ledger_lookup_same_base "$base" "$t" 2>/dev/null)"
    # v3 (#2956 S7) may print the fingerprint after the result; only the result token is compared.
    got="${got%%[[:space:]]*}"
    [ "$got" = "und:root-decoy-hit-at-base" ] && pass "C3-root-decoy-hit: $t recorded in the ledger as und:root-decoy-hit-at-base" \
      || fail "C3-root-decoy-hit: expected ledger und:root-decoy-hit-at-base for $t, got [$got]"
    cli_assert_auto_accepted "C3-root-decoy-hit" "$sid" "$t"
  done

  # Control: the same run still judges and records a base failure that reached no decoy.
  # t_pre writes the same case detail on both sides, so the comparison is `same` (#2956 S8 table 1).
  got="$(ledger_call "$cache" "$repo" rtb_ledger_lookup_same_base "$base" "$t_pre" 2>/dev/null)"
  got="${got%%[[:space:]]*}"
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: preexisting[[:space:]]+$t_pre[[:space:]]+fails-at-base-exit-1\$" \
    && [ "$got" = "fail" ]; then
    pass "C3-root-decoy-hit-control: a base failure without a hit stays preexisting and is recorded fail"
  else
    fail "C3-root-decoy-hit-control: expected preexisting + ledger fail for $t_pre; ledger=[$got] ($(cli_baseline_lines))"
  fi
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qxF "$(baseline_summary 1 0 0 2 0 0)" \
    && [ "$RTB_CLI_RC" -eq 0 ]; then
    pass "C3-root-decoy-hit: summary preexisting=1 undetermined=2 and exit 0 (auto + proof)"
  else
    fail "C3-root-decoy-hit: summary/exit mismatch; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi

  logdir="$(printf '%s\n' "$RTB_CLI_OUT" | sed -n 's/^run-tests-baseline: base-run logs: //p' | head -n 1)"
  n="$(find "$logdir" -name '*.decoyhit' 2>/dev/null | wc -l | tr -d ' ')"
  [ -n "$logdir" ] && [ "$n" = "2" ] && pass "C3-root-decoy-hit: one .decoyhit marker per decoy-reaching test, none for the control" \
    || fail "C3-root-decoy-hit: expected 2 .decoyhit markers; logdir=[$logdir] count=$n"

  # #3037 regression: a re-run at the same base SHA restores the cached undetermined result and
  # must not run the hits at base again (a fresh sid, since run_tests is already complete).
  local out1="$RTB_CLI_OUT" sid2="dhit2-$$" logdir2 n2 l1 l2
  l1="$(printf '%s\n' "$out1" | grep -E '^BASELINE: ' | grep -E "tests/bin/test-decoy-exit" | sort)"
  seed_failing "$sid2" "${hits[@]}" "$t_pre"
  ROOT_DECOY_DIR="$decoy" rtb_cli_run "$cache" "$repo" "$sid2"
  for t in "${hits[@]}"; do
    if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: undetermined[[:space:]]+$t[[:space:]]+root-decoy-hit-at-base\$"; then
      pass "C3-root-decoy-hit-rerun: $t classified undetermined root-decoy-hit-at-base again"
    else
      fail "C3-root-decoy-hit-rerun: expected undetermined root-decoy-hit-at-base for $t on re-run; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
    fi
  done
  l2="$(printf '%s\n' "$RTB_CLI_OUT" | grep -E '^BASELINE: ' | grep -E "tests/bin/test-decoy-exit" | sort)"
  [ -n "$l1" ] && [ "$l1" = "$l2" ] && pass "C3-root-decoy-hit-rerun: classify result of the hits is identical to the first run" \
    || fail "C3-root-decoy-hit-rerun: classify result changed between runs; first=[$l1] second=[$l2]"
  logdir2="$(printf '%s\n' "$RTB_CLI_OUT" | sed -n 's/^run-tests-baseline: base-run logs: //p' | head -n 1)"
  n2=0
  [ -n "$logdir2" ] && [ "$logdir2" != "$logdir" ] && n2="$(find "$logdir2" -name '*.decoyhit' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n2" = "0" ] && pass "C3-root-decoy-hit-rerun: no .decoyhit marker on re-run (hits not re-run at base)" \
    || fail "C3-root-decoy-hit-rerun: expected 0 .decoyhit markers on re-run; logdir2=[$logdir2] count=$n2"
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qxF "$(baseline_summary 1 0 0 2 0 0)" \
    && [ "$RTB_CLI_RC" -eq 0 ]; then
    pass "C3-root-decoy-hit-rerun: summary preexisting=1 undetermined=2 and exit 0, same as the first run"
  else
    fail "C3-root-decoy-hit-rerun: summary/exit mismatch; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
  cli_assert_auto_accepted "C3-root-decoy-hit-rerun" "$sid2" "${hits[0]}"
  cli_assert_auto_accepted "C3-root-decoy-hit-rerun" "$sid2" "${hits[1]}"
}
