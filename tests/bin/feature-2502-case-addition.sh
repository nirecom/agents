#!/usr/bin/env bash
# tests/bin/feature-2502-case-addition.sh
# Tests: bin/lib/test-language-match.sh, bin/lib/test-language-match/case-addition.sh
# Tags: TL2, bin, test-language-match, case-markers, test-language-registry, scope:issue-specific
# Issue #2502 S4-4b: the case-addition judgment of bin/check-test-language-match.sh. When HEAD's
# or the working version of a test is not conforming, a case added (more case units, or more
# code lines when the units cannot be counted) is one HIGH CASE_ADDED_WITHOUT_MARKERS line,
# whatever language the added case tests; edits that add no case pass. Cases live in the sibling
# directory: existing-bash.sh (new files and bash) and languages.sh (pester, pytest, js).
# shellcheck disable=SC2016 # fixture lines hold literal $REPO and $(...) text on purpose
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

CASE_DIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2502-case-addition"
# The fixture repo, body / lm / count_code / expect_* (one owner, shared with the match suite).
# shellcheck source=feature-2502-test-language-match/_lib.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2502-test-language-match/_lib.sh"
# fx_checkout (a stub checkout for the deps-op and no-runtime rows).
# shellcheck source=test-language-registry/_lib.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/test-language-registry/_lib.sh"
# shellcheck source=../../bin/lib/test-language-registry.sh
. "$SCRIPT_CHECKOUT_ROOT/bin/lib/test-language-registry.sh"
tlr_load || { echo "FAIL: registry unreadable"; exit 1; }

for _f in bin/m.ps1 bin/m.py; do printf '\n' > "$REPO/$_f"; done
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -q -m case-addition >/dev/null 2>&1

# raw <name> <line>... — a body in $BODIES/<name>, one argument per line.
raw() {
  local out="$BODIES/$1"
  shift
  printf '%s\n' "$@" > "$out"
}

# expect_added <label> <rel> <entry-id> <basis-glob> — rc 1, exactly one
# CASE_ADDED_WITHOUT_MARKERS line, and that line in the plan's shape with the entry's markerName.
expect_added() {
  local mn line found=0
  mn="$(tlr_field "$3" diagnostics.markerName)"
  expect_rc "$1" 1
  assert_eq "$1: CASE_ADDED_WITHOUT_MARKERS lines=$(count_code CASE_ADDED_WITHOUT_MARKERS)" \
    "$1: CASE_ADDED_WITHOUT_MARKERS lines=1"
  while IFS= read -r line; do
    # shellcheck disable=SC2254 # $4 is a glob on purpose
    case "$line" in
      "HIGH: $2: case added to a test file without valid case markers ("$4"); add $mn to every case first, then each case's target is checked code=CASE_ADDED_WITHOUT_MARKERS") found=1 ;;
    esac
  done <<< "$LM_OUT"
  if [ "$found" = 1 ]; then pass "$1: basis $4"; else fail "$1" "no CASE_ADDED line with basis [$4]: out=[$LM_OUT] err=[$LM_ERR]"; fi
}

# A stub checkout: the bash part's deps op fails on a file holding a `# deps-fail` line, and
# the pester part's case-count answers rc 69 (no runtime) on a file holding `# no-runtime`.
STUB_CO="$TMPBASE/co-stub"
fx_checkout "$STUB_CO"
cp "$LM_CLI_REAL" "$STUB_CO/bin/check-test-language-match.sh"
printf '%s\n' '' 'eval "_real_$(declare -f bash_case_embed)"' \
  'bash_case_embed() {' \
  '  if [ "${1:-}" = deps ] && grep -q "^# deps-fail" "${2:-/dev/null}"; then return 1; fi' \
  '  _real_bash_case_embed "$@"' \
  '}' >> "$STUB_CO/bin/lib/test-language-parts/bash-case-embed.sh"
printf '%s\n' '' 'eval "_real_$(declare -f pester_case_embed)"' \
  'pester_case_embed() {' \
  '  if [ "${1:-}" = case-count ] && grep -q "^# no-runtime" "${2:-/dev/null}"; then return 69; fi' \
  '  _real_pester_case_embed "$@"' \
  '}' >> "$STUB_CO/bin/lib/test-language-parts/pester-case-embed.sh"
STUB_CLI="$STUB_CO/bin/check-test-language-match.sh"

case_begin "ca-cli-and-stub-present" "bin/lib/test-language-match/case-addition.sh"
if [ -f "$LM_CLI_REAL" ] && [ -f "$STUB_CLI" ]; then
  pass "CLI and stub checkout exist"
else
  fail "CLI and stub checkout" "missing: $LM_CLI_REAL or $STUB_CLI"
fi
case_end

# shellcheck source=feature-2502-case-addition/existing-bash.sh
. "$CASE_DIR/existing-bash.sh"
# shellcheck source=feature-2502-case-addition/languages.sh
. "$CASE_DIR/languages.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
