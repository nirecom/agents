# shellcheck shell=bash
# tests/bin/feature-2431-run-tests-baseline/cli-decoy-hit.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-exec.sh
# Tags: run-tests, baseline, cli, exec, root-names, scope:issue-specific, pwsh-not-required, TL2
# Sourced by the dispatcher after root-names.sh (uses its _RN_NEW_NAME); never run standalone.
# #2561: a base run that reached the root decoy gives no verdict, whatever it exits with:
# undetermined root-decoy-hit-at-base, no ledger record. A base failure without a hit in the
# same run is still preexisting and recorded.

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
    [ -z "$got" ] && pass "C3-root-decoy-hit: no ledger record for $t" \
      || fail "C3-root-decoy-hit: $t was written to the ledger as [$got]"
    cli_assert_not_completed "C3-root-decoy-hit" "$sid" "$t"
  done

  # Control: the same run still judges and records a base failure that reached no decoy.
  got="$(ledger_call "$cache" "$repo" rtb_ledger_lookup_same_base "$base" "$t_pre" 2>/dev/null)"
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: preexisting[[:space:]]+$t_pre[[:space:]]+fails-at-base-exit-1\$" \
    && [ "$got" = "fail" ]; then
    pass "C3-root-decoy-hit-control: a base failure without a hit stays preexisting and is recorded fail"
  else
    fail "C3-root-decoy-hit-control: expected preexisting + ledger fail for $t_pre; ledger=[$got] ($(cli_baseline_lines))"
  fi
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE '^BASELINE_SUMMARY: preexisting=1 inherited=0 broken=0 undetermined=2$' \
    && [ "$RTB_CLI_RC" -eq 1 ]; then
    pass "C3-root-decoy-hit: summary preexisting=1 undetermined=2 and exit 1"
  else
    fail "C3-root-decoy-hit: summary/exit mismatch; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi

  logdir="$(printf '%s\n' "$RTB_CLI_OUT" | sed -n 's/^run-tests-baseline: base-run logs: //p' | head -n 1)"
  n="$(find "$logdir" -name '*.decoyhit' 2>/dev/null | wc -l | tr -d ' ')"
  [ -n "$logdir" ] && [ "$n" = "2" ] && pass "C3-root-decoy-hit: one .decoyhit marker per decoy-reaching test, none for the control" \
    || fail "C3-root-decoy-hit: expected 2 .decoyhit markers; logdir=[$logdir] count=$n"
}
