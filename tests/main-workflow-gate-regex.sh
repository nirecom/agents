#!/usr/bin/env bash
# Tests: hooks/workflow-gate.js
# Tags: workflow, gate, hook, regex, table-driven, scope:common
# Tests for workflow-gate.js commit detection regex
# Tests the FIXED regex: /^git\s+(?:-C\s+\S+\s+)?commit\s/

set -u

PASS=0
FAIL=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1)); fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm '"$secs"'; exec @ARGV' -- "$@"; fi
}

eval_regex() {
    local input="$1"
    TEST_CMD="$input" run_with_timeout 30 node -e "
const regex = /^git\s+(?:-C\s+\S+\s+)?commit\s/;
process.stdout.write(regex.test(process.env.TEST_CMD) ? 'match' : 'no-match');
"
}

echo "=== workflow-gate.js commit regex tests ==="
echo "Testing fixed regex: /^git\\s+(?:-C\\s+\\S+\\s+)?commit\\s/"
echo ""

while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    input="${input# }"
    input="${input%"${input##*[! ]}"}"
    want="${want//[[:space:]]/}"
    got=$(eval_regex "$input")
    assert_eq "$name" "$want" "$got"
done <<'TABLE'
normal-simple-commit                | git commit -m "msg"                                           | match
normal-dash-C-path                  | git -C /path/repo commit -m "msg"                             | match
normal-dash-C-windows-path          | git -C c:\git\dotfiles commit -m "msg"                        | match
no-match-git-status                 | git status                                                     | no-match
no-match-leading-spaces             |  git commit -m "msg"                                          | no-match
fp-uv-run-with-git-commit-in-arg    | uv run bin/doc-append.py --background "git commit blocked"    | no-match
fp-echo-git-commit-message          | echo "git commit message"                                     | no-match
TABLE

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
