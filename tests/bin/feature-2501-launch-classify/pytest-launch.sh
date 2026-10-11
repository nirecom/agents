# tests/bin/feature-2501-launch-classify/pytest-launch.sh
# Tests: bin/lib/run-all-launch.sh
# Tags: TL2, bin, run-all, launch, pytest, uv, scope:issue-specific
# shellcheck shell=bash
# The REAL registry pytest entry through run_all_exec, with a fake `uv` first on PATH (no network, no
# real uv): one timer per file, so the launcher calls uv exactly once, with the entry's command argv,
# and a failing uv is the test's own FAIL — supplying pytest is the installer's job (dotfileslink
# pre-fetches it), not a launch-time check. Sourced by the dispatcher.

echo ""
echo "=== run_all_exec: real pytest entry, one uv invocation ==="

CPY="$TMPBASE/co-pylaunch"
fx_co "$CPY" || fail "fixture checkout (pytest launch)" "fx_co failed"
FUV="$TMPBASE/fakeuv"
mkdir -p "$FUV/bin"
# The fake logs each argv ("|"-joined, argv0 dropped) and exits the code in <fake>/uv.rc.
printf '%s\n' '#!/usr/bin/env bash' "d='$FUV'" '( IFS="|"; printf "%s\n" "$*" ) >>"$d/uv.log"' \
  'exit "$(cat "$d/uv.rc")"' >"$FUV/bin/uv"
chmod +x "$FUV/bin/uv"
printf '%s\n' 'def test_x():' '    pass' >"$CPY/tests/bin/test_launch_2501.py"
# The registry command ["uv","run","--no-project","--with","pytest>={minVersion}","python","{wrapper}",
# "{nativePath}","{minVersion}"], substituted: {wrapper} is the checkout's wrapper in native form.
PY_WANT="run|--no-project|--with|pytest>=7.0|python|$(np "$(cd "$CPY" && pwd)/bin/lib/test-wrappers/pytest.py")|$(np "$CPY/tests/bin/test_launch_2501.py")|7.0"

# pyrun <tag> <uv-rc> — one run_all_exec of the .py file with the fake uv first on PATH.
pyrun() {
  local saved="$PATH"
  rm -f "$FUV/uv.log"
  printf '%s\n' "$2" >"$FUV/uv.rc"
  mkdir -p "$TMPBASE/res-$1"
  PATH="$FUV/bin:$PATH"
  rae "$1" "$CPY" "$CPY/tests/bin/test_launch_2501.py" "$TMPBASE/res-$1"
  PATH="$saved"
}
# uv_count — how many times the fake uv ran.
uv_count() {
  local n=0 line
  if [ -f "$FUV/uv.log" ]; then
    while IFS= read -r line; do n=$((n + 1)); done <"$FUV/uv.log"
  fi
  printf '%s' "$n"
}
# uv_import_lines — how many logged argvs carry an `import pytest` argument (a pre-launch probe).
uv_import_lines() {
  local n=0 line
  if [ -f "$FUV/uv.log" ]; then
    while IFS= read -r line; do
      case "|$line|" in *"|import pytest|"*) n=$((n + 1)) ;; esac
    done <"$FUV/uv.log"
  fi
  printf '%s' "$n"
}
uv_first() {
  local line
  if [ -f "$FUV/uv.log" ] && IFS= read -r line <"$FUV/uv.log"; then printf '%s' "$line"; else printf '<none>'; fi
}

case_begin "real-pytest-entry-runs-uv-once-with-the-command-argv" "bin/lib/run-all-launch.sh"
pyrun py-pass 0
assert_eq "uv exit 0: $(rae_sum py-pass)" "uv exit 0: rc=0 state=PASS"
assert_eq "uv exit 0: uv invocations=$(uv_count)" "uv exit 0: uv invocations=1"
assert_eq "uv exit 0: uv argv=$(uv_first)" "uv exit 0: uv argv=$PY_WANT"
assert_eq "uv exit 0: argvs with 'import pytest'=$(uv_import_lines)" "uv exit 0: argvs with 'import pytest'=0"
case_end

# A uv that cannot supply pytest is no longer told apart before launch: the run is the test's FAIL.
case_begin "real-pytest-entry-failing-uv-is-fail" "bin/lib/run-all-launch.sh"
pyrun py-fail 1
K="$TMPBASE/rae-py-fail.kv"
assert_eq "uv exit 1: $(rae_sum py-fail) launched=$(kv launched "$K")" "uv exit 1: rc=1 state=FAIL launched=1"
assert_eq "uv exit 1: uv invocations=$(uv_count)" "uv exit 1: uv invocations=1"
assert_eq "uv exit 1: argvs with 'import pytest'=$(uv_import_lines)" "uv exit 1: argvs with 'import pytest'=0"
assert_eq "uv exit 1: marker=$(file_text "$TMPBASE/res-py-fail/unrunnable")" "uv exit 1: marker=<absent>"
case_end
