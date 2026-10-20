#!/usr/bin/env bash
# tests/bin/feature-2502-check-self-impl.sh
# Tests: bin/check-self-impl.sh, bin/check-test-frontmatter.sh
# Tags: TL2, bin, self-impl, test-language-registry, pre-commit, scope:issue-specific
# Issue #2502 S3: bin/check-self-impl.sh reports a test that builds its own harness
# (a hand-made pass/fail counter, or a redefinition of a helper-library name) for every
# registered language, and check-test-frontmatter.sh --staged runs it on new files only.
# Cases live in the sibling directory: cli.sh drives the CLI, commit-time.sh the commit gate.
# TL3 gap: a real git commit through the installed hook (mitigation: the precommit lib split
# test drives the staged path, and tests/hooks/feature-2502-block-self-impl.js the edit path).
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR GIT_DIR GIT_WORK_TREE

CASE_DIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2502-check-self-impl"
SI_CLI_REAL="$SCRIPT_CHECKOUT_ROOT/bin/check-self-impl.sh"
FM_CHECK="$SCRIPT_CHECKOUT_ROOT/bin/check-test-frontmatter.sh"
BODIES="$TMPBASE/bodies"
mkdir -p "$BODIES"

# mkrepo <dir> — fixture repo whose HEAD carries one helper library stub per language.
mkrepo() {
  local d="$1" ext
  harness_git_init "$d"
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name t
  git -C "$d" config core.autocrlf false
  mkdir -p "$d/tests/lib" "$d/tests/bin" "$d/bin"
  for ext in sh ps1 py js; do
    printf '\n' > "$d/tests/lib/harness.$ext"
    printf '\n' > "$d/bin/a.$ext"
  done
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -q -m init >/dev/null 2>&1
}

# put <repo> <rel> <body-name> — copy a body into the working tree.
put() {
  mkdir -p "$(dirname "$1/$2")"
  cp "$BODIES/$3" "$1/$2"
}

# stage <repo> <rel> <body-name>
stage() {
  put "$1" "$2" "$3"
  git -C "$1" add -- "$2" >/dev/null 2>&1
}

# si <repo> <arg>... — the CLI with <repo> as cwd. Sets SI_RC SI_OUT SI_ERR.
# SI_CLI replaces the CLI path and SI_PATH replaces PATH when set.
SI_RC=0; SI_OUT=""; SI_ERR=""
SI_CLI="$SI_CLI_REAL"
SI_PATH=""
si() {
  local repo="$1"
  shift
  SI_RC=0
  (
    cd "$repo" || exit 99
    [ -n "$SI_PATH" ] && PATH="$SI_PATH"
    bash "$RWT" 90 bash "$SI_CLI" "$@"
  ) >"$TMPBASE/si.out" 2>"$TMPBASE/si.err" || SI_RC=$?
  SI_OUT="$(cat "$TMPBASE/si.out")"
  SI_ERR="$(cat "$TMPBASE/si.err")"
}

# fm_run <repo> <rel>... — check-test-frontmatter.sh --staged with <repo> as cwd.
# FM_PATH replaces PATH when set.
FM_RC=0; FM_OUT=""; FM_ERR=""
FM_PATH=""
fm_run() {
  local repo="$1"
  shift
  FM_RC=0
  (
    cd "$repo" || exit 99
    [ -n "$FM_PATH" ] && PATH="$FM_PATH"
    bash "$RWT" 90 bash "$FM_CHECK" --staged "$@"
  ) >"$TMPBASE/fm.out" 2>"$TMPBASE/fm.err" || FM_RC=$?
  FM_OUT="$(cat "$TMPBASE/fm.out")"
  FM_ERR="$(cat "$TMPBASE/fm.err")"
}

# shellcheck source=../lib/tool-shim-path.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/tool-shim-path.sh"

# no_runtime_path <tool> — a PATH of tool wrappers without <tool>; empty when one could not be built.
no_runtime_path() {
  tsp_base_path "$TMPBASE/shim-no-$1" "$1" 2>"$TMPBASE/shim-no-$1.err" || true
}

# expect_rc <label> <want> <got> <detail>
expect_rc() {
  if [ "$3" = "$2" ]; then
    pass "$1: rc=$2"
  else
    fail "$1" "want rc=$2 got rc=$3: $4"
  fi
}

# has / lacks <label> <haystack> <fixed-string>
has() {
  case "$2" in
    *"$3"*) pass "$1: has [$3]" ;;
    *) fail "$1" "lacks [$3]: $2" ;;
  esac
}
lacks() {
  case "$2" in
    *"$3"*) fail "$1" "must not mention [$3]: $2" ;;
    *) pass "$1: no [$3]" ;;
  esac
}

case_begin "cli-file-present" "bin/check-self-impl.sh"
if [ -f "$SI_CLI_REAL" ]; then
  pass "bin/check-self-impl.sh exists"
else
  fail "bin/check-self-impl.sh" "missing: $SI_CLI_REAL"
fi
case_end

# shellcheck source=feature-2502-check-self-impl/bodies.sh
. "$CASE_DIR/bodies.sh"
# shellcheck source=feature-2502-check-self-impl/cli.sh
. "$CASE_DIR/cli.sh"
# shellcheck source=feature-2502-check-self-impl/commit-time.sh
. "$CASE_DIR/commit-time.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
