# shellcheck shell=bash
# tests/bin/feature-3055-branch-decoy-base-fail/cli.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, root-names, scope:issue-specific, pwsh-not-required, TL2
# CLI case of tests/bin/feature-3055-branch-decoy-base-fail.sh: a real branch solo run hits the root
# decoy. t.sh is identical on main and feature; only tests/lib/dep.sh (which t.sh sources) differs,
# and the feature copy reaches the main root, so only the branch run hits the decoy (the #3055 shape).
# Sourced by the entrypoint after feature-2688-branch-rerun/_lib.sh (mk_repo, seed, rtb, field).

bd_cli_auto() {
  local R="$TMPROOT/cli-decoy" S S2 DECOY ROOT_VAR="AGENTS_MAIN""_ROOT"
  mk_repo "$R" 0; mkdir -p "$R.cache" "$R/tests/lib"
  git -C "$R" checkout -q main
  printf '#!/usr/bin/env bash\n. "$(dirname "$0")/../lib/dep.sh"\nexit 1\n' >"$R/tests/bin/t.sh"
  printf 'touch "%s"\n' "$(np "$R.marks")/base" >"$R/tests/lib/dep.sh"
  git -C "$R" add -A; git -C "$R" commit -q -m "dep on main"
  git -C "$R" checkout -q feature
  git -C "$R" checkout main -- tests/bin/t.sh tests/lib/dep.sh
  git -C "$R" add -A; git -C "$R" commit -q -m "t.sh as on main"
  git -C "$R" merge -q --no-edit main
  printf 'touch "%s"\nnode "$%s/hooks/lib/load-env.js" >/dev/null 2>&1 || true\n' \
    "$(np "$R.marks")/branch" "$ROOT_VAR" >"$R/tests/lib/dep.sh"
  git -C "$R" add -A; git -C "$R" commit -q -m "dep reaches the main root"
  ck "cli: fixture: t.sh is unchanged against main" "" "$(git -C "$R" diff main -- tests/bin/t.sh)"
  S="bd-cli-$$"; DECOY="$(np "$TMPROOT/decoy-cli")"
  seed "$S" '{"tests/bin/t.sh":1}' tests/bin/t.sh
  rtb "$R.cache" "$R" "$S" ROOT_DECOY_DIR="$DECOY"
  ck "cli: exit 0" 0 "$RTB_RC"
  present "cli: the branch copy ran alone" "$R.marks/branch"
  present "cli: the base ran" "$R.marks/base"
  ck "cli: fixture: the branch run was a decoy hit" "inconclusive:decoy" \
    "$(grep -hom 1 'inconclusive:decoy' "$R.cache"/branch.v2.*.seg 2>/dev/null)"
  has_line "cli: root-decoy-hit-on-branch line" "BASELINE: undetermined tests/bin/t.sh root-decoy-hit-on-branch"
  lacks_line "cli: no records-missing line" "case-records-missing-on-branch"
  ck "cli: auto-accepted" "baseline-auto-accepted" "$(field "$S" completion_basis)"
  # Second session on the same cache: the ledger's same-base fail row decides, the base does not re-run.
  rm -f "$R.marks/base"; S2="bd-cli2-$$"
  seed "$S2" '{"tests/bin/t.sh":1}' tests/bin/t.sh
  rtb "$R.cache" "$R" "$S2" ROOT_DECOY_DIR="$DECOY"
  ck "cli (ledger): exit 0" 0 "$RTB_RC"
  absent "cli (ledger): the base did not re-run" "$R.marks/base"
  has_line "cli (ledger): root-decoy-hit-on-branch line" "BASELINE: undetermined tests/bin/t.sh root-decoy-hit-on-branch"
  ck "cli (ledger): auto-accepted" "baseline-auto-accepted" "$(field "$S2" completion_basis)"
}
