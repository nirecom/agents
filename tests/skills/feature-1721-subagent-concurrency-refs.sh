#!/usr/bin/env bash
# tests/skills/feature-1721-subagent-concurrency-refs.sh
# Tests: skills/_shared/subagent-concurrency.md, skills/workflow-init/SKILL.md, skills/review-code-security/SKILL.md, skills/worktree-end/SKILL.md, skills/issue-close-finalize/SKILL.md, skills/_shared/codex-review-loop.md, skills/write-tests/SKILL.md, skills/review-tests/SKILL.md, skills/make-outline-plan/SKILL.md, skills/make-detail-plan/SKILL.md, skills/clarify-intent/SKILL.md
# Tags: subagent-concurrency, skill-orchestration, static, regression, TL1, scope:issue-specific
# Issue #1721 — dispatch concurrency policy (SC-P parallel / SC-S serial / SC-W wait) is stated once in skills/_shared/subagent-concurrency.md and referenced from each dispatch site instead of re-explained inline.
# Two regression axes: the SYMMETRIC PAIR (worktree-end WE-9 and issue-close-finalize's initial delegation pass are the same serial-by-dependency shape — annotating one and forgetting the other IS the #1721 defect, so either span failing fails the whole run) and SYNTAX DRIFT (the annotation must be the exact literal `Serial by dependency (SC-S):`; a variant like `(SC-S, path)` must FAIL).
# TL1 (static): the subject is prompt text, read directly off disk — no live LLM call, no runtime behavior.
# TL3 gap (what this test does NOT catch): an orchestrator that reads the SC-P/SC-S annotations yet still dispatches independent subagents sequentially across turns at runtime.
# Closest-to-action mitigation: manual review during /review-code of every new or edited SKILL.md dispatch block against the SC-P rule in skills/_shared/subagent-concurrency.md.
# Group functions live in the sibling folder feature-1721-subagent-concurrency-refs/ (sourced below, never run standalone).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHARED_REL="skills/_shared/subagent-concurrency.md"
SHARED_MD="$AGENTS_DIR/$SHARED_REL"

# shellcheck source=../lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

# Overrides the harness run_with_timeout to keep the in-process timeout/perl path.
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/sc-refs-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# The serial annotation literal, matched through the trailing colon.
SC_S_LITERAL='Serial by dependency (SC-S):'
SC_S_LOOSE='Serial by dependency (SC-S'

has_prefix_line() {
    awk -v p="$2" 'substr($0, 1, length(p)) == p { found = 1; exit } END { exit !found }' "$1"
}

# Block = [start-prefix, end-prefix). Anchors are literal line prefixes, not
# regexes, so `.` / `+` in step labels cannot be reinterpreted. A never-matching
# end anchor would swallow the rest of the file and turn a scoped grep into a
# false green, so every caller asserts the end anchor exists independently.
# Program held in a heredoc, not a multi-line quote, so the case-marker parser
# can still split this file into cases.
EXTRACT_BLOCK_AWK=$(cat <<'AWK'
function pre(line, p) { return substr(line, 1, length(p)) == p }
!inb && pre($0, s) { inb = 1 }
inb && seen && pre($0, e) { exit }
inb { seen = 1; print }
AWK
)
extract_block() {
    awk -v s="$2" -v e="$3" "$EXTRACT_BLOCK_AWK" "$1"
}

# Extracts the block into a temp file and sets the BLOCK_FILE global to its path.
# Returns non-zero (having already reported the failure) when the block cannot be
# scoped. BLOCK_FILE is used instead of stdout so that this helper's own fail()
# output is never captured into the caller's variable and swallowed.
# $1=label $2=abs-path $3=start $4=end $5=max-lines
BLOCK_FILE=""
block_to_file() {
    local label="$1" path="$2" start="$3" end="$4" maxl="$5" out lines
    BLOCK_FILE=""
    if [ ! -f "$path" ]; then
        fail "$label: file missing: ${path#$AGENTS_DIR/}"
        return 1
    fi
    if ! has_prefix_line "$path" "$end"; then
        fail "$label: end anchor '$end' not found in ${path#$AGENTS_DIR/} (block scoping unreliable)"
        return 1
    fi
    out="$TMPD/block-$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '_').md"
    extract_block "$path" "$start" "$end" > "$out"
    lines=$(wc -l < "$out" | tr -d '[:space:]')
    [ -n "$lines" ] || lines=0
    if [ "$lines" -eq 0 ]; then
        fail "$label: start anchor '$start' not found in ${path#$AGENTS_DIR/}"
        return 1
    fi
    if [ "$lines" -gt "$maxl" ]; then
        fail "$label: extracted block is $lines lines (max $maxl) — scoping looks broken"
        return 1
    fi
    BLOCK_FILE="$out"
    return 0
}

# Fragments only define group functions and their tables; a missing fragment
# is a hard stop, since its groups would otherwise silently vanish from the run.
FRAG_DIR="$AGENTS_DIR/tests/skills/feature-1721-subagent-concurrency-refs"
for frag in shared-doc parallel-refs serial-annotation serial-syntax negatives-and-wait; do
    if [ ! -f "$FRAG_DIR/$frag.sh" ]; then
        fail "fragment missing: $FRAG_DIR/$frag.sh"
        echo ""
        echo "Total: PASS=$PASS FAIL=$FAIL"
        exit 1
    fi
done

# Each span sources the fragment it calls (definitions only, so re-sourcing is
# idempotent): deleting any span leaves no orphan call in the others.
case_begin "shared-doc" "skills/_shared/subagent-concurrency.md"
# shellcheck source=/dev/null
. "$FRAG_DIR/shared-doc.sh"
group_shared_doc
group_sc_p_independence
case_end

case_begin "parallel-refs-workflow-init" "skills/workflow-init/SKILL.md"
# shellcheck source=/dev/null
. "$FRAG_DIR/parallel-refs.sh"
group_parallel_refs skills/workflow-init/SKILL.md
case_end

case_begin "parallel-refs-review-code-security" "skills/review-code-security/SKILL.md"
# shellcheck source=/dev/null
. "$FRAG_DIR/parallel-refs.sh"
group_parallel_refs skills/review-code-security/SKILL.md
group_b_scp_ref_probe
case_end

case_begin "serial-annotation-worktree-end" "skills/worktree-end/SKILL.md"
# shellcheck source=/dev/null
. "$FRAG_DIR/serial-annotation.sh"
group_serial_annotation skills/worktree-end/SKILL.md
case_end

case_begin "serial-annotation-issue-close-finalize" "skills/issue-close-finalize/SKILL.md"
# shellcheck source=/dev/null
. "$FRAG_DIR/serial-annotation.sh"
group_serial_annotation skills/issue-close-finalize/SKILL.md
case_end

case_begin "serial-syntax" "skills/_shared/subagent-concurrency.md"
# shellcheck source=/dev/null
. "$FRAG_DIR/serial-syntax.sh"
group_serial_syntax_drift
group_strict_matcher_probe
group_drift_filter_probe
case_end

case_begin "wi10-no-inline-text" "skills/workflow-init/SKILL.md"
# shellcheck source=/dev/null
. "$FRAG_DIR/negatives-and-wait.sh"
group_wi10_no_inline_text
case_end

case_begin "na-scan-write-tests" "skills/write-tests/SKILL.md"
# shellcheck source=/dev/null
. "$FRAG_DIR/negatives-and-wait.sh"
group_na_skills_scan write-tests
case_end

case_begin "na-scan-review-tests" "skills/review-tests/SKILL.md"
# shellcheck source=/dev/null
. "$FRAG_DIR/negatives-and-wait.sh"
group_na_skills_scan review-tests
case_end

case_begin "na-scan-make-outline-plan" "skills/make-outline-plan/SKILL.md"
# shellcheck source=/dev/null
. "$FRAG_DIR/negatives-and-wait.sh"
group_na_skills_scan make-outline-plan
case_end

case_begin "na-scan-make-detail-plan" "skills/make-detail-plan/SKILL.md"
# shellcheck source=/dev/null
. "$FRAG_DIR/negatives-and-wait.sh"
group_na_skills_scan make-detail-plan
case_end

case_begin "na-scan-clarify-intent-and-report" "skills/clarify-intent/SKILL.md"
# shellcheck source=/dev/null
. "$FRAG_DIR/negatives-and-wait.sh"
group_na_skills_scan clarify-intent
group_na_skills_report
case_end

case_begin "wait-codex-review-loop" "skills/_shared/codex-review-loop.md"
# shellcheck source=/dev/null
. "$FRAG_DIR/negatives-and-wait.sh"
group_wait_annotation skills/_shared/codex-review-loop.md
case_end

case_begin "wait-write-tests" "skills/write-tests/SKILL.md"
# shellcheck source=/dev/null
. "$FRAG_DIR/negatives-and-wait.sh"
group_wait_annotation skills/write-tests/SKILL.md
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
