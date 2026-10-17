#!/usr/bin/env bash
# Tests: hooks/pre-commit, hooks/block-case-markers.js, settings.json, hooks/lib/test-language-registry.json, bin/check-test-frontmatter.sh
# Tags: TL2, hooks, case-markers, test-language-registry, pre-commit, scope:issue-specific
# Issue #2411: the marker gate reached the way a user reaches it — a real `git commit` with
# core.hooksPath at the checkout's hooks directory, and the edit hook run as the command
# settings.json registers. bash rows hold today's verdicts; the other languages need #2411.
# TL3 gap: Claude Code itself routing a live Write through settings.json, and core.hooksPath
# arriving from the installer's global git config (mitigation: the matcher and the command
# string are read from settings.json here; tests/hooks/feature-2388-block-case-markers.sh).
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
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX CODE_LANG

CASE_DIR="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2411-gate-integration"
HOOKS_DIR="$SCRIPT_CHECKOUT_ROOT/hooks"
SETTINGS_JSON="$SCRIPT_CHECKOUT_ROOT/settings.json"
BLOCKED_LINE="Commit blocked: new test file(s) fail the case-marker gate."

NEUTRAL_CWD="$TMPBASE/neutral"
BODIES="$TMPBASE/bodies"
EMPTY_ROOT="$TMPBASE/agents-config"
mkdir -p "$NEUTRAL_CWD" "$BODIES" "$EMPTY_ROOT"

# lang_set <id> <stem> — LF the test file name, LBODY the body name prefix, LREQ the command
# the language's case reader runs under.
lang_set() {
  case "$1" in
    bash) LF="$2.sh"; LBODY="sh"; LREQ="bash" ;;
    pester) LF="$2.Tests.ps1"; LBODY="pester"; LREQ="pwsh" ;;
    pytest) LF="test_$2.py"; LBODY="pytest"; LREQ="uv" ;;
    js) LF="$2.js"; LBODY="js"; LREQ="node" ;;
    *) LF=""; LBODY=""; LREQ="" ;;
  esac
}

# has <label> <haystack> <fixed-string>
has() {
  case "$2" in
    *"$3"*) pass "$1: has [$3]" ;;
    *) fail "$1" "lacks [$3]: $(printf '%s' "$2" | tr '\n' ' ')" ;;
  esac
}

# The fixture repo: HEAD carries one helper library stub per language and the sources the
# bodies name. Its hooks stay off (harness_git_init) until a commit case arms its own copy.
TEMPLATE="$TMPBASE/template"
harness_git_init "$TEMPLATE"
git -C "$TEMPLATE" config user.email t@example.com
git -C "$TEMPLATE" config user.name t
git -C "$TEMPLATE" config core.autocrlf false
git -C "$TEMPLATE" config commit.gpgsign false
mkdir -p "$TEMPLATE/tests/lib" "$TEMPLATE/tests/hooks" "$TEMPLATE/bin"
for _ext in sh ps1 py js; do
  printf '\n' > "$TEMPLATE/tests/lib/harness.$_ext"
  printf '\n' > "$TEMPLATE/bin/a.$_ext"
  printf '\n' > "$TEMPLATE/bin/b.$_ext"
done
git -C "$TEMPLATE" add -A >/dev/null 2>&1
git -C "$TEMPLATE" update-index --chmod=+x -- tests/lib/harness.sh bin/a.sh bin/b.sh >/dev/null 2>&1
git -C "$TEMPLATE" commit -q -m init >/dev/null 2>&1
git -C "$TEMPLATE" remote add origin https://example.invalid/gate-fixture.git

case_begin "fixture-repo-is-ready-and-the-checkout-ships-the-hook" "hooks/pre-commit"
assert_eq "template commits=$(git -C "$TEMPLATE" rev-list --count HEAD 2>/dev/null)" "template commits=1"
_tpl_hooks="$(git -C "$TEMPLATE" config --get core.hooksPath)"
case "$_tpl_hooks" in
  /dev/null|nul|NUL) pass "template hooks are off (core.hooksPath=$_tpl_hooks)" ;;
  *) fail "template hooks are off" "core.hooksPath=[$_tpl_hooks]" ;;
esac
if [ -f "$HOOKS_DIR/pre-commit" ]; then
  pass "hooks/pre-commit is in the hooks directory core.hooksPath will name"
else
  fail "hooks/pre-commit" "missing from $HOOKS_DIR"
fi
case_end

# shellcheck source=feature-2411-gate-integration/bodies.sh
. "$CASE_DIR/bodies.sh"
# shellcheck source=feature-2411-gate-integration/commit.sh
. "$CASE_DIR/commit.sh"
# shellcheck source=feature-2411-gate-integration/edit.sh
. "$CASE_DIR/edit.sh"
# shellcheck source=feature-2411-gate-integration/existing.sh
. "$CASE_DIR/existing.sh"

# Load-line rows: the regex is read from the registry the way bin/check-test-frontmatter.sh
# reads it, and a line is matched the way its check_harness_source matches staged content.
# shellcheck source=../../bin/lib/test-language-registry.sh
source "$SCRIPT_CHECKOUT_ROOT/bin/lib/test-language-registry.sh"
SRC_RE_LOADED=0
tlr_load && SRC_RE_LOADED=1

# source_regex_rows <id> — reads "<row>|<match|no-match>|<line>" rows from stdin.
source_regex_rows() {
  local id="$1" row want line got re
  if [[ "$SRC_RE_LOADED" != 1 ]] || ! _tlr_get "$id" helperLibrary.sourceRegex; then
    fail "$id sourceRegex" "not readable from the registry"
    return 0
  fi
  re="$_TLR_V"
  while IFS='|' read -r row want line; do
    [[ -z "$row" || "$row" == \#* ]] && continue
    got="no-match"
    if printf '%s\n' "$line" | grep -Eq -- "$re"; then got="match"; fi
    if [[ "$got" == "$want" ]]; then
      pass "$id/$row: $want [$line]"
    else
      fail "$id/$row" "want=$want got=$got line=[$line] re=[$re]"
    fi
  done
}

case_begin "pin-pester-source-regex-s4" "hooks/lib/test-language-registry.json"
source_regex_rows pester <<'TABLE'
join-path-load|match|. (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
backslash-path-load|match|. '..\lib\harness.ps1'
slash-path-load|match|. "$PSScriptRoot/../lib/harness.ps1"
indented-join-path-load|match|    . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
indented-slash-path-load|match|        . "$PSScriptRoot/../lib/harness.ps1"
commented-load|no-match|# . "$PSScriptRoot/../lib/harness.ps1"
prose-mention|no-match|Write-Host 'see lib/harness.ps1'
other-lib-file|no-match|. "$PSScriptRoot/../lib/other.ps1"
harness-outside-lib|no-match|. "$PSScriptRoot/harness.ps1"
myharness-file|no-match|. ./myharness.ps1
TABLE
case_end

case_begin "pin-pytest-source-regex-s4" "hooks/lib/test-language-registry.json"
source_regex_rows pytest <<'TABLE'
import-load|match|import harness
import-load-trailing-comment|match|import harness  # helper
from-import-load|match|from harness import case_begin, case_end
commented-import|no-match|# import harness
import-other-module|no-match|import harness_other
indented-import|no-match|    import harness
indented-from-import|no-match|    from harness import x
string-literal|no-match|x = "import harness"
from-other-module|no-match|from harness_other import x
TABLE
case_end

case_begin "pin-js-source-regex-s4" "hooks/lib/test-language-registry.json"
source_regex_rows js <<'TABLE'
destructured-load|match|const { caseBegin, caseEnd } = require('../lib/harness');
double-quoted-load|match|require("../lib/harness")
single-quoted-js-ext|match|require('../lib/harness.js')
double-quoted-js-ext|match|require("../lib/harness.js")
commented-load|no-match|// const h = require('../lib/harness');
other-lib-module|no-match|require('../lib/other')
path-join-load|no-match|require(path.join(__dirname, '..', 'lib', 'harness'))
same-dir-lib|no-match|require('./lib/harness')
deeper-relative-lib|no-match|require('../../tests/lib/harness')
TABLE
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
