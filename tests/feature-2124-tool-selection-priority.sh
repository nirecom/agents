#!/usr/bin/env bash
# tests/feature-2124-tool-selection-priority.sh
# Tests: rules/shell-commands.md, skills/write-code/SKILL.md, skills/write-tests/SKILL.md, hooks/lib/rules-injection-policy.js
# Tags: rules, prompt, injection, dispatch, scope:issue-specific, pwsh-not-required, TL2

set -uo pipefail

# THE INCIDENT. While auto mode is active the platform injects a system-reminder telling the
# model to do its file work through Bash — cat, sed, heredocs, redirects — "rather than using
# the dedicated Read, Edit, or Write tools". The limited-scope IR analysis in
# hooks/lib/bash-write-patterns/ cannot classify those shapes safely, so they land on ask or
# block. Following the reminder produces friction: the session that surveyed #2124 was itself
# blocked by enforce-worktree on a `bash /dev/stdin` heredoc.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# THE ROOT CAUSE is a hole inside the norm layer, not the reminder. rules/shell-commands.md
# already governs WHAT may be issued through the Bash tool (the Command-Line Issuance
# Discipline's prohibited-literal table), but nothing anywhere says WHETHER file reading and
# writing should go through Bash at all. The same hole shows up one level down: the Discipline
# orders every compound form into "a scratchpad script, invoked as a single bash <path> call"
# and never says how that script gets created. A norm whose own instructions cannot be
# followed without tripping a guard is an incomplete norm (CPR-WPH, CPR-UNV).

RULES_REL="rules/shell-commands.md"
RULES="$AGENTS_DIR/$RULES_REL"

# THE CONTRACT UNDER TEST. One `## Tool Selection Priority` section is added to
# rules/shell-commands.md immediately BEFORE Command-Line Issuance Discipline, carrying five
# normative elements: reading defaults to Read/Glob/Grep; writing file content through shell
# syntax (heredoc, redirect, in-place edit) is not done in Bash; Bash-launched dedicated tools
# whose purpose IS writing (formatters, generators, dependency managers, git commit) are exempt
# as a CLASS, not as a list of examples; the scratchpad script the next section demands is
# itself created with the Write tool; and this section outranks a platform-injected reminder
# that says otherwise. The file stays in EXPECTED_UNCONDITIONAL so all three delivery routes
# receive it, and BOTH general-purpose dispatch sites — write-code WCD-4 and write-tests WT-6 —
# get the same wording INSIDE the dispatch step itself, not merely somewhere in the file.

POLICY="$AGENTS_DIR/hooks/lib/rules-injection-policy.js"

# OUT OF SCOPE: conditional providers in the verbose-prompt style (session-start receives no
# permission-mode field, so a provider could only fail open); suppressing the platform
# reminder itself; and the local "Write tool (never Bash)" directives in agents/*.md and the
# individual SKILL.md files — those carry a different reason (never turn untrusted text into
# shell syntax) and deliberately survive alongside the new class.

NEW_HEADING='## Tool Selection Priority'
NEXT_HEADING='## Command-Line Issuance Discipline'

# LAYER. Static/structural only: rules and SKILL.md files are read as TEXT, the injection
# policy SSOT is parsed as DATA (never require()d — U11 guards that), and nothing is injected,
# dispatched, or executed as a prompt. The negative controls run the SAME predicates over
# throwaway fixture files under $FIXROOT — never over rules/shell-commands.md or a real SKILL.md.

RULES_LINE_BUDGET=100

# SKIPPED: driving a real session with auto mode on and observing whether the section arrives
#          and whether the model follows it over the platform reminder.
# Because: the reminder's injection cadence is platform-controlled and unobservable from the
#          hook payload, so there is no deterministic trigger a test could arrange.

PASS=0
FAIL=0

# TL3 gap (what this test does NOT catch):
# - Whether the norm is actually injected into a live session's context at all — only the
#   policy declaration is read here, never the loader's behaviour.
# - Whether the norm outranks the platform reminder in practice once both are present: the
#   reminder is re-injected mid-session and is the more recent text.
# - Whether a general-purpose subagent really performs the Read its dispatch line orders.
# Closest-to-action mitigation: the real-loader gate in tests/TL3-rules-injection-off-switch.sh
# and the per-session receipt written by hooks/instructions-loaded-audit.js.

ROWS=0
ROWS_EXPECTED=51   # U2 real: 5 + U2N fixture controls: 16 (4 elements x canonical/inverted = 8,
                   # plus tool-exception's 8: canonical, inverted, no-class, 4 x partial-*,
                   # contradicted) + U6: 2 + U7: 6 (incl. out-of-block) + U8b named sites: 2
                   # + U6g (#2140/#2141 rule-position control): 4 (in-block, out-of-block,
                   # negated, mixed) + U6h (dispatch_timing_updated negation control): 2
                   # (negated, mixed) + UAL (#2140/#2141 review finding C1, A-layer directive
                   # pin, cycle3 C5 / review-security C5 negation guard): 7 (real, in-block,
                   # out-of-block, deleted, negated, mixed, heading-existence) + U6i
                   # (#2140/#2141 review finding C2, dispatch-read timing/ordering): 7 (4 real
                   # sites + 3 wrong-way negative fixtures). U6c-f/U10a-d/U11a-b are non-loop
                   # single assertions, no ROWS.

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name -- want [$want] got [$got]"; FAIL=$((FAIL + 1)); fi
}

node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

FIXROOT="$(mktemp -d "${TMPDIR:-/tmp}/tsp-2124.XXXXXX")" || { echo "FAIL: harness -- mktemp -d failed"; exit 1; }
trap 'rm -rf "$FIXROOT"' EXIT

heading_lineno() { # <file> <heading-literal> -> 1-based line number, or 0
    local n=""
    [ -f "$1" ] && n="$(grep -n -m1 -Fx -- "$2" "$1" 2>/dev/null | cut -d: -f1)"
    printf '%s' "${n:-0}"
}

# The heading line plus every line up to (not including) the next `## ` heading. An absent
# heading yields empty output, which is what makes U2's rows report "the section is missing"
# instead of crashing on an unset variable.
section_body() { # <file> <heading-literal>
    local f="$1" h="$2" start rel end total
    [ -f "$f" ] || return 0
    start="$(heading_lineno "$f" "$h")"
    [ "$start" != "0" ] || return 0
    total="$(wc -l < "$f" | tr -d ' ')"
    rel="$(tail -n +"$((start + 1))" "$f" | grep -n -m1 -E '^## ' | cut -d: -f1)"
    if [ -n "$rel" ]; then end=$((start + rel - 1)); else end="$total"; fi
    sed -n "${start},${end}p" "$f"
}

PART_DIR="$AGENTS_DIR/tests/feature-2124-tool-selection-priority"

. "$AGENTS_DIR/tests/lib/read-directive-negation.sh"
. "$PART_DIR/section-contract.sh"
. "$PART_DIR/injection-policy.sh"
. "$PART_DIR/dispatch-timing.sh"

# EXECUTED-ROW BUDGET. Every table-driven loop in the part files increments ROWS; U9 asserts
# the exact total. An empty table, a drifted heredoc delimiter, or an early return in front of
# a loop all leave a file that counts only failures reporting green.
assert_eq "U9: U2 / U2N / U6 / U7 / U8b together executed every case row (a short count means an empty or unreachable table)" \
    "$ROWS_EXPECTED" "$ROWS"

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
