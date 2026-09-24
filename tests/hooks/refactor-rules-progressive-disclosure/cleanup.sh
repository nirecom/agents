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

# (c) rules/coding.md is de-injected by #2037, so the shape this case pins is the
#     OPPOSITE of what it pinned before: the hub must now open with a frontmatter
#     block, exactly as rules/docs.md has since #1651. The membership itself
#     (coding.md is an ON_DEMAND_READERS key, not an EXPECTED_UNCONDITIONAL entry)
#     is owned by the policy SSOT and asserted in T1-B/T1-D — repeating it here
#     would give the fact two owners. What is left for this case is the one thing
#     T1-B cannot see: whether the *file on disk* still carries the marker comment
#     that makes the de-injection legible to a human opening it.
for hub in rules/coding.md; do
    abs="$REPO_ROOT/$hub"
    if [ ! -f "$abs" ]; then
        fail "T9: $hub carries on-demand frontmatter" "file not found"
        continue
    fi
    first_line="$(head -1 "$abs")"
    if [ "$first_line" != "---" ]; then
        fail "T9: $hub carries on-demand frontmatter" "line 1 is '$first_line', not '---' — the hub is still injected into every session and #2037's saving never lands"
    else
        pass "T9: $hub opens with a frontmatter block (de-injected)"
    fi
    if grep -qE '<!--[[:space:]]*injection:[[:space:]]*on-demand-only' "$abs"; then
        pass "T9: $hub carries the on-demand marker comment"
    else
        fail "T9: $hub carries the on-demand marker comment" "no '<!-- injection: on-demand-only -->' line — the reserved paths: token alone reads as an ordinary glob to anyone opening the file"
    fi
done

# (d) The coding hub's `## Sub-rules` section, checked as the hub becomes on-demand.
#     The hub and its sub-rules load by independent mechanisms: each sub-rule carries its
#     own `paths:` globs, so it is injected on a file match whether or not the hub was
#     Read. A reader who does not know that will assume de-injecting the hub took the
#     three language rules with it and start duplicating their content back into skills.
#     So the section must (i) still list all three and (ii) say the loading is independent.
#     The globs themselves are NOT restated here — T1-A in paths-frontmatter.sh pins them
#     verbatim and is the single owner of that fact (CPR-SSOT).
CODING_HUB="$REPO_ROOT/rules/coding.md"
SUBRULES="coding/python.md coding/nodejs.md coding/file-split.md"
if [ ! -f "$CODING_HUB" ]; then
    fail "T9d: rules/coding.md sub-rules section" "file not found"
else
    sub_missing=""
    for sub in $SUBRULES; do
        grep -qF "$sub" "$CODING_HUB" || sub_missing="$sub_missing $sub"
    done
    if [ -z "$sub_missing" ]; then
        pass "T9d: rules/coding.md still lists all three sub-rules"
    else
        fail "T9d: rules/coding.md still lists all three sub-rules" "not mentioned:$sub_missing — the sub-rules are still injected by their own paths:, but nothing in the hub says where to find them"
    fi
    # Scoped to the `## Sub-rules` section only. A whole-file grep is a false green here:
    # the hub already says "regardless of `core.fileMode`" in an unrelated paragraph.
    subsec="$(awk '/^## Sub-rules/{f=1} f{print} f && /^## /  && !/^## Sub-rules/{exit}' "$CODING_HUB")"
    if printf '%s\n' "$subsec" | grep -qiE 'independent|regardless of|unaffected|on (its|their) own|still (load|inject|arrive)|own .?paths.?'; then
        pass "T9d-independence: the section states the sub-rules load independently of the hub"
    else
        fail "T9d-independence: the section states the sub-rules load independently of the hub" "no such statement — with the hub de-injected, a reader has no way to tell that coding/python.md et al. still arrive on a file match"
    fi
fi

echo ""
