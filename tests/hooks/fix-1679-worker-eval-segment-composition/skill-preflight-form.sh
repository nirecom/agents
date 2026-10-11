# tests/hooks/fix-1679-worker-eval-segment-composition/skill-preflight-form.sh
# Tests: skills/issue-close-finalize/SKILL.md, hooks/enforce-worktree.js
# Tags: enforce-worktree, allowlist, issue-close-finalize, TL2, pwsh-not-required, scope:issue-specific
#
# Sourced by tests/hooks/fix-1679-worker-eval-segment-composition.sh.
# #2561: the pre-flight call exactly as SKILL.md's "Pre-flight (gate)" section spells it
# (the first code span of that paragraph) must pass the guard from the main worktree.
# The span is read from the worktree copy, so a reworded instruction is what gets tested.

# shellcheck source=../../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

# Markers sit at top level (depth-checked), wrapping the function definitions.
case_begin "skill-preflight-span" "skills/issue-close-finalize/SKILL.md"
sk_extract_preflight_span() {
    local skill="$SCRIPT_CHECKOUT_ROOT/skills/issue-close-finalize/SKILL.md"
    node -e '
const t = require("fs").readFileSync(process.argv[1], "utf8").split(/\r?\n/);
const i = t.findIndex((l) => /^###\s+Pre-flight/.test(l));
const body = i < 0 ? "" : t.slice(i + 1).find((l) => l.trim() !== "") || "";
const m = /`([^`]*pre-flight\.sh[^`]*)`/.exec(body);
process.stdout.write(m ? m[1] : "");
' "$skill" 2>/dev/null
}
case_end

case_begin "skill-preflight-guard" "hooks/enforce-worktree.js"
sk_assert_preflight_allowed() {
    local cmd="$1" rc=0
    guard "$cmd" || rc=$?
    assert_allow "SK2561-1: SKILL.md pre-flight form '$cmd' → ALLOW from the main worktree" "$rc"
}
case_end

test_skill_form_cases() {
    echo "=== SK: SKILL.md pre-flight call form vs the guard ==="
    local cmd
    cmd="$(sk_extract_preflight_span)"
    if [ -z "$cmd" ]; then
        fail "SK2561-1: SKILL.md Pre-flight section has a pre-flight.sh call span (none found)"
        return
    fi
    sk_assert_preflight_allowed "$cmd"
}
