# Gate wiring (pre-commit, CI) and stage-3 template cases for feat-2512-isolation-guard.sh.
# Sourced by the dispatcher after its pin; defines case bodies only.

# run_gate <consumer-dir> — run the agents-repo pre-commit gates in a consumer repo.
run_gate() {
  local cons="$1"
  PC_RC=0
  PC_OUT="$(cd "$cons" && export _cfg_dir="$cons" &&run_with_timeout 60 bash -c '. "$1"; _precommit_agents_repo_gates' _ "$SCRIPT_CHECKOUT_ROOT/hooks/lib/precommit-agents-repo-gates.sh" 2>&1)" || PC_RC=$?
}

c_i13_precommit_gate() {
  local cons rc
  cons="$(np "$T/i13")"
  mkdir -p "$cons/bin"
  harness_git_init "$cons"
  git -C "$cons" config core.autocrlf false
  git -C "$cons" config user.email test@example.com
  git -C "$cons" config user.name test
  fx "$cons/bin/check-plans-dir-isolation.sh" '#!/usr/bin/env bash' \
    'here="$(cd "$(dirname "$0")" && pwd)"' 'printf "%s\n" "$*" >> "$here/../stub-args.log"' \
    'echo "STATE-UNPINNED: tests/hooks/stub-fixture.sh"' 'exit "$(cat "$here/../stub-rc")"'
  chmod +x "$cons/bin/check-plans-dir-isolation.sh"
  printf '1\n' > "$cons/stub-rc"
  git -C "$cons" add -A

  run_gate "$cons"
  expect "I13 a classifier rc=1 blocks the commit (gate exit 1)" test "$PC_RC" = 1
  expect "I13 the classifier output is shown" test "${PC_OUT#*STATE-UNPINNED: tests/hooks/stub-fixture.sh}" != "$PC_OUT"
  expect "I13 the gate passes --staged" grep -q -- '--staged' "$cons/stub-args.log"

  for rc in 0 2 3; do
    printf '%s\n' "$rc" > "$cons/stub-rc"
    run_gate "$cons"
    case "$rc" in
      2) expect "I13 a classifier rc=2 blocks the commit" test "$PC_RC" = 1 ;;
      *) expect "I13 a classifier rc=$rc lets the commit through" test "$PC_RC" = 0 ;;
    esac
  done
  # Skip path (plan: "other rc -> diagnostic and skip"). Assumption: the diagnostic
  # follows the sibling gates' shape, one line naming the checker and "skipped".
  expect "I13 an unexpected rc=3 prints a skip diagnostic naming the classifier" \
    grep -qE 'check-plans-dir-isolation[^ ]* rc=3.*skipped' <<<"$PC_OUT"
  rm -f "$cons/bin/check-plans-dir-isolation.sh"
  run_gate "$cons"
  expect "I13 a missing classifier lets the commit through" test "$PC_RC" = 0
  expect "I13 a missing classifier prints a skip diagnostic" \
    grep -qE 'check-plans-dir-isolation.*skipped' <<<"$PC_OUT"
}

c_i14_ci_step() {
  local yml="$SCRIPT_CHECKOUT_ROOT/.github/workflows/migration-blocks-audit.yml" step
  expect "I14 the CI yml runs the classifier" grep -qE '^[[:space:]]*run:[[:space:]]*bash bin/check-plans-dir-isolation\.sh[[:space:]]*$' "$yml"
  step="$(grep -E 'check-plans-dir-isolation' "$yml" || true)"
  expect "I14 the CI step does not swallow failures with ||" test "${step#*||}" = "$step"
  expect "I14 the CI yml has no continue-on-error" test -z "$(grep -E 'continue-on-error' "$yml" || true)"
}

c_i20_templates_contract() {
  local r
  r="$(new_root i20)"
  fx "$r/hooks/tpl-a.sh" '#!/usr/bin/env bash' 'source "$(dirname "$0")/../lib/harness.sh"' \
    '_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT' \
    'harness_isolate "$_ISOLATION_TMP_ROOT"' "trap 'rm -rf \"\$_ISOLATION_TMP_ROOT\"' EXIT" "$EXEC_RO"
  fx "$r/hooks/tpl-b.sh" "${TPL_B[@]}" "$EXEC_RO"
  run_cls --root "$r"
  expect "I20 template (a) satisfies the contract" no_violation_for "tpl-a.sh"
  expect "I20 template (b) satisfies the contract" no_violation_for "tpl-b.sh"
  expect "I20 rc=0 for the two templates" rc_is 0
}

c_i20_template_b_runtime() {
  local s rec repoint tmp_root
  s="$T/i20-run/tpl-b-run.sh"
  rec="$T/i20-run/root.txt"
  repoint="$T/i20-run/repoint"
  mkdir -p "$repoint"
  printf 'keep\n' > "$repoint/keep.txt"
  fx "$s" "${TPL_B[@]}" 'printf "%s\n" "$_ISOLATION_TMP_ROOT" > "$1"' 'export WORKFLOW_STATE_DIR="$2"'
  run_with_timeout 30 bash "$s" "$rec" "$repoint"
  tmp_root="$(cat "$rec")"
  expect "I20 runtime: the template recorded its tmp root" test -n "$tmp_root"
  expect "I20 runtime: the template tmp root is removed on exit" test ! -e "$tmp_root"
  expect "I20 runtime: the re-pointed dir survives" test -f "$repoint/keep.txt"
}
