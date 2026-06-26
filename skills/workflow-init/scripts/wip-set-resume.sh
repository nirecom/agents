#!/bin/bash
# skills/workflow-init/scripts/wip-set-resume.sh — WI-5 ALL_NONE resume path.
#
# For each issue N: check that intent:clarified is present; for those that
# are not meta, set the WIP fingerprint. If any N lacks intent:clarified,
# emit NEEDS_CLARIFY and exit 1 (caller sets FORCE_PATH_B=1) — but first
# early-claim WIP via wip-set-single.sh for each OPEN non-meta N so a
# concurrent session cannot grab the issue during the clarify window.
#
# Usage: wip-set-resume.sh [--session-id <SID>] [N...]
# Env:   AGENTS_CONFIG_DIR (required)
#
# Stdout tokens:
#   META_SKIP <N>         : meta label, WIP skipped
#   SET_OK <N>            : WIP set (Pass 2; wip-set-single early-claim logs to stderr)
#   NEEDS_CLARIFY <N,...> : one or more N lack intent:clarified
#   ALL_SET               : all done
#   RC2 <N>               : wip-state.sh / wip-set-single.sh rc=2 (caller does AskUserQuestion)
#
# Exit 0 : ALL_SET (all eligible N's processed; meta entries skipped)
# Exit 1 : NEEDS_CLARIFY emitted; caller sets FORCE_PATH_B=1
# Exit 2 : RC2 emitted; caller does AskUserQuestion

set -uo pipefail

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR required}"

WIP_SCRIPT="$AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh"
SINGLE_SCRIPT="$AGENTS_CONFIG_DIR/bin/github-issues/wip-set-single.sh"

SID_ARG=""
SID_SET=0
ISSUES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --session-id)
            [ $# -lt 2 ] && { echo "Error: --session-id requires a value" >&2; exit 2; }
            SID_ARG="$2"; SID_SET=1; shift 2
            ;;
        --session-id=*)
            SID_ARG="${1#--session-id=}"; SID_SET=1; shift
            ;;
        --) shift; while [ $# -gt 0 ]; do ISSUES+=("$1"); shift; done ;;
        -*) echo "Error: unknown option: $1" >&2; exit 2 ;;
        *) ISSUES+=("$1"); shift ;;
    esac
done

if [ "$SID_SET" -eq 1 ] && [ -z "$SID_ARG" ]; then
    echo "Error: --session-id received an empty value" >&2; exit 2
fi

if [ "$SID_SET" -eq 0 ]; then
    if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -r "${CLAUDE_ENV_FILE}" ]; then
        CANDIDATE=$(grep -E '^CLAUDE_SESSION_ID=' "$CLAUDE_ENV_FILE" 2>/dev/null \
                    | head -1 | cut -d= -f2- | tr -d '\r"')
        if [ -n "$CANDIDATE" ]; then SID_ARG="$CANDIDATE"; SID_SET=1; fi
    fi
    if [ "$SID_SET" -eq 0 ] && [ -n "${CLAUDE_SESSION_ID:-}" ]; then
        SID_ARG=$(printf '%s' "$CLAUDE_SESSION_ID" | tr -d '\r"')
        [ -n "$SID_ARG" ] && SID_SET=1
    fi
fi

TMPFILE=$(mktemp 2>/dev/null || mktemp -t wipresume)
trap 'rm -f "$TMPFILE" 2>/dev/null' EXIT

ALL_CLARIFIED=1

# Pass 1: fetch labels + state for each N, cache to temp file as N\tLABELS_JSON\tSTATE.
for N in ${ISSUES[@]:+"${ISSUES[@]}"}; do
    RAW=$(gh issue view "$N" --json labels,state 2>/dev/null) || RAW=""
    if [ -z "$RAW" ]; then
        LABELS_JSON=""; STATE=""
    else
        LABELS_JSON=$(printf '%s' "$RAW" | jq -c 'if type == "array" then . else (.labels // []) end' 2>/dev/null) || LABELS_JSON=""
        STATE=$(printf '%s' "$RAW" | jq -r '.state // ""' 2>/dev/null) || STATE=""
    fi
    if [ -z "$LABELS_JSON" ]; then
        echo "warn: label probe for #$N failed — treating as intent:clarified absent" >&2
        ALL_CLARIFIED=0
        printf '%s\t%s\t%s\n' "$N" "" "" >> "$TMPFILE"
        continue
    fi
    if ! printf '%s' "$LABELS_JSON" | grep -q '"intent:clarified"'; then
        ALL_CLARIFIED=0
    fi
    printf '%s\t%s\t%s\n' "$N" "$LABELS_JSON" "$STATE" >> "$TMPFILE"
done

# If not all clarified, emit NEEDS_CLARIFY with the list of unlabeled N's.
if [ "$ALL_CLARIFIED" -eq 0 ]; then
    NOT_CLARIFIED_CSV=""
    while IFS=$'\t' read -r N LABELS_JSON STATE; do
        if [ -z "$LABELS_JSON" ] || ! printf '%s' "$LABELS_JSON" | grep -q '"intent:clarified"'; then
            if [ -z "$NOT_CLARIFIED_CSV" ]; then
                NOT_CLARIFIED_CSV="$N"
            else
                NOT_CLARIFIED_CSV="$NOT_CLARIFIED_CSV,$N"
            fi
        fi
    done < "$TMPFILE"
    echo "NEEDS_CLARIFY $NOT_CLARIFIED_CSV"

    # Early WIP claim for each OPEN non-meta N (claim early, resolve label later).
    while IFS=$'\t' read -r N LABELS_JSON STATE; do
        # Fail-safe: if state probe failed (empty STATE) or CLOSED, do not claim.
        [ -z "$STATE" ] && continue
        [ "$STATE" != "OPEN" ] && continue
        # meta issues never get WIP.
        if printf '%s' "$LABELS_JSON" | grep -q '"meta"'; then continue; fi
        CLAIM_RC=0
        if [ "$SID_SET" -eq 1 ]; then
            bash "$SINGLE_SCRIPT" --session-id "$SID_ARG" "$N" >/dev/null 2>&1 || CLAIM_RC=$?
        else
            bash "$SINGLE_SCRIPT" "$N" >/dev/null 2>&1 || CLAIM_RC=$?
        fi
        case "$CLAIM_RC" in
            0) echo "early-claim: SET_OK $N" >&2 ;;
            2)
                echo "RC2 $N"
                exit 2
                ;;
            *) echo "warn: early-claim wip-set-single failed for #$N (rc=$CLAIM_RC)" >&2 ;;
        esac
    done < "$TMPFILE"
    exit 1
fi

# Pass 2: all clarified — set WIP per non-meta N.
while IFS=$'\t' read -r N LABELS_JSON STATE; do
    if printf '%s' "$LABELS_JSON" | grep -q '"meta"'; then
        echo "META_SKIP $N"
        continue
    fi
    WIP_ARGS=(set "$N")
    if [ "$SID_SET" -eq 1 ]; then
        WIP_ARGS+=(--session-id "$SID_ARG")
    fi
    RC=0
    bash "$WIP_SCRIPT" "${WIP_ARGS[@]}" || RC=$?
    case "$RC" in
        0)
            echo "SET_OK $N"
            ;;
        2)
            echo "RC2 $N"
            exit 2
            ;;
        *)
            echo "warn: wip-state set failed for #$N (rc=$RC)" >&2
            ;;
    esac
done < "$TMPFILE"

echo "ALL_SET"
exit 0
