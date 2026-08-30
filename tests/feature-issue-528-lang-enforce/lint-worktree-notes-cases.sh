#!/bin/bash
# tests/feature-issue-528-lang-enforce/lint-worktree-notes-cases.sh
# Tests: hooks/lib/lint-worktree-notes-lang.js
# Tags: worktree, docs, lint, scope:issue-specific
# Sourced by ../feature-issue-528-lang-enforce.sh — helpers come from there.
# lang-check: ignore -- this file intentionally contains CJK test fixtures for CJK-detection tests

# ============================================================================
# Group 2 — lint-worktree-notes-lang.js unit tests
# ============================================================================

echo ""
echo "=== Group 2: lint-worktree-notes-lang.js ==="

if [ "$(src_present "$LINT_LIB")" != "ok" ]; then
    echo "SKIP G2: hooks/lib/lint-worktree-notes-lang.js not yet implemented (RED phase)"
else
    # isPrivateRepo defaults to false in the cases below, so `public` is the field
    # every one of them resolves to.
    CFG_HIST_EN='{"public":"english","private":"any"}'
    CFG_HIST_JA='{"public":"japanese","private":"any"}'

    # T8: no CJK in History Notes (english config) → empty violations
    _t8_file="$(write_tmp_file WORKTREE_NOTES.md <<'EOF'
## History Notes
- English bullet
- Another English bullet

## Changelog Notes
- (none)
EOF
)"
    _t8_count="$(lint_count "$_t8_file" "$CFG_HIST_EN" '{}')"
    if [ "$_t8_count" = "0" ]; then
        pass "T8: no CJK in History (english) → 0 violations"
    else
        fail "T8: expected 0 violations, got: $_t8_count"
    fi

    # T9: Japanese in History Notes (english config) → violation
    _t9_file="$(write_tmp_file WORKTREE_NOTES.md <<'EOF'
## History Notes
- 日本語のバグ修正

## Changelog Notes
- (none)
EOF
)"
    _t9_count="$(lint_count "$_t9_file" "$CFG_HIST_EN" '{}')"
    if [ -n "$_t9_count" ] && [ "$_t9_count" -ge 1 ]; then
        pass "T9: Japanese in History (english) → violation detected"
    else
        fail "T9: expected >=1 violation, got: $_t9_count"
    fi

    # T10: Japanese in History Notes (japanese config) → no violation
    _t10_count="$(lint_count "$_t9_file" "$CFG_HIST_JA" '{}')"
    if [ "$_t10_count" = "0" ]; then
        pass "T10: Japanese in History (japanese config) → no violation"
    else
        fail "T10: expected 0 violations, got: $_t10_count"
    fi

    # T11: Japanese in Changelog Notes (public=english) → violation
    _t11_file="$(write_tmp_file WORKTREE_NOTES.md <<'EOF'
## History Notes
- (none)

## Changelog Notes
- 公開向けの変更点
EOF
)"
    # Use public-context options (caller passes the repo visibility)
    _t11_cfg='{"public":"english","private":"any"}'
    _t11_count="$(lint_count "$_t11_file" "$_t11_cfg" '{"isPrivateRepo":false}')"
    if [ -n "$_t11_count" ] && [ "$_t11_count" -ge 1 ]; then
        pass "T11: Japanese in Changelog (public=english, public repo) → violation"
    else
        fail "T11: expected >=1 violation, got: $_t11_count"
    fi

    # T12: ### History Notes (3-level heading) → NOT matched, no violation
    _t12_file="$(write_tmp_file WORKTREE_NOTES.md <<'EOF'
### History Notes
- 日本語の説明

## Changelog Notes
- (none)
EOF
)"
    _t12_count="$(lint_count "$_t12_file" "$CFG_HIST_EN" '{}')"
    if [ "$_t12_count" = "0" ]; then
        pass "T12: ### History Notes (3-level) → not matched, 0 violations"
    else
        fail "T12: expected 0 violations for 3-level heading, got: $_t12_count"
    fi

    # T13: mixed bullet `- Fix the バグ` → violation (single CJK char)
    _t13_file="$(write_tmp_file WORKTREE_NOTES.md <<'EOF'
## History Notes
- Fix the バグ

## Changelog Notes
- (none)
EOF
)"
    _t13_count="$(lint_count "$_t13_file" "$CFG_HIST_EN" '{}')"
    if [ -n "$_t13_count" ] && [ "$_t13_count" -ge 1 ]; then
        pass "T13: mixed bullet w/ single CJK → violation"
    else
        fail "T13: expected >=1 violation, got: $_t13_count"
    fi

    # T15: error message trims leading "- " from bullet text
    _t15_json="$(lint_json "$_t13_file" "$CFG_HIST_EN" '{}')"
    # The violation object should contain a representation of the bullet text
    # without a leading "- ". We check that "Fix the" appears and that the
    # serialized JSON does not contain "- Fix the" prefix on the bullet field.
    if echo "$_t15_json" | grep -q "Fix the" && \
       ! echo "$_t15_json" | grep -q '"- Fix the'; then
        pass "T15: violation text trims leading '- '"
    else
        fail "T15: expected trimmed bullet, got: $_t15_json"
    fi
fi
