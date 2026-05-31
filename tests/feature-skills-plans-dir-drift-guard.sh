#!/usr/bin/env bash
# Tests: agents/., skills/_shared/confirm-plan.md, skills/_shared/resolve-plans-dir.md, skills/agents
# Tags: skills-plans-dir-drift-guard
# Drift guard: ensures SKILL.md and agent prompt files do not hardcode
# ~/.workflow-plans or use ${WORKFLOW_PLANS_DIR:-...} outside Bash code blocks.
#
# Rationale: LLMs do NOT pipe Read/Write tool arguments through bash, so any
# ~/.workflow-plans or ${WORKFLOW_PLANS_DIR:-...} expression appearing as
# prose in a SKILL.md is taken literally — the tilde is never expanded, and
# the bash parameter expansion never runs. Both forms must be replaced with
# the <PLANS_DIR> placeholder (resolved by Step 0 preamble).
#
# Inside fenced bash code blocks both patterns are CORRECT (bash expands
# them), so this test strips fenced code block content before grepping.
#
# Expected behavior: FAILS before source code changes (SKILL.md files still
# hold banned patterns); PASSES after the Step 0 inlining migration completes.
set -u

# Timeout guard — portable across macOS (no `timeout`) and Linux.
if [ -z "${_TIMEOUT_WRAPPED:-}" ]; then
    export _TIMEOUT_WRAPPED=1
    if command -v timeout >/dev/null 2>&1; then
        exec timeout 120 bash "$0" "$@"
    else
        exec perl -e 'alarm 120; exec @ARGV' -- bash "$0" "$@"
    fi
fi

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 60 "$@"
    else
        perl -e 'alarm 60; exec @ARGV' -- "$@"
    fi
}

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Files exempted from the scan (matched by path suffix):
#   - skills/_shared/resolve-plans-dir.md : canonical documentation of both
#     patterns (defines and explains <PLANS_DIR> resolution).
#   - skills/_shared/confirm-plan.md      : single rationale-sentence mention
#     of ~/.workflow-plans/ when explaining the breadcrumb behavior.
EXEMPT_SUFFIXES=(
    "skills/_shared/resolve-plans-dir.md"
    "skills/_shared/confirm-plan.md"
)

is_exempt() {
    local path="$1"
    local suffix
    for suffix in "${EXEMPT_SUFFIXES[@]}"; do
        case "$path" in
            *"$suffix") return 0 ;;
        esac
    done
    return 1
}

# Strip fenced code block content (lines between ``` fences). Both forms
# of the banned patterns are legal inside bash code blocks, where bash does
# expand them.
strip_code_blocks() {
    awk 'BEGIN{in_block=0} /^```/{in_block=!in_block; next} !in_block{print}'
}

echo "=== skills/agents plans-dir drift guard ==="
echo "AGENTS_DIR: $AGENTS_DIR"
echo ""

violations_file=$(mktemp)
trap 'rm -f "$violations_file"' EXIT

# Enumerate every .md under skills/ and agents/. find -print0 + while-read -d ''
# survives spaces / unusual filenames; sorted for deterministic output.
scanned=0
exempted=0
while IFS= read -r -d '' file; do
    if is_exempt "$file"; then
        exempted=$((exempted + 1))
        continue
    fi
    scanned=$((scanned + 1))

    stripped="$(strip_code_blocks < "$file")"

    # Pattern A: literal ~/.workflow-plans (hardcoded path in prose).
    matches_a="$(printf '%s\n' "$stripped" | grep -n '~/\.workflow-plans' || true)"
    if [ -n "$matches_a" ]; then
        while IFS= read -r line; do
            printf '%s:A:%s\n' "$file" "$line" >> "$violations_file"
        done <<< "$matches_a"
    fi

    # Pattern B: ${WORKFLOW_PLANS_DIR:- (broken bash expansion in prose).
    # Match the literal '${WORKFLOW_PLANS_DIR:-' substring using fgrep semantics.
    matches_b="$(printf '%s\n' "$stripped" | grep -n -F '${WORKFLOW_PLANS_DIR:-' || true)"
    if [ -n "$matches_b" ]; then
        while IFS= read -r line; do
            printf '%s:B:%s\n' "$file" "$line" >> "$violations_file"
        done <<< "$matches_b"
    fi
done < <(run_with_timeout find "$AGENTS_DIR/skills" "$AGENTS_DIR/agents" -type f -name '*.md' -print0 2>/dev/null | sort -z)

violation_count=$(wc -l < "$violations_file" | tr -d ' ')

echo "Scanned files: $scanned"
echo "Exempted files: $exempted"
echo "Violations: $violation_count"
echo ""

if [ "$violation_count" -gt 0 ]; then
    echo "--- Violations (file:pattern:line:content) ---"
    cat "$violations_file"
    echo ""
    echo "FAIL: $violation_count banned-pattern occurrence(s) found outside code blocks."
    echo "      Pattern A = literal '~/.workflow-plans' in prose"
    echo "      Pattern B = literal '\${WORKFLOW_PLANS_DIR:-' in prose"
    echo "      Replace each occurrence with the <PLANS_DIR> placeholder, or move"
    echo "      it inside a fenced bash code block where bash will expand it."
    exit 1
fi

echo "PASS: No banned patterns found outside fenced code blocks."
exit 0
