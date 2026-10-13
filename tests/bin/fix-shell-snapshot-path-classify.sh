#!/usr/bin/env bash
# Tests: bin/shell-snapshot-path-classify.js
# Tags: sweep, shell-snapshots, cli, classifier, windows-path, scope:issue-specific, TL2
# Issue #2221: the batch classifier the sweep runs once per invocation. One `<verdict>\t<name>`
# line per argument, in argument order, `unreadable` for a file it cannot read, always exit 0
# for file arguments and exit 2 for an argument error. Verdicts come from
# hooks/lib/shell-snapshot-path.js (tested in tests/hooks/fix-shell-snapshot-windows-path/).
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

CLS_TMP="$(make_tmp)"
readonly CLS_TMP
trap 'rm -rf "$CLS_TMP"' EXIT
harness_isolate "$CLS_TMP"
export HOME="$CLS_TMP/home"
export USERPROFILE="$HOME"
mkdir -p "$HOME"
unset CLAUDE_CODE_SESSION_ID CLAUDECODE 2>/dev/null || true

CLI="$(np "$SCRIPT_CHECKOUT_ROOT/bin/shell-snapshot-path-classify.js")"
D="$CLS_TMP/snaps"
mkdir -p "$D/subdir"
cd "$D" || exit 1

PRE=$'# Snapshot file\nunset __conda_setup 2>/dev/null\n'
snap() { printf "%sexport PATH='%s'\nexport FOO=1\n" "$PRE" "$2" > "$1"; }
snap ok.sh '/usr/bin:/bin'
snap wf.sh 'C:\Windows\System32;C:\Windows'
snap wu.sh 'C:\a;relative\dir'
snap wu-colon.sh 'C:\repo\dotfiles/bin:/c/x'
snap mc.sh '/definitely/not:/bin2'
snap 'with space.sh' 'C:\Windows'
printf "%sexport PATH='C:\\\\a;C:\\\\b'\r\nexport FOO=1\r\n" "$PRE" > crlf.sh
printf "%sexport PATH='git fetch Claude session sync ...\n/usr/bin:/bin'\n" "$PRE" > unparsed.sh
printf '%salias ll="ls -l"\n' "$PRE" > nopath.sh
# A shell-escaped quote ('\'') ends the first '...' early, so the value is not a simple one.
snap quote.sh "C:\\Users\\O'\\''Brien\\bin;C:\\Windows"

# cls_run <args...> — sets CLS_OUT (CR stripped), CLS_RC.
cls_run() {
  CLS_OUT="$(run_with_timeout 30 node "$CLI" "$@" 2>"$CLS_TMP/err")"
  CLS_RC=$?
  CLS_OUT="${CLS_OUT//$'\r'/}"
}

case_begin "verdict-per-file" "bin/shell-snapshot-path-classify.js"
cls_run -- ok.sh wf.sh wu.sh wu-colon.sh mc.sh 'with space.sh' crlf.sh unparsed.sh quote.sh nopath.sh missing.sh subdir
WANT="$(printf '%s\t%s\n' ok ok.sh windows-form wf.sh windows-unrepairable wu.sh windows-unrepairable wu-colon.sh missing-core mc.sh windows-form 'with space.sh' windows-form crlf.sh unparsed unparsed.sh unparsed quote.sh no-path-line nopath.sh unreadable missing.sh unreadable subdir)"
if [ "$CLS_RC" -eq 0 ] && [ "$CLS_OUT" = "$WANT" ]; then
  pass "one verdict<TAB>name line per argument, in order, unparsed for an escaped quote, unreadable for a missing file and a directory, exit 0"
else
  fail "verdict lines" "rc=$CLS_RC out=[$CLS_OUT] err=$(head -c 300 "$CLS_TMP/err" 2>/dev/null)"
fi
case_end

case_begin "read-only" "bin/shell-snapshot-path-classify.js"
cp wf.sh "$CLS_TMP/wf.orig"
cls_run -- wf.sh
if [ "$CLS_RC" -eq 0 ] && cmp -s wf.sh "$CLS_TMP/wf.orig" && [ "$CLS_OUT" = "$(printf 'windows-form\twf.sh')" ]; then
  pass "classifying never rewrites the snapshot (no repair from the sweep side)"
else
  fail "read-only" "rc=$CLS_RC out=[$CLS_OUT]"
fi
case_end

case_begin "no-file-args" "bin/shell-snapshot-path-classify.js"
cls_run --
if [ -f "$CLI" ] && [ "$CLS_RC" -eq 0 ] && [ -z "$CLS_OUT" ]; then
  pass "'--' with no file arguments: exit 0, no verdict lines"
else
  fail "no file args" "rc=$CLS_RC (want 0) out=[$CLS_OUT] cli-present=$([ -f "$CLI" ] && echo y || echo n)"
fi
case_end

case_begin "unreadable-permission" "bin/shell-snapshot-path-classify.js"
# chmod cannot deny read on win32 (MSYS) or to root; the [ -r ] probe catches any other such host.
case "${OSTYPE:-}" in msys*|cygwin*) CLS_PERM_OK=0 ;; *) CLS_PERM_OK=1 ;; esac
[ "$(id -u 2>/dev/null)" = "0" ] && CLS_PERM_OK=0
snap noread.sh '/usr/bin:/bin'
chmod 000 noread.sh
[ -r noread.sh ] && CLS_PERM_OK=0
if [ "$CLS_PERM_OK" -eq 1 ]; then
  cls_run -- noread.sh
  if [ "$CLS_RC" -eq 0 ] && [ "$CLS_OUT" = "$(printf 'unreadable\tnoread.sh')" ]; then
    pass "a file without read permission -> unreadable, exit 0"
  else
    fail "unreadable permission" "rc=$CLS_RC out=[$CLS_OUT]"
  fi
else
  skip "unreadable permission: chmod 000 cannot deny read here (win32 or root)"
fi
chmod 644 noread.sh
case_end

case_begin "argument-error" "bin/shell-snapshot-path-classify.js"
if [ -f "$CLI" ]; then
  cls_run --bogus-flag ok.sh
  if [ "$CLS_RC" -eq 2 ] && [ -z "$CLS_OUT" ]; then
    pass "an unknown flag is an argument error: exit 2, no verdict lines"
  else
    fail "argument error" "rc=$CLS_RC (want 2) out=[$CLS_OUT]"
  fi
else
  fail "argument error" "$CLI not found"
fi
case_end

echo ""
echo "fix-shell-snapshot-path-classify: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
