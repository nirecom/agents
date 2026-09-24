# Cases 9–13: error paths, soft-warn invariant, structural frontmatter.

# Case 9: Hook Audit table header drift → INFO, exit 0.
REPO9=$(make_repo)
git -C "$REPO9" checkout -q -b feature9
write_hook_audit_md_broken_header "$REPO9/rules/test/claude-e2e.md"
write_hook_stub "$REPO9" "stop-confirm-plan-guard.js"
git -C "$REPO9" add rules/test/claude-e2e.md hooks/stop-confirm-plan-guard.js
git -C "$REPO9" commit -q -m "drift hook audit header + add hook"

EXIT_CODE=0
OUTPUT=$(run_script "$REPO9" --base main) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 9: exits 0 even on parse failure (graceful degradation)"
else
    fail "Case 9: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"
fi
if echo "$OUTPUT" | grep -qiE "INFO.*(Hook Audit.*(not parseable|format)|parse|drift|header)"; then
    pass "Case 9: INFO emitted for parse failure"
else
    fail "Case 9: expected INFO about parse failure. Output: $OUTPUT"
fi

# Case 10: rules/test/claude-e2e.md missing → INFO/SKIPPED, exit 0.
REPO10=$(make_repo)
git -C "$REPO10" checkout -q -b feature10
rm -f "$REPO10/rules/test/claude-e2e.md"
write_hook_stub "$REPO10" "stop-confirm-plan-guard.js"
git -C "$REPO10" add -A
git -C "$REPO10" commit -q -m "remove claude-e2e.md, add hook"

EXIT_CODE=0
OUTPUT=$(run_script "$REPO10" --base main) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 10: exits 0 when rules/test/claude-e2e.md is missing"
else
    fail "Case 10: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"
fi
if echo "$OUTPUT" | grep -qE "(INFO|SKIPPED)"; then
    pass "Case 10: INFO or SKIPPED emitted for missing rules file"
else
    fail "Case 10: expected INFO/SKIPPED for missing rules file. Output: $OUTPUT"
fi

# Case 11: --base missing argument → SKIPPED, exit 0.
REPO11=$(make_repo)
git -C "$REPO11" checkout -q -b feature11

EXIT_CODE=0
OUTPUT=$(run_script "$REPO11" --base) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 11: exits 0 when --base argument is missing"
else
    fail "Case 11: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"
fi
if echo "$OUTPUT" | grep -qE "## E2E-Coverage Review:.*SKIPPED.*--base"; then
    pass "Case 11: SKIPPED message mentions --base"
else
    fail "Case 11: expected SKIPPED w/ --base hint. Output: $OUTPUT"
fi

# Case 12 (Invariant): exit 0 regardless of WARN count (>=4 WARN).
REPO12=$(make_repo)
git -C "$REPO12" checkout -q -b feature12
for h in stop-confirm-plan-guard workflow-mark subagent-start post-compact session-start; do
    write_hook_stub "$REPO12" "$h.js"
done
git -C "$REPO12" add hooks/
git -C "$REPO12" commit -q -m "five uncovered hooks"

EXIT_CODE=0
OUTPUT=$(run_script "$REPO12" --base main) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 12: exits 0 even with many WARN (soft-warn invariant)"
else
    fail "Case 12: expected exit 0 with many WARN, got $EXIT_CODE. Output: $OUTPUT"
fi
WARN_COUNT=$(echo "$OUTPUT" | grep -c "^WARN:" || true)
if [[ "$WARN_COUNT" -ge 4 ]]; then
    pass "Case 12: multiple WARN lines emitted ($WARN_COUNT)"
else
    fail "Case 12: expected >=4 WARN lines, got $WARN_COUNT. Output: $OUTPUT"
fi

# Case 13 (Structural): dispatcher frontmatter present in first 10 lines.
SELF="$AGENTS_ROOT/tests/feature-973-review-e2e-coverage.sh"
if head -10 "$SELF" | grep -q "^# Tests: bin/review-e2e-coverage"; then
    pass "Case 13: '# Tests: bin/review-e2e-coverage' present in first 10 lines"
else
    fail "Case 13: missing '# Tests:' frontmatter in first 10 lines"
fi
if head -10 "$SELF" | grep -qE "^# Tags:.*scope:issue-specific"; then
    pass "Case 13: '# Tags:' with scope:issue-specific present"
else
    fail "Case 13: missing '# Tags: scope:issue-specific' in first 10 lines"
fi
if head -30 "$SELF" | grep -q "^# L3 gap"; then
    pass "Case 13: '# L3 gap' block present (L2 fallback documentation)"
else
    fail "Case 13: missing '# L3 gap' block — required by rules/test.md for L2 tests"
fi

# Case 14 (Error): --base resolves to a ref with no merge-base → SKIPPED, exit 0.
REPO14=$(make_repo)
git -C "$REPO14" checkout -q -b feature14

EXIT_CODE=0
OUTPUT=$(run_script "$REPO14" --base nonexistent-sha-xyz-99999) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 14: exits 0 when merge-base unresolvable"
else
    fail "Case 14: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"
fi
if echo "$OUTPUT" | grep -qE "SKIPPED" && echo "$OUTPUT" | grep -qE "merge-base|unresolved"; then
    pass "Case 14: SKIPPED emitted for unresolvable merge-base"
else
    fail "Case 14: expected SKIPPED with merge-base hint. Output: $OUTPUT"
fi
