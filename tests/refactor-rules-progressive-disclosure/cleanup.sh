#!/usr/bin/env bash
# Tests: rules/coding.md, rules/docs.md
# Tags: rules, cleanup, scope:common
# Part of tests/refactor-rules-progressive-disclosure.sh — sourced, not run directly.
# Test 9: post-conversion cleanup — relocation stub deleted, hub files unconditional.

echo "=== Test 9: Cleanup and hub-file invariants ==="

# (a) rules/file-investigation.md was a one-line relocation stub — must be gone.
if [ -e "$REPO_ROOT/rules/file-investigation.md" ]; then
    fail "T9: rules/file-investigation.md deleted" "relocation stub still exists"
else
    pass "T9: rules/file-investigation.md deleted"
fi

# (b) Hub files must not mention the obsolete globs: key anywhere (including the
#     '## Sub-rules (path-scoped via `globs:`)' heading).
for hub in rules/coding.md rules/docs.md; do
    abs="$REPO_ROOT/$hub"
    if [ ! -f "$abs" ]; then
        fail "T9: $hub globs: free" "file not found"
        continue
    fi
    if grep -nF 'globs:' "$abs" >/dev/null 2>&1; then
        fail "T9: $hub globs: free" "still contains 'globs:' at line(s): $(grep -nF 'globs:' "$abs" | cut -d: -f1 | tr '\n' ' ')"
    else
        pass "T9: $hub contains no 'globs:' string"
    fi
done

# (c) rules/coding.md is an unconditional hub: no frontmatter block at all
#     (line 1 != ---). rules/docs.md was deliberately de-injected by #1651 — its
#     reserved-token frontmatter is asserted by T1-B, not here. The general
#     "carries no paths: key" invariant for the whole unconditional set is
#     derived from the policy SSOT in T1-D; this case keeps the stricter
#     no-frontmatter-at-all shape for the coding hub specifically.
for hub in rules/coding.md; do
    abs="$REPO_ROOT/$hub"
    if [ ! -f "$abs" ]; then
        fail "T9: $hub has no frontmatter" "file not found"
        continue
    fi
    first_line="$(head -1 "$abs")"
    if [ "$first_line" = "---" ]; then
        fail "T9: $hub has no frontmatter" "line 1 is '---' — this hub is injected unconditionally and must carry no frontmatter block"
    else
        pass "T9: $hub has no frontmatter (stays unconditional)"
    fi
done

echo ""
