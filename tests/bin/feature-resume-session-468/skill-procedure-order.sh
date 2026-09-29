# shellcheck shell=bash
# tests/bin/feature-resume-session-468/skill-procedure-order.sh — T21: cross-session route precedes local Detect in the SKILL procedure (#2279). Sourced by tests/bin/feature-resume-session-468.sh; not standalone.
# Tests: skills/resume-session/SKILL.md
# Tags: session, resume, skill-procedure, regression-2279, scope:common, pwsh-not-required, TL1

if ! declare -F run_cli >/dev/null 2>&1; then
    echo "skill-procedure-order.sh: sourced fragment — run tests/bin/feature-resume-session-468.sh instead" >&2
    return 1 2>/dev/null || exit 1
fi

echo ""
echo "=== T21: skill_procedure_order (#2279) ==="

# `/resume-session --from <sid>` is dispatched into a FRESH session. The SKILL
# procedure runs the local Detect first and dispatches on its `type`, whose
# `none` row says "stop" — so the cross-session route is unreachable for the
# very invocation that needs it. The cross-session branch must be decided from
# the user's argument before any local detection runs.

if [ ! -f "$SKILL_MD_LOCAL" ]; then
    fail "T21. skills/resume-session/SKILL.md not found at $SKILL_MD_LOCAL"
else
    DETECT_LINE=$(grep -nE '^### RSM-[0-9]+[a-z]? — Detect' "$SKILL_MD_LOCAL" | head -1 | cut -d: -f1)
    FROM_LINE=$(grep -nE '^### RSM-[0-9]+[a-z]? — Cross-session resume' "$SKILL_MD_LOCAL" | head -1 | cut -d: -f1)

    if [ -z "$DETECT_LINE" ] || [ -z "$FROM_LINE" ]; then
        fail "T21a. could not locate both headings (Detect='$DETECT_LINE' Cross-session='$FROM_LINE')"
    elif [ "$FROM_LINE" -lt "$DETECT_LINE" ]; then
        pass "T21a. the cross-session --from step is procedurally reached before local Detect"
    else
        fail "T21a. Detect (line $DETECT_LINE) precedes the cross-session --from step (line $FROM_LINE) — a --from invocation in a fresh session stops at the Detect dispatch table before ever reaching it"
    fi

    # T21b — even with the headings reordered, the local Detect step must say
    # out loud that a --from invocation does not take the local route, or a
    # reader following RSM order top-to-bottom still runs Detect first.
    DETECT_BODY=$(sed -nE '/^### RSM-[0-9]+[a-z]? — Detect/,/^### RSM-/p' "$SKILL_MD_LOCAL")
    case "$DETECT_BODY" in
        *"--from"*) pass "T21b. the Detect step names the --from branch as an exclusion" ;;
        *) fail "T21b. the Detect step never mentions --from — nothing tells the reader to skip local detection for a cross-session invocation" ;;
    esac

    # T21c — non-regression: the interactive hard-fail stays RSM-1, ahead of
    # every route, and no decimal step labels are introduced by a reorder
    # (rules/prompt.md 4.1).
    T21C_PROBLEMS=""
    HARDFAIL_LINE=$(grep -n '^### RSM-1 — Hard-fail check' "$SKILL_MD_LOCAL" | head -1 | cut -d: -f1)
    if [ -z "$HARDFAIL_LINE" ]; then
        T21C_PROBLEMS="$T21C_PROBLEMS [the RSM-1 hard-fail check heading is gone]"
    elif [ -n "$FROM_LINE" ] && [ "$HARDFAIL_LINE" -gt "$FROM_LINE" ]; then
        T21C_PROBLEMS="$T21C_PROBLEMS [the hard-fail check no longer precedes the cross-session step]"
    fi
    if grep -qE '^### (Step [0-9]+|RSM-[0-9]+)\.[0-9]' "$SKILL_MD_LOCAL"; then
        T21C_PROBLEMS="$T21C_PROBLEMS [a decimal step label was introduced]"
    fi
    if [ -z "$T21C_PROBLEMS" ]; then
        pass "T21c. the interactive hard-fail still gates every route and the step labels stay integral"
    else
        fail "T21c. the procedure ordering regressed;$T21C_PROBLEMS"
    fi

    # T21d — heading ORDER is not the contract; T21a/T21b pass on a procedure
    # that reorders the headings and still tells the reader nothing about
    # `--list`. The bypass must be written down for BOTH cross-session flags:
    # `--list` is the flag the skill runs first, and a reader who takes the
    # local route for it gets `none` and stops before any session is offered.
    BYPASS_LINE=$(grep -n 'before any local detection' "$SKILL_MD_LOCAL" | head -1 | cut -d: -f1)
    T21D_PROBLEMS=""
    if [ -z "$BYPASS_LINE" ]; then
        T21D_PROBLEMS="$T21D_PROBLEMS [no statement that the cross-session route is taken before any local detection]"
    else
        BYPASS_TEXT=$(sed -n "${BYPASS_LINE}p" "$SKILL_MD_LOCAL")
        case "$BYPASS_TEXT" in
            *'--list'*) ;;
            *) T21D_PROBLEMS="$T21D_PROBLEMS [the bypass statement names --from but not --list]" ;;
        esac
    fi
    case "$DETECT_BODY" in
        *'--list'*) ;;
        *) T21D_PROBLEMS="$T21D_PROBLEMS [the Detect step excludes --from but never --list]" ;;
    esac
    if [ -z "$T21D_PROBLEMS" ]; then
        pass "T21d. --list is named in the bypass statement and in the Detect step's exclusion, not just --from"
    else
        fail "T21d. the --list bypass is not written down;$T21D_PROBLEMS"
    fi

    # T21e — the other half: local detection is THIS session's, and nothing in
    # the Detect step may take a session argument. The CLI resolves its own id,
    # so a procedure that grew a `--from`/`--list` argument onto the Detect
    # command would silently turn the local route into a cross-session one.
    T21E_PROBLEMS=""
    DETECT_CMD=$(printf '%s\n' "$DETECT_BODY" | grep -F 'bin/resume-session-detect' | head -1)
    if [ -z "$DETECT_CMD" ]; then
        T21E_PROBLEMS="$T21E_PROBLEMS [the Detect step no longer runs bin/resume-session-detect]"
    else
        case "$DETECT_CMD" in
            *'--'*) T21E_PROBLEMS="$T21E_PROBLEMS [the Detect command carries an argument: $DETECT_CMD]" ;;
        esac
    fi
    EXCL_LINE=$(grep -n 'never reaches local detection' "$SKILL_MD_LOCAL" | head -1 | cut -d: -f1)
    if [ -z "$EXCL_LINE" ]; then
        T21E_PROBLEMS="$T21E_PROBLEMS [the Detect step never states that a cross-session run does not reach it]"
    fi
    if [ -z "$T21E_PROBLEMS" ]; then
        pass "T21e. the Detect step runs the argument-free CLI — local detection is this session's own — and says so"
    else
        fail "T21e. local detection is no longer scoped to the current session;$T21E_PROBLEMS"
    fi

    # T21f — the two statements must sit on the right side of the Detect
    # heading: the bypass inside the cross-session step that precedes it, the
    # exclusion inside the Detect step itself. Either one drifting into the
    # other step leaves the reader following the wrong route.
    if [ -n "$BYPASS_LINE" ] && [ -n "$EXCL_LINE" ] && [ -n "$DETECT_LINE" ] && [ -n "$FROM_LINE" ] \
        && [ "$FROM_LINE" -lt "$BYPASS_LINE" ] && [ "$BYPASS_LINE" -lt "$DETECT_LINE" ] \
        && [ "$DETECT_LINE" -lt "$EXCL_LINE" ]; then
        pass "T21f. cross-session heading < bypass statement < Detect heading < Detect's own exclusion clause"
    else
        fail "T21f. the two statements are on the wrong side of the Detect heading (cross-session=$FROM_LINE bypass=$BYPASS_LINE detect=$DETECT_LINE exclusion=$EXCL_LINE)"
    fi
fi
