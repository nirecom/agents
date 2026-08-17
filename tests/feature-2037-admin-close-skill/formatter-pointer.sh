# shellcheck shell=bash
# Tests: hooks/lib/supervisor-report-format.js, skills/enforce-workflow-off/SKILL.md, rules/workflow-off.md
# Tags: rules-injection, progressive-disclosure, supervisor-guard, stale-pointer, live-pointer, TL2, scope:issue-specific

# WHY (CPR-WPH): when the C3 off-proposal guard fires, the supervisor is told where to look
# up whether the bypass was sanctioned. #2037 moved that procedure — "Sanctioned-command
# false-block recovery" — out of rules/workflow-off.md and into
# skills/enforce-workflow-off/SKILL.md. A pointer left on the old address is the worst kind
# of stale: rules/workflow-off.md still EXISTS, so the reviewer opens it, does not find the
# section, and has to decide the sanctioned-vs-improvised question unaided at the exact
# moment a guard bypass is on the table.

# The output is produced by CALLING formatL2ArmedReason, never by grepping the source. A
# grep would pass on a pointer sitting in dead code or in a branch this cause never reaches,
# and would fail on one assembled from parts — neither is what the supervisor actually reads.

# The pointer is also resolved: naming a file is not the same as the file carrying the
# section. P4 opens the named path and looks for the named heading, so a second migration
# that moves the section again fails here rather than in a live incident. Assumes AGENTS_DIR,
# _AGENTS_DIR_NODE, pass(), fail() from the entry file.

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

    FP_C3="$(fp_render "C3 workflow-off proposal")"
    FP_C3_WT="$(fp_render "C3 worktree-off proposal")"
    FP_C2="$(fp_render "C2 scheduled")"

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
    # the C3 branch, and P2 is satisfied by any string at all. Driving a NON-C3 cause through
    # the same function must answer differently on both counts.
    if printf '%s' "$FP_C2" | grep -qF "$FP_LIVE"; then
        fail "S13-P3: the C2 (scheduled review) cause carries the same pointer, so P1 measures a constant footer rather than the C3 off-proposal branch"
    elif printf '%s' "$FP_C2" | grep -q '\[EM Supervisor\] Alert mode review required'; then
        pass "S13-P3: a non-C3 cause renders an alert WITHOUT the pointer — P1/P2 measure the off-proposal branch, not every alert this formatter emits"
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
