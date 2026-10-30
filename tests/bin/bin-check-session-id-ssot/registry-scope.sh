# RS (#2411): the tombstone guard takes its isolation scope (tlr_match on tests/<dir>/** incl. tests/lib,
# plus each helperLibrary.path) and clear-line form (envClearLine) from the registry;
# an unreachable part fails closed. Sourced by tests/bin/bin-check-session-id-ssot.sh, which hands
# in the retired names as L_RETIRED_SID / L_RETIRED_ENV. RS3-RS6 assume the guard copy resolves the
# registry loader from its own location. Contract: docs/architecture/claude-code/test-language-registry.md.
# shellcheck shell=bash

# shellcheck source=../../lib/test-language-registry-fixture.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/test-language-registry-fixture.sh"
# shellcheck source=../../lib/node-entry-sandbox.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/node-entry-sandbox.sh"

rs_np() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }

# rs_checkout <name> <js> — registry checkout + guard copy (+ its path tables); <js> edits table t (E(id) = entry). Sets RS_CO.
RS_CO=""
rs_checkout() {
  RS_CO="$TMPDIR_BASE/co-$1"
  if ! install_test_language_registry "$RS_CO" "$SCRIPT_CHECKOUT_ROOT" 2>/dev/null; then
    fail "RS/$1: registry checkout installed"; RS_CO=""; return 1
  fi
  # #2507: the guard execs bin/check-session-id-ssot/main.js and requires each registered envClearLine
  # part, whose matcher loads hooks/lib/ere by a computed path.
  node_entry_sandbox_copy "$RS_CO" bin/check-session-id-ssot.sh hooks/lib/test-gates/parts/env-clear/{bash,js,pester,pytest}.js \
    hooks/lib/ere/{translate,longest}.js \
    || { fail "RS/$1: guard copied"; RS_CO=""; return 1; }
  mkdir -p "$RS_CO/bin/check-session-id-ssot" \
    && cp "$SCRIPT_CHECKOUT_ROOT/bin/check-session-id-ssot/path-tables.txt" "$RS_CO/bin/check-session-id-ssot/path-tables.txt" \
    || { fail "RS/$1: path tables copied"; RS_CO=""; return 1; }
  if ! node -e '
    const fs = require("fs");
    const p = process.argv[1];
    const t = JSON.parse(fs.readFileSync(p, "utf8"));
    const E = (id) => t.entries.find((e) => e.id === id);
    new Function("t", "E", process.argv[2])(t, E);
    fs.writeFileSync(p, JSON.stringify(t, null, 2) + "\n");
  ' "$(rs_np "$RS_CO/hooks/lib/test-language-registry.json")" "$2" 2>/dev/null; then
    fail "RS/$1: registry edited"; RS_CO=""; return 1
  fi
}

# rs_run_co <fixture-relpaths...> — run_guard with the checkout's guard copy.
rs_run_co() {
  local saved="$GUARD"
  GUARD="$RS_CO/bin/check-session-id-ssot.sh"
  run_guard "$FIXTURE" "$@"
  GUARD="$saved"
}

# rs_tlr <label> <want> <snippet run after tlr_load in RS_CO> — the edit reached the bash loader.
rs_tlr() {
  local got
  got="$(bash -c '. "$1/bin/lib/test-language-registry.sh" 2>/dev/null || exit 3; tlr_load 2>/dev/null || exit 4; eval "$2"' _ "$RS_CO" "$3" 2>&1)"
  if [[ "$got" == "$2" ]]; then pass "$1"; else fail "$1: want=[$2] got=[$got]"; fi
}

RS_UNSET="unset $L_RETIRED_SID $L_RETIRED_ENV"
RS_JS_DELETE="delete process.env.$L_RETIRED_SID;"
RS_PS_REMOVE="Remove-Item -Path Env:$L_RETIRED_SID -ErrorAction SilentlyContinue"
RS_PY_POP="os.environ.pop(\"$L_RETIRED_SID\", None)"

# RS1: scope the registry keeps (pin, green before and after).
make_fixture rs1
add_file tests/lib/harness.sh "$RS_UNSET"
add_file tests/a/b/c/rs-deep.Tests.ps1 "$RS_PS_REMOVE"
add_file tests/a/b/c/test_rs_deep.py "$RS_PY_POP"
add_file tests/a/b/c/rs-deep.js "$RS_JS_DELETE"
run_guard "$FIXTURE" tests/lib/harness.sh tests/a/b/c/rs-deep.Tests.ps1 tests/a/b/c/test_rs_deep.py tests/a/b/c/rs-deep.js
expect_rc "RS1 (bash helperLibrary tests/lib/harness.sh and deep-nested test files pass)" 0
expect_hits "RS1b (none of them is reported)" "tests/" 0

# RS2: control — the guard copy in an unedited checkout keeps today's verdicts.
if rs_checkout control 'void t;'; then
  make_fixture rs2
  add_file tests/hooks/rs-control.sh "$RS_UNSET" "# $L_RETIRED_ENV named in a comment"
  rs_run_co tests/hooks/rs-control.sh
  expect_rc "RS2 (guard copy in an unedited checkout: comment still fails)" 1
  expect_hits "RS2b (unset line passes in the checkout)" "tests/hooks/rs-control.sh:1:" 0
  expect_hits "RS2c (comment line is reported in the checkout)" "tests/hooks/rs-control.sh:2:" 1
fi

# RS3: bash envClearLine names a function its part file does not define -> the unset line is reported.
if rs_checkout bash-fn-absent 'E("bash").envClearLine = { file: "hooks/lib/test-gates/parts/env-clear/bash.js", function: "envClearLineAbsent" };'; then
  rs_tlr "RS3-pre (the edited envClearLine.function reaches tlr_field)" "envClearLineAbsent" 'tlr_field bash envClearLine.function'
  make_fixture rs3
  add_file tests/hooks/rs-unset.sh "$RS_UNSET"
  rs_run_co tests/hooks/rs-unset.sh
  expect_rc "RS3 (unreachable bash clear-line part fails closed)" 1
  expect_hits "RS3b (the unset line is reported)" "tests/hooks/rs-unset.sh:1:" 1
fi

# RS4: js envClearLine names a part file that does not exist -> the delete line is reported.
if rs_checkout js-file-missing 'E("js").envClearLine = { file: "hooks/lib/test-gates/parts/env-clear/no-such-js-part.js", function: "envClearLine" };'; then
  rs_tlr "RS4-pre (the edited envClearLine.file reaches tlr_field)" "hooks/lib/test-gates/parts/env-clear/no-such-js-part.js" 'tlr_field js envClearLine.file'
  make_fixture rs4
  add_file tests/hooks/rs-delete.js "$RS_JS_DELETE"
  rs_run_co tests/hooks/rs-delete.js
  expect_rc "RS4 (missing js clear-line part file fails closed)" 1
  expect_hits "RS4b (the delete line is reported)" "tests/hooks/rs-delete.js:1:" 1
fi

# RS5: the isolation file set follows the pytest entry's patterns, not a hardcoded test_*.py.
if rs_checkout pytest-patterns 'E("pytest").patterns = ["check_*.py"];'; then
  rs_tlr "RS5-pre (check_rs.py routes to pytest in the checkout)" "pytest" 'tlr_match check_rs.py; printf "%s\n" "$TLR_ID"'
  make_fixture rs5
  add_file tests/hooks/check_rs.py "$RS_PY_POP"
  add_file tests/hooks/test_rs.py "$RS_PY_POP"
  rs_run_co tests/hooks/check_rs.py tests/hooks/test_rs.py
  expect_hits "RS5 (a file the pytest patterns now route is an isolation file)" "tests/hooks/check_rs.py:1:" 0
  expect_hits "RS5b (test_rs.py no longer routes to pytest and is reported)" "tests/hooks/test_rs.py:1:" 1
fi

# RS6: a helper whose basename matches no pattern (*.ps1 vs *.Tests.ps1) is in scope only as the
# pester entry's helperLibrary.path.
if rs_checkout pester-helper-path 'E("pester").helperLibrary.path = "tests/lib/helper2.ps1";'; then
  rs_tlr "RS6-pre (the edited helperLibrary.path reaches tlr_field)" "tests/lib/helper2.ps1" 'tlr_field pester helperLibrary.path'
  make_fixture rs6
  add_file tests/lib/helper2.ps1 "$RS_PS_REMOVE"
  add_file tests/lib/harness.ps1 "$RS_PS_REMOVE"
  rs_run_co tests/lib/helper2.ps1 tests/lib/harness.ps1
  expect_hits "RS6 (the registered helperLibrary.path is an isolation file)" "tests/lib/helper2.ps1:1:" 0
  expect_hits "RS6b (tests/lib/harness.ps1, no longer registered, is reported)" "tests/lib/harness.ps1:1:" 1
fi
