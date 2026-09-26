# Part C (frontmatter) — space-in-path security cases + token/harness codes (C2/C3).
# The #1834 fix converts the staged-paths list to a bash array read NUL-delimited, so a
# path with a space now reaches the checker as ONE argv element and can no longer evade
# validation. C2a/C2b/C2c assert that fixed behavior on both bypass axes (location + shape).
# Sourced by tests/hooks/feature-1834-precommit-lib-split.sh; shares its helpers/globals.

echo ""
echo "=== Part C: frontmatter security/codes (real bin/check-test-frontmatter.sh) ==="

# C2a — a VALID categorized test whose PATH contains a space. Post-fix the array +
# NUL-delimited read preserve the path as ONE argv element, so the file is actually
# VALIDATED (not bypassed) and passes because it is well-formed: rc 0, no block message.
case_begin "C2a-valid-space-not-blocked" "hooks/lib/precommit-tests-frontmatter.sh"
R="$TMPBASE/c2a"; init_fixture "$R"
mkdir -p "$R/tests/hooks"
printf '%s\n' '#!/usr/bin/env bash' \
    '# tests/hooks/name with spaces.sh' \
    '# Tests: hooks/pre-commit' \
    '# Tags: scope:common' > "$R/tests/hooks/name with spaces.sh"
git -C "$R" add --chmod=+x -- "tests/hooks/name with spaces.sh" >/dev/null 2>&1
run_fm_check "$R"
if [ "$RC" -ne 0 ]; then
    fail "C2a: valid space" "want rc 0 (valid file validated + not blocked), got $RC — out: $(printf '%s' "$OUT" | tr '\n' ' ')"
elif printf '%s' "$OUT" | grep -qF "$FM_MSG"; then
    fail "C2a: valid space" "frontmatter message [$FM_MSG] fired on a well-formed file"
else
    pass "C2a: a valid categorized test whose name contains a space is validated and passes (rc 0)"
fi
case_end

# C2b — the core regression proof: a FLAT test whose PATH contains a space. Post-fix the
# single-token path reaches the checker, which rejects the flat tests/*.sh location
# (FLAT_TEST_SH_REJECTED). The location gate can no longer be evaded by a space.
case_begin "C2b-flat-space-rejected" "hooks/lib/precommit-tests-frontmatter.sh"
R="$TMPBASE/c2b"; init_fixture "$R"
mkdir -p "$R/tests"
printf '%s\n' '#!/usr/bin/env bash' \
    '# tests/name with spaces.sh' \
    '# Tests: hooks/pre-commit' \
    '# Tags: scope:common' > "$R/tests/name with spaces.sh"
git -C "$R" add --chmod=+x -- "tests/name with spaces.sh" >/dev/null 2>&1
run_fm_check "$R"
if [ "$RC" -ne 1 ]; then
    fail "C2b: flat space rejected" "want rc 1 (flat-reject fires), got $RC — out: $(printf '%s' "$OUT" | tr '\n' ' ')"
elif ! printf '%s' "$OUT" | grep -qF "$LOC_MSG"; then
    fail "C2b: flat space rejected" "output lacks the location message [$LOC_MSG]"
else
    pass "C2b: a flat space-bearing test is rejected by the location gate (word-split evasion closed)"
fi
case_end

# C2c — symmetric counterpart on the frontmatter axis: a DEFECTIVE categorized test whose
# PATH contains a space and which OMITS the required headers. Post-fix it is validated as
# one argv element: rc 1, the frontmatter message fires, and the location message does NOT
# (it is correctly categorized). Frontmatter-shape validation can no longer be evaded.
case_begin "C2c-defective-space-frontmatter-rejected" "hooks/lib/precommit-tests-frontmatter.sh"
R="$TMPBASE/c2c"; init_fixture "$R"
mkdir -p "$R/tests/hooks"
printf '%s\n' '#!/usr/bin/env bash' \
    '# bad name.sh — no # Tests: header, no # Tags: line' > "$R/tests/hooks/bad name.sh"
git -C "$R" add --chmod=+x -- "tests/hooks/bad name.sh" >/dev/null 2>&1
run_fm_check "$R"
if [ "$RC" -ne 1 ]; then
    fail "C2c: defective space" "want rc 1 (frontmatter validation fires), got $RC — out: $(printf '%s' "$OUT" | tr '\n' ' ')"
elif ! printf '%s' "$OUT" | grep -qF "$FM_MSG"; then
    fail "C2c: defective space" "output lacks the frontmatter message [$FM_MSG]"
elif printf '%s' "$OUT" | grep -qF "$LOC_MSG"; then
    fail "C2c: defective space" "location message [$LOC_MSG] leaked though the file is correctly categorized"
else
    pass "C2c: a defective space-bearing categorized test is caught by frontmatter validation (shape evasion closed)"
fi
case_end

# C2d — glob-metacharacter counterpart to C2b: a FLAT test whose PATH contains a shell
# glob char (bracket class). Post-fix the NUL-delimited array read preserves it as ONE
# literal argv element — no word-split, no pathname expansion — so the checker still sees
# a flat tests/*.sh and rejects it (LOC_MSG, rc 1). The staging pathspec uses :(literal)
# so git treats the bracket as a filename char, not a pathspec glob.
case_begin "C2d-flat-glob-rejected" "hooks/lib/precommit-tests-frontmatter.sh"
R="$TMPBASE/c2d"; init_fixture "$R"
mkdir -p "$R/tests"
printf '%s\n' '#!/usr/bin/env bash' \
    '# tests/glob[star]name.sh' \
    '# Tests: hooks/pre-commit' \
    '# Tags: scope:common' > "$R/tests/glob[star]name.sh"
git -C "$R" add --chmod=+x -- ":(literal)tests/glob[star]name.sh" >/dev/null 2>&1
run_fm_check "$R"
if [ "$RC" -ne 1 ]; then
    fail "C2d: flat glob rejected" "want rc 1 (flat-reject fires), got $RC — out: $(printf '%s' "$OUT" | tr '\n' ' ')"
elif ! printf '%s' "$OUT" | grep -qF "$LOC_MSG"; then
    fail "C2d: flat glob rejected" "output lacks the location message [$LOC_MSG]"
else
    pass "C2d: a flat glob-bearing test is rejected by the location gate (glob-char word-split/expansion evasion closed)"
fi
case_end

# TL3 gap — filenames bearing a literal newline, and the '*'/'?' glob wildcards, are NOT
# exercised here: Windows filesystems reject control chars and those wildcards in a name,
# so git cannot round-trip such a path portably on this host. C2d's bracket class '[...]'
# is the representative glob metacharacter that IS creatable on every supported platform,
# and it proves the same argv-preservation guarantee the newline case would.

# C3a — INVALID_TESTS_TOKEN: a categorized test whose `# Tests:` token contains
# parentheses (outside [A-Za-z0-9._/-]) fails FRONTMATTER_TOKEN_VALID_RE. The
# frontmatter message fires; the location message must NOT (the file is correctly
# categorized, so only the token shape is wrong).
case_begin "C3a-invalid-tests-token" "hooks/lib/precommit-tests-frontmatter.sh"
R="$TMPBASE/c3a"; init_fixture "$R"
mkdir -p "$R/tests/hooks"
printf '%s\n' '#!/usr/bin/env bash' \
    '# tests/hooks/badtoken.sh' \
    '# Tests: bin/foo(bar).sh' \
    '# Tags: scope:common' > "$R/tests/hooks/badtoken.sh"
git -C "$R" add --chmod=+x -- tests/hooks/badtoken.sh >/dev/null 2>&1
run_fm_check "$R"
if [ "$RC" -ne 1 ]; then
    fail "C3a: invalid token" "want rc 1, got $RC — out: $(printf '%s' "$OUT" | tr '\n' ' ')"
elif ! printf '%s' "$OUT" | grep -qF "$FM_MSG"; then
    fail "C3a: invalid token" "output lacks the frontmatter message [$FM_MSG]"
elif printf '%s' "$OUT" | grep -qF "$LOC_MSG"; then
    fail "C3a: invalid token" "location message [$LOC_MSG] leaked though the file is categorized"
else
    pass "C3a: a malformed # Tests: token blocks with the frontmatter message, not the location message"
fi
case_end

# C3b — MISSING_HARNESS_SOURCE: this rule only runs when tests/lib/harness.sh EXISTS
# in the repo under commit and the entrypoint is newly added. The fixture ships a
# harness stub, then stages a valid-frontmatter entrypoint that never sources it, so
# the harness-source check fires the frontmatter message.
case_begin "C3b-missing-harness-source" "hooks/lib/precommit-tests-frontmatter.sh"
R="$TMPBASE/c3b"; init_fixture "$R"
mkdir -p "$R/tests/lib" "$R/tests/hooks"
printf '%s\n' '#!/usr/bin/env bash' '# harness stub' > "$R/tests/lib/harness.sh"
git -C "$R" add --chmod=+x -- tests/lib/harness.sh >/dev/null 2>&1
git -C "$R" commit -q -m "add harness" >/dev/null 2>&1
printf '%s\n' '#!/usr/bin/env bash' \
    '# tests/hooks/nosrc.sh' \
    '# Tests: hooks/pre-commit' \
    '# Tags: scope:common' \
    'echo "no harness sourced"' > "$R/tests/hooks/nosrc.sh"
git -C "$R" add --chmod=+x -- tests/hooks/nosrc.sh >/dev/null 2>&1
run_fm_check "$R"
if [ "$RC" -ne 1 ]; then
    fail "C3b: missing harness source" "want rc 1, got $RC — out: $(printf '%s' "$OUT" | tr '\n' ' ')"
elif ! printf '%s' "$OUT" | grep -qF "$FM_MSG"; then
    fail "C3b: missing harness source" "output lacks the frontmatter message [$FM_MSG]"
else
    pass "C3b: a new entrypoint that omits the harness source blocks with the frontmatter message"
fi
case_end
