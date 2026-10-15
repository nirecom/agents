# LX (#2411): tombstone isolation in JS, PowerShell and Python tests. A retired name passes only on a
# whole-line clear in the file's own language, in tests/<dir>/**/*.js, *.Tests.ps1, test_*.py and
# tests/lib/harness.{js,ps1,py}; any other spelling, path or cross-language form still fails.
# Sourced by tests/bin/bin-check-session-id-ssot.sh, the exempt file that owns the retired names:
# rows write them as @S@ / @E@ and L_RETIRED_SID / L_RETIRED_ENV fill them in. A trailing @CR@
# becomes a carriage return, so that file's line ends in CRLF (a Windows checkout); it must pass.
# Uniform scope: any depth under tests/<dir>/ (tests/lib included) whose basename matches a supported
# entry, or a helperLibrary.path; so a clear-only line in tests/lib/other.js passes, other.ps1/.py do not.
# shellcheck shell=bash

make_fixture lx
LX_PATHS=()
LX_WANTS=()
LX_NAMES=()
LX_POSITIVE=()
while IFS='|' read -r _lx_name _lx_path _lx_want _lx_line; do
  [[ -z "$_lx_name" || "$_lx_name" =~ ^[[:space:]]*# ]] && continue
  _lx_name="${_lx_name//[[:space:]]/}"
  _lx_path="${_lx_path//[[:space:]]/}"
  _lx_want="${_lx_want//[[:space:]]/}"
  _lx_line="${_lx_line# }"
  _lx_line="${_lx_line//@S@/$L_RETIRED_SID}"
  _lx_line="${_lx_line//@E@/$L_RETIRED_ENV}"
  _lx_line="${_lx_line//@CR@/$'\r'}"
  add_file "$_lx_path" "$_lx_line"
  LX_NAMES+=("$_lx_name")
  LX_PATHS+=("$_lx_path")
  LX_WANTS+=("$_lx_want")
  [[ "$_lx_want" == "pass" ]] && LX_POSITIVE+=("$_lx_path")
done <<'TABLE'
# name                 | path                                   | want | the one line of the file
# JS: `delete process.env.NAME;` alone on the line
js-delete-sid          | tests/hooks/js-delete-sid.js           | pass | delete process.env.@S@;
js-delete-no-semicolon | tests/hooks/js-delete-env.js           | pass | delete process.env.@E@
js-delete-indented     | tests/tests/sub/js-indented.js         | pass |     delete process.env.@S@;
js-harness-lib         | tests/lib/harness.js                   | pass |   delete process.env.@E@;
js-list-literal        | tests/hooks/js-list.js                 | fail | const R = ["@S@", "@E@"];
js-assignment          | tests/hooks/js-assign.js               | fail | process.env.@S@ = "x";
js-read-assert         | tests/hooks/js-read.js                 | fail | assert.strictEqual(process.env.@E@, undefined);
js-bracket-delete      | tests/hooks/js-bracket.js              | fail | delete process.env["@S@"];
js-trailing-comment    | tests/hooks/js-comment.js              | fail | delete process.env.@S@; // clear
js-two-on-one-line     | tests/hooks/js-two.js                  | fail | delete process.env.@S@; delete process.env.@E@;
js-comment-only        | tests/hooks/js-note.js                 | fail | // @E@ is cleared below
js-bash-unset          | tests/hooks/js-unset.js                | fail | unset @S@
js-python-pop          | tests/hooks/js-pop.js                  | fail | os.environ.pop("@S@", None)
js-crlf-windows-checkout | tests/hooks/js-crlf.js               | pass | delete process.env.@S@;@CR@
js-tests-top-level     | tests/top.js                           | fail | delete process.env.@S@;
js-tests-wrong-depth   | tests/harness.js                       | fail | delete process.env.@S@;
# tests/lib/*.js matches the js entry's *.js: a clear-only line passes there; any other use still fails.
js-lib-not-harness     | tests/lib/other.js                     | pass | delete process.env.@S@;
js-lib-list-literal    | tests/lib/other-list.js                | fail | const R = ["@S@", "@E@"];
js-bin-path            | bin/x.js                               | fail | delete process.env.@S@;
js-hooks-path          | hooks/x.js                             | fail | delete process.env.@E@;
# PowerShell: Remove-Item [-Path] Env:[\]NAME, then -ErrorAction SilentlyContinue and/or -Force
ps-path-form           | tests/hooks/ps-path.Tests.ps1          | pass | Remove-Item -Path Env:@S@ -ErrorAction SilentlyContinue
ps-bare-form           | tests/hooks/ps-bare.Tests.ps1          | pass | Remove-Item Env:@E@ -ErrorAction SilentlyContinue
ps-backslash-force     | tests/hooks/ps-bs.Tests.ps1            | pass | Remove-Item Env:\@S@ -Force
ps-both-options        | tests/hooks/ps-both.Tests.ps1          | pass | Remove-Item -Path Env:@E@ -ErrorAction SilentlyContinue -Force
ps-indented            | tests/tests/sub/ps-indented.Tests.ps1  | pass |         Remove-Item -Path Env:@S@ -ErrorAction SilentlyContinue
ps-harness-lib         | tests/lib/harness.ps1                  | pass |     Remove-Item -Path Env:@E@ -ErrorAction SilentlyContinue
ps-list-literal        | tests/hooks/ps-list.Tests.ps1          | fail | $names = @('@S@', '@E@')
ps-assignment          | tests/hooks/ps-assign.Tests.ps1        | fail | $env:@S@ = 'x'
ps-read-assert         | tests/hooks/ps-read.Tests.ps1          | fail | $env:@E@ | Should -BeNullOrEmpty
ps-set-null            | tests/hooks/ps-setnull.Tests.ps1       | fail | [Environment]::SetEnvironmentVariable('@S@', $null)
ps-other-option        | tests/hooks/ps-recurse.Tests.ps1       | fail | Remove-Item Env:@S@ -Recurse
ps-trailing-comment    | tests/hooks/ps-comment.Tests.ps1       | fail | Remove-Item Env:@S@ -ErrorAction SilentlyContinue # clear
ps-two-on-one-line     | tests/hooks/ps-two.Tests.ps1           | fail | Remove-Item Env:@S@ -ErrorAction SilentlyContinue; Remove-Item Env:@E@ -ErrorAction SilentlyContinue
ps-js-delete           | tests/hooks/ps-delete.Tests.ps1        | fail | delete process.env.@S@;
ps-crlf-windows-checkout | tests/hooks/ps-crlf.Tests.ps1        | pass | Remove-Item -Path Env:@S@ -ErrorAction SilentlyContinue@CR@
ps-not-a-tests-file    | tests/hooks/helper.ps1                 | fail | Remove-Item -Path Env:@S@ -ErrorAction SilentlyContinue
ps-lib-not-harness     | tests/lib/other.ps1                    | fail | Remove-Item -Path Env:@S@ -ErrorAction SilentlyContinue
ps-install-path        | install/x.ps1                          | fail | Remove-Item -Path Env:@S@ -ErrorAction SilentlyContinue
# Python: os.environ.pop("NAME", None) with either quote, alone on the line
py-double-quote        | tests/hooks/test_py_dq.py              | pass | os.environ.pop("@S@", None)
py-single-quote        | tests/hooks/test_py_sq.py              | pass | os.environ.pop('@E@', None)
py-indented            | tests/tests/sub/test_py_indent.py      | pass |         os.environ.pop("@E@", None)
py-harness-lib         | tests/lib/harness.py                   | pass |     os.environ.pop("@S@", None)
py-tuple-literal       | tests/hooks/test_py_list.py            | fail | _R = ("@S@", "@E@")
py-assignment          | tests/hooks/test_py_assign.py          | fail | os.environ["@S@"] = "x"
py-read-assert         | tests/hooks/test_py_read.py            | fail | assert "@E@" not in os.environ
py-pop-no-default      | tests/hooks/test_py_nodefault.py       | fail | os.environ.pop("@S@")
py-del                 | tests/hooks/test_py_del.py             | fail | del os.environ["@S@"]
py-trailing-comment    | tests/hooks/test_py_comment.py         | fail | os.environ.pop("@S@", None)  # clear
py-two-on-one-line     | tests/hooks/test_py_two.py             | fail | os.environ.pop("@S@", None); os.environ.pop("@E@", None)
py-js-delete           | tests/hooks/test_py_delete.py          | fail | delete process.env.@S@;
py-crlf-windows-checkout | tests/hooks/test_py_crlf.py          | pass | os.environ.pop("@S@", None)@CR@
py-not-a-test-file     | tests/hooks/helper.py                  | fail | os.environ.pop("@S@", None)
py-lib-not-harness     | tests/lib/other.py                     | fail | os.environ.pop("@S@", None)
py-hooks-path          | hooks/x.py                             | fail | os.environ.pop("@S@", None)
# bash keeps only its own forms
sh-js-delete           | tests/hooks/sh-delete.sh               | fail | delete process.env.@S@;
sh-python-pop          | tests/hooks/sh-pop.sh                  | fail | os.environ.pop("@S@", None)
sh-ps-remove           | tests/hooks/sh-remove.sh               | fail | Remove-Item -Path Env:@E@ -ErrorAction SilentlyContinue
TABLE

run_guard "$FIXTURE" "${LX_PATHS[@]}"
expect_rc "LX (the rejected rows make the run fail)" 1
for _lx_i in "${!LX_PATHS[@]}"; do
  _lx_hits=0
  [[ "${LX_WANTS[$_lx_i]}" == "fail" ]] && _lx_hits=1
  expect_hits "LX/${LX_NAMES[$_lx_i]} (${LX_WANTS[$_lx_i]})" "${LX_PATHS[$_lx_i]}:1:" "$_lx_hits"
done

run_guard "$FIXTURE" "${LX_POSITIVE[@]}"
expect_rc "LX-positive-only (every accepted clear line passes together)" 0
