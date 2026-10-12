#!/usr/bin/env bash
# Tests: bin/lib/native-path.sh, bin/github-issues/issue-create.sh, bin/github-issues/issue-body-append.sh, bin/github-issues/reopen-with-update.sh, bin/lib/github-contents-write.sh, bin/lib/github-git-data-write.sh, bin/github-issues/migration/migrate-history.sh, bin/github-issues/migration/migrate-todo.sh
# Tags: github, gh, windows-path, msys, scope:issue-specific, TL1, TL2
# Issue #2221 Change 3: under MSYS_NO_PATHCONV=1 native gh.exe cannot read an MSYS file path; native_path
# converts once at the gh boundary (cygpath -m when present, else or on failure unchanged, `-` untouched).
# A recording gh stub shows what issue-create.sh and issue-body-append.sh actually pass as --body-file.
# TL3 gap (what this test does NOT catch):
# - The real gh.exe opening the converted --body-file/--input path (the stub only records argv).
# Closest-to-action mitigation: none — no check-verification-gate category covers gh; check by hand on Git Bash.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/lib/script-checkout-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"

GNP_TMP="$(make_tmp)"
readonly GNP_TMP
trap 'rm -rf "$GNP_TMP"' EXIT
harness_isolate "$GNP_TMP"
export HOME="$GNP_TMP/home"
export USERPROFILE="$HOME"
mkdir -p "$HOME"
unset CLAUDE_CODE_SESSION_ID CLAUDECODE REPO_OVERRIDE 2>/dev/null || true

LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/native-path.sh"
EMPTY_BIN="$GNP_TMP/empty-bin"
FAILING_BIN="$GNP_TMP/failing-cygpath-bin"
mkdir -p "$EMPTY_BIN" "$FAILING_BIN"
# A cygpath that always fails and records each call, so the fallback and the `-` bypass are visible.
printf '#!/bin/sh\necho "$*" >> "%s/cygpath-calls"\nexit 1\n' "$GNP_TMP" > "$FAILING_BIN/cygpath"
chmod +x "$FAILING_BIN/cygpath"
HAVE_CYGPATH=0
command -v cygpath >/dev/null 2>&1 && HAVE_CYGPATH=1

# np_call <PATH> <input> — prints native_path's output; exit 99 when the lib cannot be sourced.
np_call() {
  run_with_timeout 10 env PATH="$1" "$BASH" -c '. "$1" || exit 99; native_path "$2"' _ "$LIB" "$2"
}

# np_row <label> <PATH> <input> <mode> <want> — mode: eq (exact) or re (extended regex).
np_row() {
  local label="$1" p="$2" in="$3" mode="$4" want="$5" got rc ok=0
  got="$(np_call "$p" "$in" 2>"$GNP_TMP/np.err")"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    case "$mode" in
      eq) [ "$got" = "$want" ] && ok=1 ;;
      re) printf '%s' "$got" | grep -qE "$want" && ok=1 ;;
    esac
  fi
  if [ "$ok" -eq 1 ]; then
    pass "native_path[$label] '$in' -> '$got'"
  else
    fail "native_path[$label] '$in'" "rc=$rc got='$got' want($mode)='$want' err=$(head -c 200 "$GNP_TMP/np.err")"
  fi
}

case_begin "native-path-table" "bin/lib/native-path.sh"
if [ "$HAVE_CYGPATH" -eq 1 ]; then
  np_row "cygpath dash" "$PATH" "-" eq "-"
  np_row "cygpath relative" "$PATH" "body.md" eq "body.md"
  np_row "cygpath dash-led relative" "$PATH" "-x.md" eq "-x.md"
  np_row "cygpath msys abs" "$PATH" "/tmp/x" re '^[A-Za-z]:/.*/x$'
  np_row "cygpath mixed abs" "$PATH" "C:/x" eq "C:/x"
  np_row "cygpath space" "$PATH" "/tmp/a b/c.md" re '^[A-Za-z]:/.*/a b/c\.md$'
else
  skip "native_path with a real cygpath: not on this host (TL3 gap: Windows Git Bash only)"
fi
for _in in "-" "body.md" "/tmp/x" "C:/x" "/tmp/a b/c.md"; do
  np_row "no cygpath" "$EMPTY_BIN" "$_in" eq "$_in"
done
rm -f "$GNP_TMP/cygpath-calls"
for _in in "/tmp/x" "/tmp/a b/c.md"; do
  np_row "cygpath fails" "$FAILING_BIN" "$_in" eq "$_in"
done
if [ -s "$GNP_TMP/cygpath-calls" ]; then
  pass "native_path: a failing cygpath was really consulted before the fallback"
else
  fail "native_path: the failing cygpath was never called" "the fallback rows above passed without exercising cygpath"
fi
rm -f "$GNP_TMP/cygpath-calls"
np_row "dash never converted" "$FAILING_BIN" "-" eq "-"
if [ "$(np_call "$FAILING_BIN" "-" 2>/dev/null)" = "-" ] && [ ! -e "$GNP_TMP/cygpath-calls" ]; then
  pass "native_path: '-' (stdin) never reaches cygpath"
else
  fail "native_path: '-' was passed to cygpath" "$(cat "$GNP_TMP/cygpath-calls")"
fi
# A dash-led path other than `-` is a path, not a cygpath option: it must follow `--`.
np_row "no cygpath dash-led" "$EMPTY_BIN" "-x.md" eq "-x.md"
rm -f "$GNP_TMP/cygpath-calls"
np_row "cygpath fails dash-led" "$FAILING_BIN" "-x.md" eq "-x.md"
if grep -qE -- '(^| )-- -x\.md$' "$GNP_TMP/cygpath-calls" 2>/dev/null; then
  pass "native_path: '-x.md' reaches cygpath only after '--', never as an option"
else
  fail "native_path: '-x.md' not passed after '--'" "calls=[$(cat "$GNP_TMP/cygpath-calls" 2>/dev/null)]"
fi
case_end

# ---------------------------------------------------------------- gh integration
# A checkout copy whose is-github-dotcom-remote says non-GitHub (skips Phase 0a label repair).
# The copy holds tracked files only, so the lib under test is copied in when present.
CO="$GNP_TMP/co"
script_checkout_fixture_copy "$CO" bin >/dev/null 2>&1 || fail "fixture" "checkout copy failed"
[ -f "$LIB" ] && cp "$LIB" "$CO/bin/lib/native-path.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$CO/bin/is-github-dotcom-remote"
chmod +x "$CO/bin/is-github-dotcom-remote"
: > "$CO/.private-info-allowlist"
: > "$CO/.private-info-blocklist"
STUB_BIN="$GNP_TMP/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  auth\ status*) echo "scopes: 'project', 'repo'"; exit 0 ;;
  issue\ view*) echo "ORIGINAL body"; exit 0 ;;
esac
printf '%s\n' "$@" > "$GNP_GH_LOG"
case "$*" in issue\ create*) echo "https://github.com/example/repo/issues/7" ;; esac
exit 0
GH
chmod +x "$STUB_BIN/gh"
export GNP_GH_LOG="$GNP_TMP/gh-args"
mkdir -p "$GNP_TMP/body dir"
BODY_FILE="$GNP_TMP/body dir/body.md"
printf 'ordinary body text\n' > "$BODY_FILE"

# is_abs_path <p> — POSIX absolute or drive-letter absolute (gh resolves a relative one against its cwd).
is_abs_path() { case "$1" in /*|[A-Za-z]:/*|[A-Za-z]:\\*) return 0 ;; esac; return 1; }

# recorded_body_file — the argument after --body-file in the last recorded gh call.
recorded_body_file() { awk 'prev == "--body-file" { print; exit } { prev = $0 }' "$GNP_GH_LOG" 2>/dev/null; }

# gh_check <label> <rc> <input path> — the recorded --body-file is native (cygpath host) or unchanged.
gh_check() {
  local label="$1" rc="$2" in="$3" got
  got="$(recorded_body_file)"
  if [ "$HAVE_CYGPATH" -eq 1 ]; then
    if [ "$rc" -eq 0 ] && printf '%s' "$got" | grep -qE '^[A-Za-z]:/'; then
      pass "$label: --body-file reaches gh in native form ($got)"
    else
      fail "$label: --body-file not native" "rc=$rc got='$got' (want ^[A-Za-z]:/)"
    fi
  elif [ "$rc" -eq 0 ] && [ "$got" = "$in" ]; then
    pass "$label: without cygpath --body-file is passed unchanged"
  else
    fail "$label: without cygpath" "rc=$rc got='$got' want='$in'"
  fi
}

case_begin "issue-create-body-file" "bin/github-issues/issue-create.sh"
rm -f "$GNP_GH_LOG"
cd "$GNP_TMP" || exit 1
PATH="$STUB_BIN:$PATH" MSYS_NO_PATHCONV=1 ISSUE_CREATE_SKIP_SCHEMA=1 run_with_timeout 60 bash "$CO/bin/github-issues/issue-create.sh" \
  --title "ordinary title" --body-file "$BODY_FILE" >"$GNP_TMP/ic.out" 2>"$GNP_TMP/ic.err"
IC_RC=$?
[ -s "$GNP_GH_LOG" ] || fail "issue-create: gh was not reached" "rc=$IC_RC err=$(head -c 400 "$GNP_TMP/ic.err")"
gh_check "issue-create" "$IC_RC" "$BODY_FILE"
case_end

case_begin "issue-body-append-body-file" "bin/github-issues/issue-body-append.sh"
rm -f "$GNP_GH_LOG"
PATH="$STUB_BIN:$PATH" MSYS_NO_PATHCONV=1 run_with_timeout 60 bash "$CO/bin/github-issues/issue-body-append.sh" \
  --issue 7 --note "ordinary note" >"$GNP_TMP/iba.out" 2>"$GNP_TMP/iba.err"
IBA_RC=$?
IBA_IN="$(recorded_body_file)"
if [ "$HAVE_CYGPATH" -eq 1 ]; then
  gh_check "issue-body-append" "$IBA_RC" "$IBA_IN"
elif [ "$IBA_RC" -eq 0 ] && is_abs_path "$IBA_IN"; then
  pass "issue-body-append: without cygpath the absolute mktemp path is passed as-is ($IBA_IN)"
else
  fail "issue-body-append" "rc=$IBA_RC recorded='$IBA_IN' err=$(head -c 400 "$GNP_TMP/iba.err")"
fi
case_end

# ---------------------------------------------------------------- sibling audit (static)
# Every gh file-path argument of the audited siblings goes through native_path (CPR-ORTH).
case_begin "sibling-gh-file-args" "bin/lib/native-path.sh"
AUDITED="bin/github-issues/issue-create.sh bin/github-issues/issue-body-append.sh
bin/github-issues/reopen-with-update.sh bin/lib/github-contents-write.sh
bin/lib/github-git-data-write.sh bin/github-issues/migration/migrate-history.sh
bin/github-issues/migration/migrate-todo.sh"
for rel in $AUDITED; do
  f="$SCRIPT_CHECKOUT_ROOT/$rel"
  raw="$(grep -cE -- '--(body-file|input) "\$[A-Za-z_{]' "$f" 2>/dev/null)"
  wrapped="$(grep -cE -- '--(body-file|input) "\$\(native_path ' "$f" 2>/dev/null)"
  if [ -f "$f" ] && [ "${raw:-0}" -eq 0 ] && [ "${wrapped:-0}" -ge 1 ] && grep -q 'native-path\.sh' "$f"; then
    pass "$rel: every gh --body-file/--input path goes through native_path"
  else
    fail "$rel" "unwrapped=${raw:-?} wrapped=${wrapped:-?} sources-lib=$(grep -q 'native-path\.sh' "$f" 2>/dev/null && echo y || echo n)"
  fi
done
# Discovery: every bin/ file with a non-comment line invoking `gh ` with --body-file/--input must be
# audited above, so a new gh file-path call site cannot bypass native_path unnoticed.
GH_SCAN="$(cd "$SCRIPT_CHECKOUT_ROOT" && grep -rlE '^[^#]*(^|[^A-Za-z0-9_.-])gh [^#]*--(body-file|input)( |=|$)' bin | sort -u)"
GH_UNAUDITED="$(comm -23 <(printf '%s\n' "$GH_SCAN") <(printf '%s\n' $AUDITED | sort -u))"
if [ -n "$GH_SCAN" ] && [ -z "$GH_UNAUDITED" ]; then
  pass "bin/ scan: all $(printf '%s\n' "$GH_SCAN" | wc -l | tr -d ' ') gh --body-file/--input files are audited"
else
  fail "bin/ scan: gh --body-file/--input call sites outside the audited list" "unaudited=[$GH_UNAUDITED] scanned=[$GH_SCAN]"
fi
case_end

echo ""
echo "fix-gh-native-path: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
