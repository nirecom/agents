#!/bin/bash
# tests/fix-1223-git-reset-path-arg-false-positive.sh
# Tests: hooks/lib/bash-write-patterns/patterns.js
# Tags: hook, git-write, scope:issue-specific
#
# L3 gap (what this test does NOT catch):
# - Real git runtime behavior if the subcommand classifier becomes position-unaware in a future change
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration
#
# #1223 intent: the literal token "reset" inside a PATH argument of a read
# subcommand (git log/diff/show) must NOT be misclassified as a `git reset`
# write. #1401 migration: git write detection moved from classify()/WRITE_PATTERNS
# to isGitWriteIR (the IR-based SSOT, read-allowlist + fail-closed). This test now
# pins the #1223 no-false-positive guarantee AND the real-reset-is-write
# guarantee against isGitWriteIR — the current owner of git-write classification.
set -u
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _A="$(cygpath -m "$AGENTS_DIR")"; else _A="$AGENTS_DIR"; fi
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
run_with_timeout() {
  if [ -x "${_A}/bin/run-with-timeout.sh" ]; then "${_A}/bin/run-with-timeout.sh" 30 "$@";
  elif command -v timeout >/dev/null 2>&1; then timeout 30 "$@";
  else perl -e 'alarm 30; exec @ARGV' -- "$@"; fi
}
# git_write <cmd> → "write" when isGitWriteIR true, else "read" (maps the boolean
# onto the #1223 table's read/write vocabulary).
git_write() {
  run_with_timeout node -e "const {isGitWriteIR}=require('${_A}/hooks/lib/bash-write-patterns/patterns');const {parse}=require('${_A}/hooks/lib/command-ir');process.stdout.write(isGitWriteIR(parse(process.argv[1]))?'write':'read')" -- "$1" 2>/dev/null
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
    got=$(git_write "$input")
    assert_eq "$name" "$want" "$got"
done <<'TABLE'
# #1223 regression: "reset" in a path arg of a read subcommand must NOT be a write
git-reset-in-path      | git log --oneline path/to/reset/module.js             | read
git-reset-in-patharg   | git diff HEAD -- src/reset/config.ts                   | read
git-reset-colon-path   | git show main:reset/file.js                            | read
# Real git reset subcommand must still be a write
git-reset-real         | git reset HEAD~1                                       | write
git-reset-soft         | git reset --soft HEAD                                  | write
git-reset-hard         | git reset --hard origin/main                           | write
TABLE

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
