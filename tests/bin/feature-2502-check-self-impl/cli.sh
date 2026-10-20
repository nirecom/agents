# bin/check-self-impl.sh run directly, one fixture repo, cwd at its root (#2502 S3).
# Sourced by tests/bin/feature-2502-check-self-impl.sh.
# shellcheck shell=bash

echo ""
echo "=== cli: bin/check-self-impl.sh ==="

REPO_CLI="$TMPBASE/repo-cli"
mkrepo "$REPO_CLI"
put "$REPO_CLI" tests/bin/selfimpl.sh sh-bad
put "$REPO_CLI" tests/bin/clean.sh sh-clean
put "$REPO_CLI" tests/bin/test_selfimpl.py pytest-bad
put "$REPO_CLI" tests/bin/test_clean.py pytest-clean
put "$REPO_CLI" tests/bin/selfimpl.Tests.ps1 pester-bad
put "$REPO_CLI" tests/bin/clean.Tests.ps1 pester-clean
put "$REPO_CLI" tests/bin/selfimpl.js js-bad
put "$REPO_CLI" tests/bin/clean.js js-clean
put "$REPO_CLI" tests/bin/selfimpl.test.ts ts-bad

SI_LINE_RE='^HIGH: [^ ]+ line [0-9]+: self-implemented harness \((counter-init|harness-redef) [^)]+\) code=SELF_IMPLEMENTED_HARNESS$'

# shape_all <label> <file> — every stdout line has the HIGH shape and names <file>.
shape_all() {
  local line bad=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [[ "$line" =~ $SI_LINE_RE ]] || bad="$bad[$line]"
    [ "${line#"HIGH: $2 line "}" != "$line" ] || bad="$bad[not $2: $line]"
  done <<< "$SI_OUT"
  if [ -z "$SI_OUT" ]; then
    fail "$1" "no output (rc=$SI_RC err=$SI_ERR)"
  elif [ -z "$bad" ]; then
    pass "$1: every line has the HIGH shape"
  else
    fail "$1" "lines off the shape: $bad"
  fi
}

# check_lang <label> <rel> <counter-line> <redef-line> <redef-name> — rc 1, both kinds found.
check_lang() {
  si "$REPO_CLI" "$2"
  expect_rc "$1" 1 "$SI_RC" "$SI_OUT $SI_ERR"
  shape_all "$1" "$2"
  has "$1 counter" "$SI_OUT" "HIGH: $2 line $3: self-implemented harness (counter-init "
  has "$1 redef" "$SI_OUT" "HIGH: $2 line $4: self-implemented harness (harness-redef $5) code=SELF_IMPLEMENTED_HARNESS"
}

case_begin "si-bash-exact-lines" "bin/check-self-impl.sh"
si "$REPO_CLI" tests/bin/selfimpl.sh
expect_rc "bash self-impl" 1 "$SI_RC" "$SI_OUT $SI_ERR"
assert_eq "$SI_OUT" "HIGH: tests/bin/selfimpl.sh line 5: self-implemented harness (counter-init PASS=0) code=SELF_IMPLEMENTED_HARNESS
HIGH: tests/bin/selfimpl.sh line 6: self-implemented harness (harness-redef pass) code=SELF_IMPLEMENTED_HARNESS"
case_end

case_begin "si-pytest-detects" "bin/check-self-impl.sh"
if command -v uv >/dev/null 2>&1; then
  check_lang "pytest self-impl" tests/bin/test_selfimpl.py 5 8 isolate
else
  skip "pytest self-impl: uv not installed"
fi
case_end

case_begin "si-pester-detects" "bin/check-self-impl.sh"
if command -v pwsh >/dev/null 2>&1; then
  check_lang "pester self-impl" tests/bin/selfimpl.Tests.ps1 6 7 Enter-HarnessIsolation
else
  skip "pester self-impl: pwsh not installed"
fi
case_end

case_begin "si-js-detects" "bin/check-self-impl.sh"
check_lang "js self-impl" tests/bin/selfimpl.js 4 6 isolate
has "js redef gitInit" "$SI_OUT" "HIGH: tests/bin/selfimpl.js line 5: self-implemented harness (harness-redef gitInit) code=SELF_IMPLEMENTED_HARNESS"
case_end

case_begin "si-clean-files-pass" "bin/check-self-impl.sh"
_clean=(tests/bin/clean.sh tests/bin/clean.js)
command -v uv >/dev/null 2>&1 && _clean+=(tests/bin/test_clean.py)
command -v pwsh >/dev/null 2>&1 && _clean+=(tests/bin/clean.Tests.ps1)
si "$REPO_CLI" "${_clean[@]}"
expect_rc "clean files" 0 "$SI_RC" "$SI_OUT $SI_ERR"
assert_eq "$SI_OUT" ""
case_end

case_begin "si-multi-file-names-only-the-bad-one" "bin/check-self-impl.sh"
si "$REPO_CLI" tests/bin/clean.js tests/bin/selfimpl.js
expect_rc "clean + bad" 1 "$SI_RC" "$SI_OUT $SI_ERR"
shape_all "clean + bad" tests/bin/selfimpl.js
lacks "clean + bad" "$SI_OUT" "tests/bin/clean.js"
case_end

case_begin "si-unsupported-language-warns" "bin/check-self-impl.sh"
si "$REPO_CLI" tests/bin/selfimpl.test.ts
expect_rc "unsupported" 0 "$SI_RC" "$SI_OUT $SI_ERR"
assert_eq "$SI_OUT" "WARN: tests/bin/selfimpl.test.ts: harness self-implementation not checked (no caseEmbedRules) code=SELF_IMPL_CHECK_UNSUPPORTED"
case_end

case_begin "si-pester-runtime-unavailable-warns" "bin/check-self-impl.sh"
SI_PATH="$(no_runtime_path pwsh)"
if [ -z "$SI_PATH" ]; then
  skip "pester runtime: could not build a PATH without pwsh"
else
  si "$REPO_CLI" tests/bin/selfimpl.Tests.ps1
  expect_rc "no pwsh" 0 "$SI_RC" "$SI_OUT $SI_ERR"
  assert_eq "$SI_OUT" "WARN: tests/bin/selfimpl.Tests.ps1: harness self-implementation not checked (pwsh is not installed) code=SELF_IMPL_CHECK_RUNTIME_UNAVAILABLE"
fi
SI_PATH=""
case_end

case_begin "si-pytest-runtime-unavailable-warns" "bin/check-self-impl.sh"
SI_PATH="$(no_runtime_path uv)"
if [ -z "$SI_PATH" ]; then
  skip "pytest runtime: could not build a PATH without uv"
else
  si "$REPO_CLI" tests/bin/test_selfimpl.py
  expect_rc "no uv" 0 "$SI_RC" "$SI_OUT $SI_ERR"
  assert_eq "$SI_OUT" "WARN: tests/bin/test_selfimpl.py: harness self-implementation not checked (uv is not installed) code=SELF_IMPL_CHECK_RUNTIME_UNAVAILABLE"
fi
SI_PATH=""
case_end

case_begin "si-infra-error-exit-2" "bin/check-self-impl.sh"
# A checkout holding the CLI alone: its lib is unreachable, which is an infra error, not a verdict.
_lone="$TMPBASE/lone-cli"
mkdir -p "$_lone/bin"
if cp "$SI_CLI_REAL" "$_lone/bin/check-self-impl.sh" 2>/dev/null; then
  SI_CLI="$_lone/bin/check-self-impl.sh"
  si "$REPO_CLI" tests/bin/selfimpl.sh
  expect_rc "lib unreachable" 2 "$SI_RC" "$SI_OUT $SI_ERR"
  lacks "lib unreachable" "$SI_OUT" "code=SELF_IMPLEMENTED_HARNESS"
  SI_CLI="$SI_CLI_REAL"
else
  fail "lib unreachable" "cannot copy $SI_CLI_REAL"
fi
case_end
