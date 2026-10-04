# Case 19 (#2500): the self-contamination guard reads `Tests:` in each candidate's own
# registry header.commentPrefix. The fixture table (slash-header.json) adds slash-lang
# (*.slt, "//"); a `Tests:` line in the other language's prefix is a decoy.

REPO19=$(make_repo)
git -C "$REPO19" checkout -q -b feature19
cp "$AGENTS_ROOT/tests/bin/test-language-registry/fixtures/slash-header.json" \
    "$REPO19/hooks/lib/test-language-registry.json"

# write_e2e19 <path> <prefix> <tests-target> <decoy-line-or-empty> <hook> — a compliant
# E2E body naming <hook>, so only the header decides whether the file counts.
write_e2e19() {
    local path="$1" pfx="$2" target="$3" decoy="${4:-}"
    mkdir -p "$(dirname "$path")"
    {
        [[ -n "$decoy" ]] && printf '%s\n' "$decoy"
        printf '%s\n' "$pfx Tests: $target" "$pfx Tags: scope:issue-specific, e2e"
        printf '%s\n' 'get-config-var --is-off RUN_TL3 off && exit 77'
        printf '%s\n' "claude -p \"test\" # hooks/$5"
    } > "$path"
}

for h in stop-confirm-plan-guard.js subagent-start.js post-compact.js session-start.js; do
    write_hook_stub "$REPO19" "$h"
done
# slash-lang self-test: `// Tests:` names the script, so it must not cover its hook.
write_e2e19 "$REPO19/tests/feature-19-self.slt" "//" "bin/review-e2e-coverage" "" "stop-confirm-plan-guard.js"
# slash-lang real E2E with a leading `#` self-test decoy: still counts.
write_e2e19 "$REPO19/tests/feature-19-sub.slt" "//" "hooks/subagent-start.js" \
    "# Tests: bin/review-e2e-coverage" "subagent-start.js"
# bash real E2E with a leading `//` self-test decoy: still counts.
write_e2e19 "$REPO19/tests/feature-19-pc.sh" "#" "hooks/post-compact.js" \
    "// Tests: bin/review-e2e-coverage" "post-compact.js"
# bash self-test (`#` prefix, unchanged behaviour): excluded.
write_e2e19 "$REPO19/tests/feature-19-self.sh" "#" "bin/review-e2e-coverage" "" "session-start.js"
git -C "$REPO19" add -A
git -C "$REPO19" commit -q -m "four hooks; self-tests and decoys in both comment prefixes"

EXIT_CODE=0
OUTPUT=$(run_script "$REPO19" --base main) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 19: exits 0"
else
    fail "Case 19: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "WARN.*stop-confirm-plan-guard"; then
    pass "Case 19: // Tests: self-test in a slash-lang file is excluded"
else
    fail "Case 19: slash-lang self-test (// Tests:) counted as coverage. Output: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "WARN.*subagent-start"; then
    fail "Case 19: # decoy in a slash-lang file wrongly excluded it. Output: $OUTPUT"
else
    pass "Case 19: # Tests: decoy in a slash-lang file does not exclude it"
fi
if echo "$OUTPUT" | grep -q "WARN.*post-compact"; then
    fail "Case 19: // decoy in a bash file wrongly excluded it. Output: $OUTPUT"
else
    pass "Case 19: // Tests: decoy in a bash file does not exclude it"
fi
if echo "$OUTPUT" | grep -q "WARN.*session-start"; then
    pass "Case 19: bash # Tests: self-test still excluded"
else
    fail "Case 19: bash self-test (# Tests:) counted as coverage. Output: $OUTPUT"
fi
