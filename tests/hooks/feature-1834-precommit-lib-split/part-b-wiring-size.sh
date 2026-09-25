# Part B — wiring + size guards (real hooks/pre-commit).
# Sourced by tests/hooks/feature-1834-precommit-lib-split.sh; shares its helpers/globals.

echo ""
echo "=== Part B: wiring + size guards (real hooks/pre-commit) ==="

# B1: structural wiring — un-wiring a module must be caught even if units stay green.
case_begin "B1-wiring-present" "hooks/pre-commit"
w=0
grep -q 'precommit-tests-frontmatter.sh' "$PRECOMMIT" || { fail "B1: wiring" "source of hooks/lib/precommit-tests-frontmatter.sh missing"; w=1; }
grep -q '_precommit_check_tests_frontmatter' "$PRECOMMIT" || { fail "B1: wiring" "call to _precommit_check_tests_frontmatter missing"; w=1; }
grep -q 'precommit-agents-repo-gates.sh' "$PRECOMMIT" || { fail "B1: wiring" "source of hooks/lib/precommit-agents-repo-gates.sh missing"; w=1; }
grep -q '_precommit_agents_repo_gates' "$PRECOMMIT" || { fail "B1: wiring" "call to _precommit_agents_repo_gates missing"; w=1; }
[ "$w" -eq 0 ] && pass "B1: hooks/pre-commit sources and calls both extracted modules"
case_end

# B2: size regression — the file-split.md Pattern A HARD limit is the reason for the split.
case_begin "B2-size-under-hard-limit" "hooks/pre-commit"
lines="$(wc -l < "$PRECOMMIT")"
lines="$(printf '%s' "$lines" | tr -d '[:space:]')"
if [ "$lines" -le 500 ]; then
    pass "B2: hooks/pre-commit is $lines lines (<= 500 HARD limit)"
else
    fail "B2: size" "hooks/pre-commit is $lines lines, exceeds the 500-line HARD limit"
fi
case_end
