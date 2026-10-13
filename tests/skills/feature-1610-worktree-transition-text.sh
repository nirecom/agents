#!/bin/bash
# tests/skills/feature-1610-worktree-transition-text.sh
# Tests: skills/_shared/worktree-transition.md, skills/worktree-start/SKILL.md, skills/worktree-end/SKILL.md, bin/workflow/next-step, hooks/workflow-gate/worktree-entry-gate.js, hooks/enforce-worktree/worktree-remedy.js, bin/workflow/lib/next-step/
# Tags: prompt, skill, worktree, duplication-policy, TL1, pwsh-not-required, scope:issue-specific
#
# Issue #1610 — static half of the worktree-transition duplication policy.
# X12 pins the static side (reference counts, recovery-procedure exclusivity,
# escape hatches listed only by Tier 3). The runtime side (entry procedure never
# leaking into a hook's emitted reason) is pinned by T1 Section H6/H7 against
# real hook stdout — source grep cannot decide it, because worktree-remedy.js
# legitimately carries /worktree-start in its default branch.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FRAGMENT="$SCRIPT_CHECKOUT_ROOT/skills/_shared/worktree-transition.md"
WS="$SCRIPT_CHECKOUT_ROOT/skills/worktree-start/SKILL.md"
WE="$SCRIPT_CHECKOUT_ROOT/skills/worktree-end/SKILL.md"
# STEP_HINT moved out of the bin/workflow/next-step entrypoint when it was split
# into bin/workflow/lib/next-step/ (#1756); steps.js now owns the hint strings.
NEXT_STEP="$SCRIPT_CHECKOUT_ROOT/bin/workflow/lib/next-step/steps.js"
ENTRY_GATE="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-gate/worktree-entry-gate.js"
REMEDY="$SCRIPT_CHECKOUT_ROOT/hooks/enforce-worktree/worktree-remedy.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

lines_of() { wc -l < "$1" | tr -d ' '; }
count_lit() { grep -oF "$2" "$1" 2>/dev/null | wc -l | tr -d ' '; }

check_has() { if grep -qF "$2" "$3"; then pass "$1"; else fail "$1 -- literal [$2] absent from $3"; fi; }
check_lacks() { if grep -qF "$2" "$3"; then fail "$1 -- literal [$2] present in $3"; else pass "$1"; fi; }
check_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 -- want [$2] got [$3]"; fi; }

# check_lacks_except <desc> <needle> <file> [allowed_line_substring ...]
# Same intent as check_lacks, but tolerates occurrences that fall on a line
# containing one of the allowed substrings — used to extend X12d's mechanics-
# literal check to prose/CLI referrers that already use the same substrings
# for an unrelated, pre-existing, already-audited purpose (see X12e/f/g).
check_lacks_except() {
    local desc="$1" needle="$2" file="$3"; shift 3
    local hits allow
    hits="$(grep -F "$needle" "$file" 2>/dev/null || true)"
    for allow in "$@"; do
        hits="$(printf '%s\n' "$hits" | grep -vF "$allow" || true)"
    done
    hits="$(printf '%s\n' "$hits" | grep -v '^[[:space:]]*$' || true)"
    if [ -z "$hits" ]; then pass "$desc"
    else fail "$desc -- unaccounted occurrence(s): $hits"; fi
}

# X1 — fragment exists and stays under the prompt-file WARN threshold.
run_X1() {
    require_source "$FRAGMENT" "X1: worktree-transition.md exists and is < 100 lines" || return
    local n; n="$(lines_of "$FRAGMENT")"
    if [ "$n" -lt 100 ]; then pass "X1: worktree-transition.md exists and is < 100 lines ($n)"
    else fail "X1: worktree-transition.md is $n lines (must be < 100)"; fi
}

# X2 — rules/prompt.md 1.5: no fenced code blocks in prompt files.
run_X2() {
    require_source "$FRAGMENT" "X2: worktree-transition.md has zero code fences" || return
    local n; n="$(grep -c '^```' "$FRAGMENT" || true)"
    check_eq "X2: worktree-transition.md has zero code fences" "0" "$n"
}

# X3 — worktree-start WS-8 carries the entry step and defers to the fragment.
run_X3() {
    require_source "$FRAGMENT" "X3: worktree-start WS-8 references the fragment" || return
    require_source "$WS" "X3: worktree-start WS-8 references the fragment" || return
    if grep -qF "WS-8." "$WS" && grep -qF "skills/_shared/worktree-transition.md" "$WS"; then
        pass "X3: worktree-start WS-8 references the fragment"
    else
        fail "X3: worktree-start WS-8 references the fragment (WS-8. or fragment path missing)"
    fi
}

# X4 — entry is reported by the final step, and nothing follows it.
run_X4() {
    require_source "$FRAGMENT" "X4: worktree-start WS-9 is the final report and mentions entry" || return
    require_source "$WS" "X4: worktree-start WS-9 is the final report and mentions entry" || return
    local ws9 tail_labels
    ws9="$(grep -F "WS-9." "$WS" || true)"
    tail_labels="$(grep -cE '^WS-1[0-9]+\.' "$WS" || true)"
    if [ -n "$ws9" ] \
        && printf '%s' "$ws9" | grep -qF "Final report" \
        && printf '%s' "$ws9" | grep -qF "entered" \
        && [ "$tail_labels" = "0" ]; then
        pass "X4: worktree-start WS-9 is the final report and mentions entry"
    else
        fail "X4: worktree-start WS-9 is the final report and mentions entry (ws9=[$ws9] labels_after=$tail_labels)"
    fi
}

# X5 — worktree-end gains WE-9a (WE-13a before #2527 renumber) and defers to the fragment.
run_X5() {
    require_source "$FRAGMENT" "X5: worktree-end WE-9a references the fragment" || return
    require_source "$WE" "X5: worktree-end WE-9a references the fragment" || return
    if grep -qF "### WE-9a" "$WE" && grep -qF "skills/_shared/worktree-transition.md" "$WE"; then
        pass "X5: worktree-end WE-9a references the fragment"
    else
        fail "X5: worktree-end WE-9a references the fragment (WE-9a or fragment path missing)"
    fi
}

# X6 / X7 — both hook modules point at the fragment rather than restating it.
run_X6() {
    require_source "$ENTRY_GATE" "X6: worktree-entry-gate.js carries the fragment path" || return
    check_has "X6: worktree-entry-gate.js carries the fragment path" \
        "skills/_shared/worktree-transition.md" "$ENTRY_GATE"
}

run_X7() {
    require_source "$REMEDY" "X7: worktree-remedy.js carries the fragment path" || return
    check_has "X7: worktree-remedy.js carries the fragment path" \
        "skills/_shared/worktree-transition.md" "$REMEDY"
}

# X8 — pinned regression: the CWD-switch ordering warning must not be lost.
# #2527 renumbered WE-13 → WE-9 and dropped the merge step that carried one copy;
# the CWD rule stays in ## Rules and the ExitWorktree-after-cd order is stated twice.
run_X8() {
    require_source "$WE" "X8: WE-9 ordering warning still stated" || return
    local cwd n
    cwd="$(count_lit "$WE" "CWD must remain in the linked worktree through WE-8; switch to main worktree only at WE-9")"
    n="$(count_lit "$WE" 'the WE-9 `cd`')"
    if [ "$cwd" -ge 1 ] && [ "$n" -ge 2 ]; then pass "X8: WE-9 ordering warning still stated (cwd=$cwd cd-order=$n)"
    else fail "X8: WE-9 ordering warning lost (cwd=$cwd must be >= 1, cd-order=$n must be >= 2)"; fi
}

# X9 — rules/prompt.md 4.1: decimal step labels are prohibited.
run_X9() {
    require_source "$WS" "X9: no decimal step labels in worktree SKILL.md files" || return
    require_source "$WE" "X9: no decimal step labels in worktree SKILL.md files" || return
    local a b
    a="$(grep -cE 'WS-[0-9]+\.[0-9]' "$WS" || true)"
    b="$(grep -cE 'WE-[0-9]+\.[0-9]' "$WE" || true)"
    if [ "$a" = "0" ] && [ "$b" = "0" ]; then
        pass "X9: no decimal step labels in worktree SKILL.md files"
    else
        fail "X9: decimal step labels found (worktree-start=$a worktree-end=$b)"
    fi
}

# X10 — file-split Pattern B WARN threshold for prompt files.
run_X10() {
    require_source "$WS" "X10: both worktree SKILL.md files stay <= 100 lines" || return
    require_source "$WE" "X10: both worktree SKILL.md files stay <= 100 lines" || return
    local a b
    a="$(lines_of "$WS")"; b="$(lines_of "$WE")"
    if [ "$a" -le 100 ] && [ "$b" -le 100 ]; then
        pass "X10: both worktree SKILL.md files stay <= 100 lines ($a / $b)"
    else
        fail "X10: prompt file over WARN threshold (worktree-start=$a worktree-end=$b)"
    fi
}

# X11 — the workflow step hint routes the reader to the same fragment.
run_X11() {
    require_source "$FRAGMENT" "X11: next-step STEP_HINT references the fragment" || return
    require_source "$NEXT_STEP" "X11: next-step STEP_HINT references the fragment" || return
    check_has "X11: next-step STEP_HINT references the fragment" \
        "worktree-transition.md" "$NEXT_STEP"
}

# X12 — duplication policy, static side. Four independent asserts:
#   (a) each of the 5 referrers mentions the fragment exactly once
#   (b) the recovery sentinels are the fragment's exclusive property
#   (c) Tier 3 alone spells out both escape hatches
#   (d) the entry procedure never appears in the Tier 3 gate source
# The runtime counterpart lives in T1 H6/H7.
run_X12() {
    local label
    local refs=("$WS" "$WE" "$NEXT_STEP" "$ENTRY_GATE" "$REMEDY")

    label="X12a: fragment referenced exactly once per referrer (5 referrers)"
    if [ ! -f "$FRAGMENT" ]; then
        skip "$label (source not implemented yet)"
    else
        local missing="" bad="" f n
        for f in "${refs[@]}"; do
            if [ ! -f "$f" ]; then missing="$missing $f"; continue; fi
            n="$(count_lit "$f" "worktree-transition.md")"
            [ "$n" = "1" ] || bad="$bad $f=$n"
        done
        if [ -n "$missing" ]; then skip "$label (referrers not implemented yet:$missing)"
        elif [ -z "$bad" ]; then pass "$label"
        else fail "$label -- wrong counts:$bad"; fi
    fi

    label="X12b: recovery sentinels appear only in the fragment"
    if [ ! -f "$FRAGMENT" ]; then
        skip "$label (source not implemented yet)"
    else
        local leak="" g
        for g in "$WS" "$WE" "$NEXT_STEP" "$REMEDY"; do
            [ -f "$g" ] || continue
            grep -qF "WORKFLOW_ENFORCE_WORKTREE_OFF" "$g" && leak="$leak $g(OFF)"
            grep -qF "WORKFLOW_ENFORCE_WORKTREE_ON" "$g" && leak="$leak $g(ON)"
        done
        if [ -z "$leak" ]; then pass "$label"
        else fail "$label -- sentinel literals leaked into:$leak"; fi
    fi

    label="X12c: Tier 3 gate names both escape hatches"
    if require_source "$ENTRY_GATE" "$label"; then
        if grep -qF "WORKFLOW_ENFORCE_WORKTREE_OFF" "$ENTRY_GATE" \
            && grep -qF "WORKFLOW_ENFORCE_WORKFLOW_OFF" "$ENTRY_GATE"; then
            pass "$label"
        else
            fail "$label -- one or both sentinel literals missing from $ENTRY_GATE"
        fi
    fi

    label="X12d: Tier 3 gate source omits the entry procedure"
    if require_source "$ENTRY_GATE" "$label"; then
        local found="" lit
        for lit in 'EnterWorktree' 'cd "' 'git rev-parse'; do
            grep -qF "$lit" "$ENTRY_GATE" && found="$found [$lit]"
        done
        if [ -z "$found" ]; then pass "$label"
        else fail "$label -- forbidden literals present:$found"; fi
    fi
}

# X12e/f/g — X12d's mechanics-literal check, extended to WS, WE and NEXT_STEP.
# Each legitimately uses some X12d tokens for unrelated purposes, so only the
# narrowed checks below apply: WS/WE exclude `cd "$AGENTS_MAIN_ROOT"`, WE also
# excludes the WE-9 `cd "<main-worktree-root>"` CWD switch, and `git rev-parse`
# (generic, used everywhere) is never checked. EnterWorktree is blanket-absent in WE.
run_X12e() {
    local label

    label="X12e: worktree-start SKILL.md has no unaccounted cd-mechanic occurrence"
    if require_source "$WS" "$label"; then
        check_lacks_except "$label" 'cd "' "$WS" 'cd "$AGENTS_MAIN_ROOT"'
    fi

    label="X12f: worktree-end SKILL.md omits EnterWorktree and has no unaccounted cd-mechanic occurrence"
    if require_source "$WE" "$label"; then
        check_lacks "X12f-1: worktree-end SKILL.md omits EnterWorktree" "EnterWorktree" "$WE"
        check_lacks_except "X12f-2: worktree-end SKILL.md has no unaccounted cd-mechanic occurrence" \
            'cd "' "$WE" 'cd "$AGENTS_MAIN_ROOT"' 'cd "<main-worktree-root>"'
    fi

    label="X12g: next-step CLI has no unaccounted cd-mechanic occurrence"
    if require_source "$NEXT_STEP" "$label"; then
        check_lacks "$label" 'cd "' "$NEXT_STEP"
    fi
}

run_X1; run_X2; run_X3; run_X4; run_X5; run_X6
run_X7; run_X8; run_X9; run_X10; run_X11; run_X12
run_X12e

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
