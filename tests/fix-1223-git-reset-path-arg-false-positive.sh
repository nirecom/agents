#!/bin/bash
# tests/fix-1223-git-reset-path-arg-false-positive.sh
# Tests: hooks/lib/bash-write-patterns.js
# Tags: hook, classify, scope:issue-specific
#
# L3 gap (what this test does NOT catch):
# - Real git runtime behavior if the git-reset regex stays position-unaware in a future change
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration
#
# Regression evidence: the git-reset-in-* cases may FAIL against the CURRENT
# bash-write-patterns.js (the literal "reset" inside a path argument is
# misclassified as a `git reset` write). That is the #1223 defect to fix in
# write-code. This test tolerates those expected FAILs (exit 0) as
# fail-before-fix evidence.
set -u
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _A="$(cygpath -m "$AGENTS_DIR")"; else _A="$AGENTS_DIR"; fi
WP="${_A}/hooks/lib/bash-write-patterns.js"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
run_with_timeout() {
  if [ -x "${_A}/bin/run-with-timeout.sh" ]; then "${_A}/bin/run-with-timeout.sh" 30 "$@";
  elif command -v timeout >/dev/null 2>&1; then timeout 30 "$@";
  else perl -e 'alarm 30; exec @ARGV' -- "$@"; fi
}
classify() {
  run_with_timeout node -e "const {classify}=require('$WP');console.log(classify(process.argv[1]))" -- "$1" 2>/dev/null
}
assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then pass "$name (=$got)"; else fail "$name (want=$want got=$got)"; fi
}

while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
    got=$(classify "$input")
    assert_eq "$name" "$want" "$got"
done <<'TABLE'
# #1223 regression: git reset in path arg must NOT trigger git-reset write pattern
git-reset-in-path      | git log --oneline path/to/reset/module.js             | read
git-reset-in-patharg   | git diff HEAD -- src/reset/config.ts                   | read
git-reset-colon-path   | git show main:reset/file.js                            | read
# Real git reset subcommand must still trigger write
git-reset-real         | git reset HEAD~1                                       | write
git-reset-soft         | git reset --soft HEAD                                  | write
git-reset-hard         | git reset --hard origin/main                           | write
TABLE

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
