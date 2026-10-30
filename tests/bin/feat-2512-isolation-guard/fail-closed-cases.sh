# #2589: inside the agents repo each of the six pre-commit gates blocks the commit when its
# checker is missing or answers an rc other than 0, 1 or 2; outside it nothing runs.
# #2507: the gates are Node modules the agents-repo-gates check loads from the cfg checkout.
# Sourced by feat-2512-isolation-guard.sh after its pin; defines case bodies only.

# Parallel arrays: the cliPath a message names, and the module the check loads for it.
FC_CHECKERS=(
  bin/check-on-demand-rules.sh
  bin/check-session-id-ssot.sh
  bin/check-migration-blocks.sh
  bin/check-plans-artifacts
  bin/check-plans-dir-isolation.sh
  bin/check-root-names.sh
)
FC_MODULES=(
  bin/lib/check-on-demand-rules.js
  bin/check-session-id-ssot/main.js
  bin/lib/check-migration-blocks.js
  bin/check-plans-artifacts
  bin/check-plans-dir-isolation/main.js
  bin/check-root-names/main.js
)
FC_RUNNER="$(np "$SCRIPT_CHECKOUT_ROOT/tests/lib/precommit-check-runner.js")"
FC_TEMPLATE="$T/fc-template"

. "$SCRIPT_CHECKOUT_ROOT/tests/lib/node-entry-sandbox.sh"

# fc_module_of <checker> — the module path paired with a cliPath.
fc_module_of() {
  local i
  for i in "${!FC_CHECKERS[@]}"; do
    if [[ "${FC_CHECKERS[$i]}" == "$1" ]]; then
      printf '%s' "${FC_MODULES[$i]}"
      return 0
    fi
  done
  return 1
}

# fc_stub <repo> <checker> <rc> — the checker's module only answers <rc>.
fc_stub() {
  local f
  f="$1/$(fc_module_of "$2")"
  mkdir -p "$(dirname "$f")"
  printf 'exports.run = async () => %s;\n' "$3" > "$f"
}

# fc_stub_all_clean <repo> [skip-checker] — every checker but <skip-checker> as a clean stub.
fc_stub_all_clean() {
  local c
  for c in "${FC_CHECKERS[@]}"; do
    [[ "$c" == "${2:-}" ]] || fc_stub "$1" "$c" 0
  done
}

# fc_template — the pre-commit body and hooks/lib, built once and copied per fixture.
fc_template() {
  [[ -d "$FC_TEMPLATE/hooks/pre-commit.d" ]] && return 0
  mkdir -p "$FC_TEMPLATE/hooks/lib"
  node_entry_sandbox_copy "$FC_TEMPLATE" hooks/pre-commit.d/main.js >/dev/null
  cp -R "$SCRIPT_CHECKOUT_ROOT/hooks/lib/." "$FC_TEMPLATE/hooks/lib/"
}

# fc_repo <dir> — a fixture repo carrying the template (the gates' checkout is the repo).
fc_repo() {
  fc_template
  mkdir -p "$1"
  cp -R "$FC_TEMPLATE/." "$1/"
  harness_git_init "$1"
  git -C "$1" config core.autocrlf false
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name test
}

# fc_fixture <name> — agents-repo fixture with six clean checkers and one file staged; sets R.
fc_fixture() {
  R="$(np "$T/fc/$1")"
  fc_repo "$R"
  fc_stub_all_clean "$R"
  git -C "$R" add -A
  git -C "$R" commit -qm fixture
  printf 'x\n' > "$R/app.txt"
  git -C "$R" add app.txt
}

# fc_run <repo> <cfg-dir> — the agents-repo-gates check from inside <repo>; sets FC_OUT / FC_RC.
fc_run() {
  FC_RC=0
  FC_OUT="$(cd "$1" && run_with_timeout 60 node "$FC_RUNNER" --cfg "$2" agents-repo-gates 2>&1)" || FC_RC=$?
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
    rm -f "$R/$(fc_module_of "$c")"
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
  for c in "${FC_CHECKERS[@]}"; do rm -f "$cfg/$(fc_module_of "$c")"; done
  fc_fixture other
  fc_run "$R" "$cfg"
  if [[ "$FC_RC" -eq 0 ]]; then pass "FC other repo: missing checkers of another checkout do not block"; else fail "FC other repo: missing checkers" "rc=$FC_RC out=$FC_OUT"; fi
}
