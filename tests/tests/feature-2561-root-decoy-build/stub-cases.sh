#!/usr/bin/env bash
# tests/tests/feature-2561-root-decoy-build/stub-cases.sh — sourced by
# tests/tests/feature-2561-root-decoy-build.sh: the case bodies that reach a stub of the
# single tree ($TREE) and read the hit it records. Functions only.

stub_case_node() {
  local before
  before="$(hit_count)"
  expect_ne "node stub exits non-zero" "$(rc_of node "$TREE/hooks/hook.js")" "0"
  expect_ne "cjs stub exits non-zero when required" "$(rc_of node -e 'require(process.argv[1])' "$TREE/hooks/lib/mod.cjs")" "0"
  expect_ne "esm stub exits non-zero" "$(rc_of node "$TREE/hooks/esm.mjs")" "0"
  expect_eq "three node hits recorded" "$(($(hit_count) - before))" "3"
  expect_eq "node hit names the stub path" "$(hit_lines "hooks/hook.js$TAB")" "1"
}

stub_case_bash() {
  local before sourced
  before="$(hit_count)"
  expect_ne "bash stub exits non-zero" "$(rc_of bash "$TREE/bin/sub dir/spaced tool.sh")" "0"
  sourced="$(bash -c 'source "$1" 2>/dev/null; printf "%s:alive" "$?"' _ "$TREE/bin/sub dir/spaced tool.sh")"
  expect_ne "sourced bash stub returns non-zero" "${sourced%%:*}" "0"
  expect_eq "sourcing shell is not killed" "${sourced#*:}" "alive"
  expect_eq "run and source each record one hit" "$(($(hit_count) - before))" "2"
  expect_eq "bash hits name the spaced stub path" "$(hit_lines "bin/sub dir/spaced tool.sh$TAB")" "2"
}

stub_case_shebang() {
  local before
  before="$(hit_count)"
  expect_ne "extensionless node stub fails under node" "$(rc_of node "$TREE/bin/nodecli")" "0"
  expect_ne "extensionless bash stub fails under bash" "$(rc_of bash "$TREE/bin/bashcli")" "0"
  expect_eq "both extensionless stubs record a hit" "$(($(hit_count) - before))" "2"
  expect_has "non-script keeps only the marker text" "$(cat "$TREE/skills/demo/SKILL.md")" "ROOT-DECOY-STUB"
  expect_has "file without shebang keeps only the marker text" "$(cat "$TREE/bin/plainfile")" "ROOT-DECOY-STUB (not a script)"
}

stub_case_python() {
  local before python_bin=""
  if python3 -c "" >/dev/null 2>&1; then python_bin=python3; elif python -c "" >/dev/null 2>&1; then python_bin=python; fi
  before="$(hit_count)"
  if [[ -n "$python_bin" ]]; then
    expect_ne "python stub exits non-zero" "$(rc_of "$python_bin" "$TREE/bin/tool.py")" "0"
    expect_eq "python hit names the stub path" "$(($(hit_count) - before)):$(hit_lines "bin/tool.py$TAB")" "1:1"
  else
    skip "python stub: no working python on PATH"
  fi
}

stub_case_powershell() {
  local before
  before="$(hit_count)"
  if command -v pwsh >/dev/null 2>&1; then
    expect_ne "powershell stub exits non-zero" "$(rc_of run_with_timeout 60 pwsh -NoProfile -File "$TREE/bin/tool.ps1")" "0"
    expect_eq "powershell hit names the stub path" "$(($(hit_count) - before)):$(hit_lines "bin/tool.ps1$TAB")" "1:1"
  else
    skip "powershell stub: pwsh not on PATH"
  fi
}

stub_case_stripped_environment() {
  local before
  before="$(hit_count)"
  expect_ne "bash stub fails under an empty environment" "$(rc_of env -i "$(command -v bash)" "$TREE/bin/bashcli")" "0"
  expect_ne "node stub fails under an empty environment" "$(rc_of env -i "$(command -v node)" "$TREE/hooks/hook.js")" "0"
  expect_eq "both stripped runs record a hit" "$(($(hit_count) - before))" "2"
}

stub_case_test_id() {
  ROOT_DECOY_TEST_ID="lane-7/some-test.sh" node "$TREE/hooks/hook.js" >/dev/null 2>&1
  ROOT_DECOY_TEST_ID="lane-8/other-test.sh" bash "$TREE/bin/bashcli" >/dev/null 2>&1
  expect_eq "node hit carries the test id" "$(hit_lines "hooks/hook.js${TAB}lane-7/some-test.sh")" "1"
  expect_eq "bash hit carries the test id" "$(hit_lines "bin/bashcli${TAB}lane-8/other-test.sh")" "1"
}

stub_case_metacharacters() {
  local before
  before="$(hit_count)"
  mkdir -p "$TMP_ROOT/neutral cwd"
  (cd "$TMP_ROOT/neutral cwd" && ROOT_DECOY_FIXTURE_SECRET="s3cr3t-value" bash "$TREE/$META_REL" >/dev/null 2>&1)
  expect_ne "metacharacter stub still exits non-zero" "$?" "0"
  expect_eq "metacharacter stub records one hit" "$(($(hit_count) - before))" "1"
  expect_eq "hit keeps the literal path" "$(hit_lines "$META_REL$TAB")" "1"
  expect_eq "no command embedded in the path ran" "$(find "$TMP_ROOT" -name INJECTED | wc -l | tr -d ' ')" "0"
  expect_eq "hit records hold only the two fixed fields" "$(cat "$TREE"/hits/*.hit | grep -c -v -E '^(stub|test_id)=' || true)" "0"
  expect_eq "no environment value leaks into a hit record" "$(grep -r -l "s3cr3t-value" "$TREE/hits" | wc -l | tr -d ' ')" "0"
}
