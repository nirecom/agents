#!/bin/bash
# issue-close-triage.sh <N>
#
# Determines next-step routing for /issue-close skill. Outputs eval-able
# shell assignments to stdout: STATE, SENTINEL, ACTION, NEXT_STEPS.
# Caller does: `eval "$(bash issue-close-triage.sh <N>)"`.
#
# NEXT_STEPS is a comma-separated list of step letters (B,D,E,F,G,H,J) the
# caller must execute in order; all other steps are skipped.
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

STATE=$(gh issue view "$N" --json state --jq '.state' 2>/dev/null) || {
    echo "Error: gh issue view #${N} failed" >&2
    exit 1
}

SENTINEL_RAW=$(gh issue view "$N" --json comments \
    --jq '[.comments[].body | select(test("^<!-- issue-close-sentinel:"))] | first // ""' \
    2>/dev/null) || SENTINEL_RAW=""

SENTINEL=""
if [ -n "$SENTINEL_RAW" ]; then
    SENTINEL=$(printf '%s' "$SENTINEL_RAW" | sed -nE 's/^<!-- issue-close-sentinel: ([a-z]+).*-->.*/\1/p')
fi

# Routing table. Step letters: B=sub-issue-gate, D=pending-post,
# E=doc-append, F=promote, G=parent-body-update, H=gh-issue-close,
# J=resolved-by+sentinel.
case "${STATE}:${SENTINEL}" in
    OPEN:)
        ACTION=proceed
        NEXT_STEPS="B,D,E,F,G,H,J"
        ;;
    OPEN:pending)
        ACTION=resume_e
        NEXT_STEPS="E,F,G,H,J"
        ;;
    OPEN:appended)
        ACTION=resume_h
        NEXT_STEPS="G,H,J"
        ;;
    CLOSED:appended)
        ACTION=resume_j
        NEXT_STEPS="J"
        ;;
    CLOSED:)
        ACTION=auto_close_path
        NEXT_STEPS="B,E,G,J"
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
            NEXT_STEPS="J"
        else
            ACTION=stuck_append_sentinel
            NEXT_STEPS="E,J"
        fi
        ;;
    *)
        echo "Error: unexpected state=${STATE} sentinel=${SENTINEL}" >&2
        exit 1
        ;;
esac

printf 'STATE=%s\n' "$STATE"
printf 'SENTINEL=%s\n' "$SENTINEL"
printf 'ACTION=%s\n' "$ACTION"
printf 'NEXT_STEPS=%s\n' "$NEXT_STEPS"
