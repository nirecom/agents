# Shared fixture repo and helpers for the bin/check-test-language-match.sh suites
# (tests/bin/feature-2502-test-language-match.sh, tests/bin/feature-2502-case-addition.sh).
# The sourcing entrypoint has loaded tests/lib/harness.sh and set SCRIPT_CHECKOUT_ROOT.
# shellcheck shell=bash

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR GIT_DIR GIT_WORK_TREE

LM_CLI_REAL="$SCRIPT_CHECKOUT_ROOT/bin/check-test-language-match.sh"
LM_LIB="$SCRIPT_CHECKOUT_ROOT/bin/check-test-language-match/cli.js"
LM_CLI="$LM_CLI_REAL"
BODIES="$TMPBASE/bodies"
mkdir -p "$BODIES"

REPO="$TMPBASE/repo"
harness_git_init "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
git -C "$REPO" config core.autocrlf false
mkdir -p "$REPO/tests/lib" "$REPO/tests/bin" "$REPO/bin" "$REPO/docs" "$REPO/hooks/lib"
for _ext in sh ps1 py js; do printf '\n' > "$REPO/tests/lib/harness.$_ext"; done
for _f in bin/foo.js bin/bar.js bin/foo.sh bin/bar.sh bin/a.sh hooks/x.js docs/x.md hooks/lib/x.json; do printf '\n' > "$REPO/$_f"; done
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -q -m init >/dev/null 2>&1

# The marker words are split so this file's own reader never takes the fixture lines for markers.
MB="case""_begin"
ME="case""_end"

# body <name> <tags> <tests-csv> [<case>=<target>[=<echo-word>]]... — a bash test body in
# $BODIES/<name>. Each case echoes its own name unless a third field gives another word.
body() {
  local out="$BODIES/$1" tags="$2" tests="$3" c n r t w
  shift 3
  printf '%s\n' '#!/usr/bin/env bash' "# Tests: $tests" "# Tags: $tags" \
    'source "$(dirname "$0")/../../tests/lib/harness.sh"' > "$out"
  for c in "$@"; do
    n="${c%%=*}"; r="${c#*=}"; t="${r%%=*}"; w="$n"
    [ "$r" != "$t" ] && w="${r#*=}"
    printf '%s "%s" "%s"\necho %s\n%s\n' "$MB" "$n" "$t" "$w" "$ME" >> "$out"
  done
}

# lm <rel> <work-body> [<head-body>] — the CLI from the repo root on a temp copy of
# <work-body>, with --rel <rel>, and --head on a temp copy of <head-body> when given.
# Sets LM_RC LM_OUT LM_ERR.
LM_RC=0; LM_OUT=""; LM_ERR=""
LM_N=0
lm() {
  local rel="$1" work="$2" head="${3:-}" d base
  local -a args=(--rel "$rel")
  LM_N=$((LM_N + 1))
  d="$TMPBASE/w$LM_N"
  base="${rel##*/}"
  mkdir -p "$d/head"
  cp "$BODIES/$work" "$d/$base"
  if [ -n "$head" ]; then
    cp "$BODIES/$head" "$d/head/$base"
    args+=(--head "$d/head/$base")
  fi
  LM_RC=0
  (
    cd "$REPO" || exit 99
    bash "$RWT" 90 bash "$LM_CLI" "${args[@]}" "$d/$base"
  ) >"$TMPBASE/lm.out" 2>"$TMPBASE/lm.err" || LM_RC=$?
  LM_OUT="$(cat "$TMPBASE/lm.out")"
  LM_ERR="$(cat "$TMPBASE/lm.err")"
}

expect_rc() {
  if [ "$LM_RC" = "$2" ]; then pass "$1: rc=$2"; else fail "$1" "want rc=$2 got rc=$LM_RC: out=[$LM_OUT] err=[$LM_ERR]"; fi
}
# count_code <code> — lines of LM_OUT ending in code=<code>.
count_code() {
  local line n=0
  while IFS= read -r line; do
    [ "${line%" code=$1"}" != "$line" ] && n=$((n + 1))
  done <<< "$LM_OUT"
  printf '%s' "$n"
}
# expect_mismatch <label> <rel> <target> — one TEST_LANGUAGE_MISMATCH line for <target>.
expect_mismatch() {
  local line found=0
  while IFS= read -r line; do
    case "$line" in
      "HIGH: $2"*"test language bash does not match code language js of $3 (new file shape: "*") code=TEST_LANGUAGE_MISMATCH") found=1 ;;
    esac
  done <<< "$LM_OUT"
  if [ "$found" = 1 ]; then pass "$1: mismatch on $3"; else fail "$1" "no mismatch line for $3: out=[$LM_OUT] err=[$LM_ERR]"; fi
}
# expect_invalid <label> <rel> <value> — the exact INVALID_TEST_LANG_EXCEPTION line.
expect_invalid() {
  local want="HIGH: $2: invalid test-lang-exception value '$3' (allowed: text-only symmetry e2e) code=INVALID_TEST_LANG_EXCEPTION"
  case $'\n'"$LM_OUT"$'\n' in
    *$'\n'"$want"$'\n'*) pass "$1: invalid value '$3'" ;;
    *) fail "$1" "want line [$want] in out=[$LM_OUT] err=[$LM_ERR]" ;;
  esac
}
# expect_clean <label> — exit 0 and no output line at all.
expect_clean() {
  if [ "$LM_RC" = 0 ] && [ -z "$LM_OUT" ]; then pass "$1: passes silently"; else fail "$1" "want rc=0 and no output, got rc=$LM_RC out=[$LM_OUT] err=[$LM_ERR]"; fi
}
