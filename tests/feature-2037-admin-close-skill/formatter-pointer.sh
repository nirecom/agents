# shellcheck shell=bash
# Tests: hooks/lib/supervisor-report-format.js, skills/enforce-workflow-off/SKILL.md, rules/workflow-off.md
# Tags: rules-injection, progressive-disclosure, supervisor-guard, stale-pointer, live-pointer, TL2, scope:issue-specific

# WHY (CPR-WPH): when the off-proposal guard fires, the supervisor's alert must point at
# where "Sanctioned-command false-block recovery" now lives (skills/enforce-workflow-off/
# SKILL.md after #2037), not the stale rules/workflow-off.md that still exists but no longer
# carries the section. Output is produced by CALLING formatL2ArmedReason (not grep), and P4
# opens the named path to confirm the heading resolves. Assumes AGENTS_DIR, _AGENTS_DIR_NODE,
# pass(), fail() from the entry file.

echo ""
echo "=== S13: the C3 alert's verify-pointer resolves to where the procedure actually lives ==="

FP_FORMATTER="$AGENTS_DIR/hooks/lib/supervisor-report-format.js"
FP_LIVE="skills/enforce-workflow-off/SKILL.md"
FP_STALE="rules/workflow-off.md"
FP_SECTION="Sanctioned-command false-block recovery"

if [ ! -f "$FP_FORMATTER" ]; then
    fail "S13: IMPLEMENTATION MISSING: hooks/lib/supervisor-report-format.js"
else
    # fp_render <cause> — the reason text the guard would actually show, for that cause.
    fp_render() {
        node -e '
const f = require(process.argv[1]);
process.stdout.write(f.formatL2ArmedReason(
  process.argv[2], "fpsid-2037", null,
  "/tmp/agents/agents/supervisor.md", "/tmp/plans/fpsid-2037-supervisor-state.json"
));
' "$_AGENTS_DIR_NODE/hooks/lib/supervisor-report-format.js" "$1" 2>&1
    }

    # NOTE: RED until write-code renames the cause labels (#929): the guard now passes
    # non-numbered causes and the formatter's off-proposal branch keys on
    # cause.includes("off proposal") instead of an indexOf("C3")===0 prefix.
    FP_C3="$(fp_render "workflow-off proposal")"
    FP_C3_WT="$(fp_render "worktree-off proposal")"
    FP_C2="$(fp_render "scheduled-review")"

    # P0: the render must have produced something recognisable, otherwise every
    # contains/does-not-contain assertion below grades an error message or an empty string.
    if printf '%s' "$FP_C3" | grep -q '\[EM Supervisor\] Alert mode review required'; then
        pass "S13-P0: formatL2ArmedReason returned a rendered alert for the C3 cause — the assertions below read real output, not a stack trace"
    else
        fail "S13-P0: no rendered alert came back (got: $(printf '%s' "$FP_C3" | tr '\n' ' ' | cut -c1-220)) — everything below would be graded against nothing"
    fi

    if printf '%s' "$FP_C3" | grep -qF "$FP_LIVE"; then
        pass "S13-P1: the C3 alert points the reviewer at $FP_LIVE"
    else
        fail "S13-P1: the C3 alert never names $FP_LIVE — the reviewer is told to check whether a bypass was sanctioned without being told where the criterion lives; rendered: $(printf '%s' "$FP_C3" | tr '\n' ' ' | cut -c1-300)"
    fi

    if printf '%s' "$FP_C3" | grep -qF "$FP_STALE"; then
        fail "S13-P2: the C3 alert still names the pre-#2037 address $FP_STALE — that file exists but no longer carries the '$FP_SECTION' section, so the reviewer opens it and finds nothing"
    else
        pass "S13-P2: the C3 alert does not carry the pre-#2037 address $FP_STALE"
    fi

    # P3: the non-vacuity control. P1 asserts a substring is PRESENT and P2 that another is
    # ABSENT; a footer printed for every cause would satisfy P1 while saying nothing about
    # the off-proposal branch, and P2 is satisfied by any string at all. Driving a
    # non-off-proposal cause through the same function must answer differently on both counts.
    if printf '%s' "$FP_C2" | grep -qF "$FP_LIVE"; then
        fail "S13-P3: the scheduled-review cause carries the same pointer, so P1 measures a constant footer rather than the off-proposal branch"
    elif printf '%s' "$FP_C2" | grep -q '\[EM Supervisor\] Alert mode review required'; then
        pass "S13-P3: a non-off-proposal cause renders an alert WITHOUT the pointer — P1/P2 measure the off-proposal branch, not every alert this formatter emits"
    else
        fail "S13-P3: the C2 cause did not render an alert at all, so it cannot serve as the control; rendered: $(printf '%s' "$FP_C2" | tr '\n' ' ' | cut -c1-220)"
    fi

    # P4: the pointer must RESOLVE. A live-looking path whose named section has moved on
    # again is indistinguishable from a correct one by string comparison alone.
    if [ ! -f "$AGENTS_DIR/$FP_LIVE" ]; then
        fail "S13-P4: the alert names $FP_LIVE and no such file exists in the tree — the reviewer is sent to a dead address"
    elif grep -qF "$FP_SECTION" "$AGENTS_DIR/$FP_LIVE"; then
        pass "S13-P4: $FP_LIVE exists and carries the '$FP_SECTION' section the alert quotes"
    else
        fail "S13-P4: $FP_LIVE exists but no longer carries the '$FP_SECTION' section the alert quotes by name — the procedure has moved again and the pointer was not updated with it"
    fi

    # P4-ctl: the migration is only complete if the section is NOT also still at the old
    # address. Two copies of a procedure is the CPR-SSOT failure #2037 set out to remove,
    # and it would make P4 pass no matter which address the alert named.
    if [ -f "$AGENTS_DIR/$FP_STALE" ] && grep -qF "$FP_SECTION" "$AGENTS_DIR/$FP_STALE"; then
        fail "S13-P4-ctl: '$FP_SECTION' is present in BOTH $FP_LIVE and $FP_STALE — the fact has two homes, so the pointer assertions above cannot tell a migrated tree from an un-migrated one"
    else
        pass "S13-P4-ctl: the section lives at exactly one address — so P1/P2 distinguish a migrated pointer from a stale one"
    fi

    # P5 (CPR-ORTH): the worktree-off spelling of the same C3 cause takes a different branch
    # for its trigger line and must not have been left behind on the old pointer.
    if printf '%s' "$FP_C3_WT" | grep -q 'WORKTREE_OFF' \
       && printf '%s' "$FP_C3_WT" | grep -qF "$FP_LIVE" \
       && ! printf '%s' "$FP_C3_WT" | grep -qF "$FP_STALE"; then
        pass "S13-P5: the WORKTREE_OFF spelling of the C3 cause carries the same live pointer and none of the stale one"
    else
        fail "S13-P5: the WORKTREE_OFF spelling diverged from its WORKFLOW_OFF sibling — one of the two symmetric proposal types would send the reviewer somewhere else; rendered: $(printf '%s' "$FP_C3_WT" | tr '\n' ' ' | cut -c1-300)"
    fi
fi
