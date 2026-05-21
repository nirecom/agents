#!/bin/bash
# issue-close-finalize-triage.sh <N>
#
# Phase 2 (issue-close-finalize) routing. Outputs eval-able shell assignments
# to stdout: STATE, SENTINEL, ACTION, NEXT_STEPS.
# Caller: `eval "$(bash issue-close-finalize-triage.sh <N>)"`.
#
# NEXT_STEPS is a comma-separated list of step letters the caller must execute
# in order. Step letters: B=sub-issue-gate (Phase 1 only), E=doc-append,
# G=parent-body-update, H=gh-issue-close, J=resolved-by+sentinel,
# K=wip-state-clear. auto_close_path omits B intentionally — the parent is
# already CLOSED, so the gate's pre-close protection is moot. (#366)
#
# Uses `gh --jq` (built into the gh CLI) — no external jq dependency.
# Exit non-zero on argument / environment / gh failures.

set -uo pipefail

if [ $# -lt 1 ]; then
    echo "Error: issue number required" >&2
    exit 1
fi

N="$1"

if ! printf '%s' "$N" | grep -qE '^[0-9]+$'; then
    echo "Error: issue number must be digits only (got: $N)" >&2
    exit 1
fi

if [ -z "${AGENTS_CONFIG_DIR:-}" ]; then
    echo "Error: AGENTS_CONFIG_DIR not set" >&2
    exit 1
fi

# shellcheck source=./issue-close-triage-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/issue-close-triage-lib.sh"

STATE=$(gh issue view "$N" --json state --jq '.state' 2>/dev/null) || {
    echo "Error: gh issue view #${N} failed" >&2
    exit 1
}

SENTINEL_RAW=$(gh issue view "$N" --json comments \
    --jq '[.comments[].body | select(test("^<!-- issue-close-sentinel:"))] | last // ""' \
    2>/dev/null) || SENTINEL_RAW=""

SENTINEL=$(parse_sentinel "$SENTINEL_RAW")

# #360: consumer-side staleness validation. Stale `pending` sentinel is treated
# as if Phase 1 never ran — fall through to the `OPEN:` / `CLOSED:` empty
# sentinel routes. Fresh sentinels (and `appended` ones) are unaffected.
EFFECTIVE_SENTINEL="$SENTINEL"
SENTINEL_STALE=0
if [ "$SENTINEL" = "pending" ]; then
    SENTINEL_CREATED_AT=$(gh issue view "$N" --json comments \
        --jq '[.comments[] | select(.body | test("^<!-- issue-close-sentinel: pending"))] | last | .createdAt // ""' \
        2>/dev/null) || SENTINEL_CREATED_AT=""
    if ! validate_sentinel_freshness "$SENTINEL_CREATED_AT"; then
        EFFECTIVE_SENTINEL=""
        SENTINEL_STALE=1
    fi
fi

case "${STATE}:${EFFECTIVE_SENTINEL}" in
    OPEN:)
        # Phase 1 was never run, or its sentinel was auto-expired (#360).
        # /issue-close-finalize requires the pending sentinel posted by
        # /issue-close-stage as forcing function.
        if [ "$SENTINEL_STALE" -eq 1 ]; then
            echo "Error: issue #${N} Phase 1 sentinel auto-expired (stale). Run /issue-close-stage ${N} from the linked worktree." >&2
        else
            echo "Error: issue #${N} has no Phase 1 sentinel. Run /issue-close-stage ${N} first from the linked worktree." >&2
        fi
        exit 1
        ;;
    OPEN:pending)
        ACTION=resume_e
        NEXT_STEPS="E,F,G,H,J,K"
        print_triage_output "$STATE" "$SENTINEL" "$ACTION" "$NEXT_STEPS"
        ;;
    OPEN:appended)
        ACTION=resume_h
        NEXT_STEPS="G,H,J,K"
        print_triage_output "$STATE" "$SENTINEL" "$ACTION" "$NEXT_STEPS"
        ;;
    CLOSED:appended)
        # #412: Step E (doc-append) added so History Notes from WORKTREE_NOTES.md
        # sidecar are synthesized into the history entry on resume.
        ACTION=resume_j
        NEXT_STEPS="E,J,K"
        print_triage_output "$STATE" "$SENTINEL" "$ACTION" "$NEXT_STEPS"
        ;;
    CLOSED:)
        # Issue was closed via `closes #N` keyword without /issue-close-stage.
        # Step B (sub-issue gate) is intentionally omitted: it protects against
        # closing a parent with open children, but the parent is already CLOSED
        # here — gating now only stalls bookkeeping behind long-lived tracker
        # sub-issues. Step E (doc-append) remains the existing limit and is
        # blocked under ENFORCE_WORKTREE=on. (#366)
        ACTION=auto_close_path
        NEXT_STEPS="E,G,J,K"
        print_triage_output "$STATE" "$SENTINEL" "$ACTION" "$NEXT_STEPS"
        ;;
    CLOSED:pending)
        # Stuck: close succeeded but sentinel never promoted.
        # Recovery: post a new `appended` sentinel via J-2 (idempotent). The
        # orphan `pending` is harmless — consumers match only on the
        # `appended` prefix. If history.md is missing the entry, prepend E.
        HIST_HIT=0
        if grep -qE "^### .*#${N}[,)]|^### #${N}:" \
            "${AGENTS_CONFIG_DIR}/docs/history.md" 2>/dev/null; then
            HIST_HIT=1
        elif ls "${AGENTS_CONFIG_DIR}/docs/history/"*.md >/dev/null 2>&1; then
            if grep -qE "^### .*#${N}[,)]|^### #${N}:" \
                "${AGENTS_CONFIG_DIR}/docs/history/"*.md 2>/dev/null; then
                HIST_HIT=1
            fi
        fi
        if [ "$HIST_HIT" -eq 1 ]; then
            ACTION=stuck_sentinel_only
            NEXT_STEPS="J,K"
        else
            ACTION=stuck_append_sentinel
            NEXT_STEPS="E,J,K"
        fi
        print_triage_output "$STATE" "$SENTINEL" "$ACTION" "$NEXT_STEPS"
        ;;
    *)
        echo "Error: unexpected state=${STATE} sentinel=${SENTINEL}" >&2
        exit 1
        ;;
esac
