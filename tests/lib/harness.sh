#!/usr/bin/env bash
# tests/lib/harness.sh
# Tests: tests/lib/harness.sh
# Tags: scope:common, shared-lib
# Shared harness. Do NOT mix-source with a narrow harness
# (tests/bin/bin-concern-ledger-reducer.sh, tests/lib/clearance-hook-harness.sh):
# those set PASS=0/FAIL=0 unguarded and overwrite this harness's counts.
# case_begin/case_end targets are for STATIC grep (catalog input),
# not runtime aggregation.

# 1a. Re-entry guard counters — only initialize when unset.
: "${PASS:=0}"
: "${FAIL:=0}"
: "${SKIP:=0}"

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

# 1d. case_begin / case_end — targets are for static grep, not runtime use.
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
  CURRENT_CASE="$name"
  CURRENT_CASE_TARGET="$target"
  echo "--- case: $name ($target) ---"
}

# shellcheck disable=SC2034  # CURRENT_CASE* are consumed by test callers, not here.
case_end() {
  CURRENT_CASE=""
  CURRENT_CASE_TARGET=""
}

# 1e. Fixture helpers.

# AGENTS_DIR resolution: only when caller has not already defined it.
# Uses parameter expansion (no dirname) so it works under filtered PATH (np() tests).
# BASH_SOURCE[1] = sourcing test file → go up 1 from tests/.
# BASH_SOURCE[1] empty (bash -c context) → fall back to BASH_SOURCE[0] (this file,
# tests/lib/harness.sh) and go up 2 from tests/lib/.
: "${AGENTS_DIR:=$(
  _bhs="${BASH_SOURCE[1]:-}";
  if [ -n "$_bhs" ]; then
    cd "${_bhs%/*}/.." && pwd
  else
    cd "${BASH_SOURCE[0]%/*}/../.." && pwd
  fi
)}"

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
RWT="${RWT:-$AGENTS_DIR/bin/run-with-timeout.sh}"
run_with_timeout() { bash "$RWT" "$@"; }

# harness_isolate [<tmpdir>] — dual-pin per rules/test/fixture-isolation.md,
# so tests never write the developer's real ~/.workflow-plans. Idempotent.
harness_isolate() {
  local d="${1:-$(make_tmp)}"
  mkdir -p "$d/workflow-state" "$d/plans"
  export CLAUDE_WORKFLOW_DIR="$d/workflow-state"
  export WORKFLOW_PLANS_DIR="$d/plans"
}

# harness_git_init <dir> — git repo with core.hooksPath=/dev/null so the
# installed pre-commit hook never fires inside the fixture.
harness_git_init() {
  git init -q "$1"
  git -C "$1" config core.hooksPath /dev/null
}

# Unset inherited session IDs unconditionally (per fixture-isolation.md).
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE 2>/dev/null || true
