# #2589: inside the agents repo each of the six pre-commit gates blocks the commit when its
# checker is missing or answers an rc other than 0, 1 or 2; outside it nothing runs.
# Sourced by feat-2512-isolation-guard.sh after its pin; defines case bodies only.

FC_CHECKERS=(
  bin/check-on-demand-rules.sh
  bin/check-session-id-ssot.sh
  bin/check-migration-blocks.sh
  bin/check-plans-artifacts
  bin/check-plans-dir-isolation.sh
  bin/check-root-names.sh
)

# fc_stub <repo> <checker> <rc> — a checker that only answers <rc> (plans-artifacts runs under node).
fc_stub() {
  local f="$1/$2"
  mkdir -p "$(dirname "$f")"
  if [[ "$2" == bin/check-plans-artifacts ]]; then
    printf '%s\n' '"use strict";' "process.exit($3);" > "$f"
  else
    printf '%s\n' '#!/usr/bin/env bash' "exit $3" > "$f"
  fi
  chmod +x "$f"
}

# fc_stub_all_clean <repo> [skip-checker] — every checker but <skip-checker> as a clean stub.
fc_stub_all_clean() {
  local c
  for c in "${FC_CHECKERS[@]}"; do
    [[ "$c" == "${2:-}" ]] || fc_stub "$1" "$c" 0
  done
}

# fc_fixture <name> — agents-repo fixture (the gates' checkout is the repo) with six clean
# checkers and one file staged; sets R.
fc_fixture() {
  R="$(np "$T/fc/$1")"
  mkdir -p "$R"
  harness_git_init "$R"
  git -C "$R" config core.autocrlf false
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  fc_stub_all_clean "$R"
  git -C "$R" add -A
  git -C "$R" commit -qm fixture
  printf 'x\n' > "$R/app.txt"
  git -C "$R" add app.txt
}

# fc_run <repo> <cfg-dir> — the gates library from inside <repo>; sets FC_OUT / FC_RC.
fc_run() {
  FC_RC=0
  FC_OUT="$(cd "$1" && run_with_timeout 60 bash -c '. "$1"; _cfg_dir="$2"; _precommit_agents_repo_gates' _ \
    "$SCRIPT_CHECKOUT_ROOT/hooks/lib/precommit-agents-repo-gates.sh" "$2" 2>&1)" || FC_RC=$?
}

# fc_blocked <label> <checker> — the commit is stopped and the output names the checker.
fc_blocked() {
  local base="${2##*/}"
  if [[ "$FC_RC" -eq 0 ]]; then
    fail "$1: the commit is blocked" "rc=0 out=$(tr '\n' ' ' <<<"$FC_OUT")"
  elif [[ "$FC_OUT" != *"$base"* ]]; then
    fail "$1: the output names $base" "rc=$FC_RC out=$(tr '\n' ' ' <<<"$FC_OUT")"
  else
    pass "$1: blocked (rc=$FC_RC) and names $base"
  fi
}

c_fc_all_clean_passes() {
  fc_fixture clean
  fc_run "$R" "$R"
  if [[ "$FC_RC" -eq 0 ]]; then pass "FC control: six clean checkers let the commit through"; else fail "FC control: six clean checkers" "rc=$FC_RC out=$FC_OUT"; fi
}

c_fc_missing_checker_blocks() {
  local c i=0
  for c in "${FC_CHECKERS[@]}"; do
    i=$((i + 1))
    fc_fixture "missing-$i"
    rm -f "$R/$c"
    fc_run "$R" "$R"
    fc_blocked "FC missing $c" "$c"
  done
}

c_fc_unexpected_rc_blocks() {
  local c i=0
  for c in "${FC_CHECKERS[@]}"; do
    i=$((i + 1))
    fc_fixture "rc3-$i"
    fc_stub "$R" "$c" 3
    fc_run "$R" "$R"
    fc_blocked "FC rc 3 from $c" "$c"
    if [[ "$FC_OUT" == *"rc=3"* ]]; then pass "FC rc 3 from $c: the rc is shown"; else fail "FC rc 3 from $c: the rc is shown" "out=$(tr '\n' ' ' <<<"$FC_OUT")"; fi
  done
}

# Outside the agents repo the gates never run, so a missing checker cannot block.
c_fc_other_repo_is_untouched() {
  local c cfg
  fc_fixture agents-cfg
  cfg="$R"
  for c in "${FC_CHECKERS[@]}"; do rm -f "$cfg/$c"; done
  fc_fixture other
  fc_run "$R" "$cfg"
  if [[ "$FC_RC" -eq 0 ]]; then pass "FC other repo: missing checkers of another checkout do not block"; else fail "FC other repo: missing checkers" "rc=$FC_RC out=$FC_OUT"; fi
}
