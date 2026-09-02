#!/usr/bin/env bash
# tests/feature-2140-fork-dispatch-shell-commands.sh
# Tests: skills/review-tests/SKILL.md, skills/refactor-prompts/SKILL.md, rules/shell-commands.md
# Tags: rules, prompt, dispatch, fork, scope:issue-specific, pwsh-not-required, TL2

set -uo pipefail

# THE INCIDENT (#2140/#2141). review-tests runs `context: fork` — a subagent execution that
# does not inherit rule injection the way the main conversation or a named-agent dispatch does.
# RT-2's incident: the subagent issued a shell-syntax file-write instead of the Write tool,
# because rules/shell-commands.md's Tool Selection Priority was not effectively available at
# Bash-issuance time. The fix adds a defensive Read directive at the TOP of review-tests'
# `## Procedure`, ahead of every step including RT-0, and rewords RT-2 itself to point at that
# rule instead of re-describing shell mechanics inline. refactor-prompts (also `context: fork`)
# gets a parallel one-sentence reminder ahead of its own shell-command-substitution step.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVIEW_TESTS_SKILL="$AGENTS_DIR/skills/review-tests/SKILL.md"
REFACTOR_PROMPTS_SKILL="$AGENTS_DIR/skills/refactor-prompts/SKILL.md"

# LAYER. Static/structural only: both SKILL.md files are read as TEXT; nothing is dispatched,
# injected, or executed as a prompt. Negative controls run the SAME predicates over throwaway
# fixture files under $FIXROOT — never over the two real skill files.

PASS=0
FAIL=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name -- want [$want] got [$got]"; FAIL=$((FAIL + 1)); fi
}

FIXROOT="$(mktemp -d "${TMPDIR:-/tmp}/fdsc-2140.XXXXXX")" || { echo "FAIL: harness -- mktemp -d failed"; exit 1; }
trap 'rm -rf "$FIXROOT"' EXIT

# --- Shared structural helpers (CPR-SSOT: every part file below reuses these; none re-greps
# the raw file with a bespoke one-off pattern). ---

marker_lineno() { # <file> <ere> -> 1-based lineno of the first match, or 0
    local n
    [ -f "$1" ] && n="$(grep -n -m1 -E -- "$2" "$1" 2>/dev/null | cut -d: -f1)"
    printf '%s' "${n:-0}"
}

range_block() { # <file> <start-lineno> <end-lineno-exclusive, or 0 for EOF>
    local f="$1" start="$2" end="$3" total
    [ "$start" != "0" ] || return 0
    if [ "$end" = "0" ]; then
        total="$(wc -l < "$f" | tr -d ' ')"
        sed -n "${start},${total}p" "$f"
    else
        sed -n "${start},$((end - 1))p" "$f"
    fi
}

# The two-trigger directive predicate (CPR-SSOT with dispatch-timing.sh's dispatch_timing_updated,
# specialized to a whole-file scan rather than a dispatch-block scan): "Read `rules/shell-
# commands.md`" plus BOTH "before ... Bash command" and "before ... writ[e/ing]" on the same line.
directive_lineno() { # <file> -> 1-based lineno, or 0
    local f="$1" hit
    [ -f "$f" ] || { printf '0'; return; }
    hit="$(grep -n -F -- 'rules/shell-commands.md' "$f" 2>/dev/null \
        | grep -F -- 'Read' \
        | grep -Ei -- 'before (the )?(first )?Bash command' \
        | grep -Ei -- 'before (writing|you write|it writes|any (file )?write|creating or writing)' \
        | head -n1)"
    [ -n "$hit" ] || { printf '0'; return; }
    # A line that FORBIDS the Read carries the same tokens -- tests/lib/read-directive-negation.sh.
    [ "$(line_negates_read "${hit#*:}")" = "no" ] || { printf '0'; return; }
    printf '%s' "${hit%%:*}"
}
directive_exists() { [ "$(directive_lineno "$1")" != "0" ] && printf 'yes' || printf 'no'; }

frontmatter_has_context_fork() { # <file> -> yes|no
    local f="$1" fm_end
    [ -f "$f" ] || { printf 'no'; return; }
    fm_end="$(tail -n +2 "$f" | grep -n -m1 -E '^---$' | cut -d: -f1)"
    [ -n "$fm_end" ] || { printf 'no'; return; }
    if sed -n "1,$((fm_end + 1))p" "$f" | grep -qE '^context: *fork$'; then
        printf 'yes'
    else
        printf 'no'
    fi
}

ROWS=0
ROWS_EXPECTED=20  # G1..G18 (plus G17c) negative-control rows -- see negative-controls.sh for the per-row breakdown.

# TL3 gap: whether a `context: fork` execution actually READS the top-of-Procedure directive at
# Bash-issuance time, or whether RT-2's reworded body stops a subagent re-deriving banned shell
# forms from first principles, is not covered here -- only the skill's own text is inspected.
# Closest-to-action mitigation: a real fork-dispatch E2E (rules/test/claude-e2e.md) and the
# per-session receipt written by hooks/instructions-loaded-audit.js.

PART_DIR="$AGENTS_DIR/tests/feature-2140-fork-dispatch-shell-commands"

. "$AGENTS_DIR/tests/lib/read-directive-negation.sh"
. "$PART_DIR/review-tests-checks.sh"
. "$PART_DIR/refactor-prompts-checks.sh"
. "$PART_DIR/negative-controls.sh"

# EXECUTED-ROW BUDGET. Every table-driven / row-incrementing check in negative-controls.sh
# increments ROWS; this asserts the exact total, so an empty table or an early return upstream
# reports as a short count instead of a silent pass.
assert_eq "G-budget: negative-controls.sh executed every planned row (a short count means an empty or unreachable table)" \
    "$ROWS_EXPECTED" "$ROWS"

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
