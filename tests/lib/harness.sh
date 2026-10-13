#!/usr/bin/env bash
# tests/lib/harness.sh
# Tests: tests/lib/harness.sh
# Tags: scope:common, shared-lib
# Shared harness. Do NOT mix-source with a narrow harness
# (tests/bin/bin-concern-ledger-reducer.sh, tests/lib/clearance-hook-harness.sh):
# those set PASS=0/FAIL=0 unguarded and overwrite this harness's counts.
# case_begin/case_end targets feed the static catalog; when tests/run-all.sh launched this very
# file (RUN_ALL_RESULT_OWNER == $0), each case also lands in <RUN_ALL_RESULT_DIR>/cases.tsv
# (format: docs/architecture/claude-code/test-result-contract.md).

# This file's own checkout; the sourcing test assigns its own root itself.
_HARNESS_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# 1a. Re-entry guard counters — only initialize when unset.
: "${PASS:=0}"
: "${FAIL:=0}"
: "${SKIP:=0}"

# The result env belongs to the launched file alone: never to a nested test or a child process.
if [ -z "${_HARNESS_CASES_FILE+x}" ]; then
  _HARNESS_CASES_FILE=""
  _HARNESS_CASE_SEQ=0
  _HARNESS_CASE_OPEN=""
  if [ -n "${RUN_ALL_RESULT_DIR:-}" ] && [ "${RUN_ALL_RESULT_OWNER-}" = "$0" ]; then
    _HARNESS_CASES_FILE="$RUN_ALL_RESULT_DIR/cases.tsv"
  fi
fi
unset RUN_ALL_RESULT_DIR RUN_ALL_RESULT_OWNER

# 1b. Result reporters.
pass() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  if [ -n "${2:-}" ]; then
    echo "FAIL: $1 — $2"
  else
    echo "FAIL: $1"
  fi
  FAIL=$((FAIL + 1))
  _harness_case_failed
}

# _harness_case_failed — the open case's FAIL record, written at once and only once: a file that
# exits before case_end must not leave the case merely OPEN. xfail.sh's XPASS calls it too.
_harness_case_failed() {
  [ -n "${_HARNESS_CASE_OPEN:-}" ] && [ -z "${_HARNESS_CASE_FAILED:-}" ] || return 0
  _HARNESS_CASE_FAILED=1
  _harness_case_record FAIL
}

skip() {
  echo "SKIP: $1"
  SKIP=$((SKIP + 1))
}

# 1c. assert_eq <actual> <expected>
assert_eq() {
  local actual="$1" expected="$2"
  if [ "$actual" = "$expected" ]; then
    pass "eq: $(printf '%q' "$expected")"
  else
    fail "eq" "want=$(printf '%q' "$expected") got=$(printf '%q' "$actual")"
  fi
}

# _harness_case_record <STATE> — one cases.tsv line for the current case; a no-op without a result dir.
_harness_case_record() {
  [ -n "${_HARNESS_CASES_FILE:-}" ] || return 0
  printf '%s\t%s\t%s\t%s\n' "$_HARNESS_CASE_SEQ" "$1" "$_HARNESS_CASE_NAME" "$_HARNESS_CASE_TARGET" \
    >>"$_HARNESS_CASES_FILE" 2>/dev/null || true
}

# 1d. case_begin / case_end — the target is a static catalog key; run-all also reads the records.
case_begin() {
  local name="$1" target="$2"
  if [ -z "$name" ]; then
    fail "case_begin" "name is empty"
    return 1
  fi
  if [ -z "$target" ]; then
    fail "case_begin" "target-path is empty"
    return 1
  fi
  if [ "${target#//}" != "$target" ]; then
    fail "case_begin" "target-path is a UNC path: $target"
    return 1
  fi
  if [ "${target#/}" != "$target" ]; then
    fail "case_begin" "target-path is absolute: $target"
    return 1
  fi
  case "$target" in
    *:*|*\\*)
      fail "case_begin" "target-path has a drive letter or backslash: $target"
      return 1
      ;;
  esac
  if [ "$target" = ".." ]; then
    fail "case_begin" "target-path escapes the tree: $target"
    return 1
  fi
  case "$target" in
    *../*)
      fail "case_begin" "target-path escapes the tree: $target"
      return 1
      ;;
  esac
  case "$target" in
    *";"*|*'$'*|*'`'*|*"|"*|*"&"*|*">"*|*"<"*|*"("*|*")"*)
      fail "case_begin" "target-path has shell metacharacters: $target"
      return 1
      ;;
  esac
  [ -z "${_HARNESS_CASE_OPEN:-}" ] || case_end
  CURRENT_CASE="$name"
  CURRENT_CASE_TARGET="$target"
  echo "--- case: $name ($target) ---"
  _HARNESS_CASE_SEQ=$((${_HARNESS_CASE_SEQ:-0} + 1))
  _HARNESS_CASE_OPEN=1
  _HARNESS_CASE_FAILED=""
  _HARNESS_CASE_NAME="${name//[$'\t\n']/ }"
  _HARNESS_CASE_TARGET="${target//[$'\t\n']/ }"
  _HARNESS_CASE_AT="${PASS:-0} ${FAIL:-0} ${SKIP:-0} ${XFAIL_N:-0} ${XPASS_N:-0}"
  _harness_case_record OPEN
}

# The final state follows the counters this case moved: an XPASS also raises FAIL, so only
# failures beyond the XPASS count make it FAIL.
# shellcheck disable=SC2034  # CURRENT_CASE* are consumed by test callers, not here.
case_end() {
  local p f s xf xp st
  CURRENT_CASE=""
  CURRENT_CASE_TARGET=""
  [ -n "${_HARNESS_CASE_OPEN:-}" ] || return 0
  _HARNESS_CASE_OPEN=""
  read -r p f s xf xp <<<"$_HARNESS_CASE_AT"
  p=$((${PASS:-0} - p)) f=$((${FAIL:-0} - f)) s=$((${SKIP:-0} - s))
  xf=$((${XFAIL_N:-0} - xf)) xp=$((${XPASS_N:-0} - xp))
  if [ $((f - xp)) -gt 0 ]; then st=FAIL
  elif [ "$xp" -gt 0 ]; then st=XPASS
  elif [ "$xf" -gt 0 ]; then st=XFAIL
  elif [ "$p" -gt 0 ]; then st=PASS
  elif [ "$s" -gt 0 ]; then st=SKIP
  else st=UNOBSERVED
  fi
  # A FAIL already written by fail() is the final record; an XPASS still gets its own line.
  if [ "$st" = FAIL ] && [ -n "${_HARNESS_CASE_FAILED:-}" ]; then return 0; fi
  _harness_case_record "$st"
}

# harness_discard_pass <cmd> [args...] — run <cmd> as a dry pass (e.g. to prefetch probes): output
# discarded, return code ignored, no cases.tsv line written, and the counters plus every case-state
# variable restored afterwards. Stdin is the caller's to redirect; caller-owned counters stay its own.
_HARNESS_DISCARD_VARS=(PASS FAIL SKIP XFAIL_N XPASS_N CURRENT_CASE CURRENT_CASE_TARGET _HARNESS_CASES_FILE
  _HARNESS_CASE_OPEN _HARNESS_CASE_FAILED _HARNESS_CASE_SEQ _HARNESS_CASE_NAME _HARNESS_CASE_TARGET _HARNESS_CASE_AT)
harness_discard_pass() {
  local _hdp_v _hdp_i=0
  local -a _hdp_saved=()
  for _hdp_v in "${_HARNESS_DISCARD_VARS[@]}"; do
    if [ -n "${!_hdp_v+x}" ]; then _hdp_saved+=("1${!_hdp_v}"); else _hdp_saved+=("0"); fi
  done
  _HARNESS_CASES_FILE=""
  "$@" >/dev/null 2>&1 || true
  for _hdp_v in "${_HARNESS_DISCARD_VARS[@]}"; do
    case "${_hdp_saved[_hdp_i]}" in
      1*) printf -v "$_hdp_v" '%s' "${_hdp_saved[_hdp_i]#1}" ;;
      *) unset "$_hdp_v" ;;
    esac
    _hdp_i=$((_hdp_i + 1))
  done
  return 0
}

# 1e. Fixture helpers.

# np() — normalize path for node: cygpath -m on Windows, passthrough elsewhere.
np() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s\n' "$1"
  fi
}

# make_tmp — portable temp directory (macOS and Linux). Caller owns cleanup;
# no EXIT trap here (one trap per shell, and the caller owns it).
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t harness; }

# run_with_timeout <seconds> <command...> — per rules/test/macos-timeout.md.
RWT="${RWT:-$_HARNESS_SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh}"
run_with_timeout() { bash "$RWT" "$@"; }

# Root decoy default: the launcher's ROOT_DECOY_DIR when given, else one built for this test.
# Fails closed — a test must not run with the root names pointing at a real checkout.
case "${BASH_SOURCE[0]}" in
  */*) _HARNESS_LIB_DIR="${BASH_SOURCE[0]%/*}" ;;
  *)   _HARNESS_LIB_DIR="." ;;
esac
# Exception: a harness copied without root-decoy.sh (a fixture checkout) keeps the decoy, run
# root and command guard its launcher already pinned, as run_all_pin_root_decoy does; anything
# else still fails closed.
if [[ ! -f "$_HARNESS_LIB_DIR/root-decoy.sh" && -n "${ROOT_DECOY_DIR:-}" && -d "$ROOT_DECOY_DIR/main" &&
  "${AGENTS_MAIN_ROOT:-}" == "$ROOT_DECOY_DIR/main" ]]; then
  :
else
  # shellcheck source=tests/lib/root-decoy.sh
  . "$_HARNESS_LIB_DIR/root-decoy.sh" || exit 1
  root_decoy_ensure || exit 1
  # Run root (TMPDIR pinned inside it) and the command guard in front of git/gh/glab/codex;
  # docs/architecture/claude-code/test-command-guard.md. Both fail closed like the decoy.
  # shellcheck source=tests/lib/test-run-root.sh
  . "$_HARNESS_LIB_DIR/test-run-root.sh" || exit 1
  test_run_root_ensure || exit 1
  # shellcheck source=tests/lib/command-guard.sh
  . "$_HARNESS_LIB_DIR/command-guard.sh" || exit 1
  command_guard_ensure || exit 1
fi

# harness_isolate [<tmpdir>] — dual-pin per rules/test/fixture-isolation.md,
# so tests never write the developer's real ~/.workflow-plans. Idempotent.
harness_isolate() {
  local d="${1:-$(make_tmp)}"
  mkdir -p "$d/workflow-state" "$d/plans"
  export WORKFLOW_STATE_DIR="$d/workflow-state"
  export WORKFLOW_PLANS_DIR="$d/plans"
}

# _harness_norm_path <path> — cygpath -m, backslash -> /, no trailing /,
# lower-cased on Windows so live-root comparison is case-insensitive there.
_harness_norm_path() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    p="$(cygpath -m "$p" 2>/dev/null || printf '%s' "$p")"
  fi
  p="${p//\\//}"
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  if command -v cygpath >/dev/null 2>&1 || [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]; then
    p="$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')"
  fi
  printf '%s' "$p"
}

# harness_assert_isolated — fail closed unless both dirs are pinned off the live
# defaults. A helper cannot tell a test's pin from an inherited live value, so
# helpers assert here and the sourcing test calls harness_isolate first.
harness_assert_isolated() {
  local var val nval root nroot
  for var in WORKFLOW_STATE_DIR WORKFLOW_PLANS_DIR; do
    val="${!var:-}"
    if [ -z "$val" ]; then
      echo "harness_assert_isolated: $var is unset or empty; call harness_isolate before this helper" >&2
      exit 1
    fi
    nval="$(_harness_norm_path "$val")"
    for root in "$HOME/.workflow-state" "$HOME/.claude/projects/workflow" "$HOME/.workflow-plans"; do
      nroot="$(_harness_norm_path "$root")"
      if [ "$nval" = "$nroot" ] || [ "${nval#"$nroot"/}" != "$nval" ]; then
        echo "harness_assert_isolated: $var=$val is under the live dir $root" >&2
        exit 1
      fi
    done
  done
}

# harness_git_init <dir> — git repo with core.hooksPath=/dev/null so the
# installed pre-commit hook never fires inside the fixture, and without the
# developer's own ignore file, so the fixture tracks the same files on every machine.
harness_git_init() {
  git init -q "$1"
  git -C "$1" config core.hooksPath /dev/null
  # The repo's own (empty) exclude file: git on Windows refuses /dev/null here.
  git -C "$1" config core.excludesFile "$1/.git/info/exclude"
}

# Unset inherited session IDs unconditionally (per fixture-isolation.md).
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE 2>/dev/null || true
