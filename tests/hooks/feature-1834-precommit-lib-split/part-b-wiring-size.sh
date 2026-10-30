# Part B — wiring + size guards (real hooks/pre-commit).
# Sourced by tests/hooks/feature-1834-precommit-lib-split.sh; shares its helpers/globals.

echo ""
echo "=== Part B: wiring + size guards (real hooks/pre-commit) ==="

# B1: structural wiring — un-wiring a module must be caught even if units stay green.
# #2507: hooks/pre-commit execs hooks/pre-commit.d/main.js, whose registry runs both gate blocks.
case_begin "B1-wiring-present" "hooks/pre-commit"
w=0
_reg="$SCRIPT_CHECKOUT_ROOT/hooks/pre-commit.d/registry.js"
grep -q 'node "$_cfg_dir/hooks/pre-commit.d/main.js"' "$PRECOMMIT" || { fail "B1: wiring" "run of hooks/pre-commit.d/main.js missing"; w=1; }
grep -qF '["tests-frontmatter",' "$_reg" || { fail "B1: wiring" "tests-frontmatter check not registered"; w=1; }
grep -qF '["agents-repo-gates",' "$_reg" || { fail "B1: wiring" "agents-repo-gates check not registered"; w=1; }
[ "$w" -eq 0 ] && pass "B1: hooks/pre-commit runs the Node body and its registry lists both gate blocks"
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
