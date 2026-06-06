#!/bin/bash
# step-g5-loop.sh — mechanical parts of Step ICF-D..ICF-G (parent close proposal).
#
# ICF-F (AskUserQuestion + LLM judgement of parent body) stays in SKILL.md.
# This script implements:
#   - prepare <N>  : init counters + run ICF-E pre-check; emit PROPOSAL_PARENT
#                    and PROPOSAL_STATUS to stdout.
#   - execute <N> <ACTION> : implement ICF-G (yes) or counter bumps for the
#                    LLM/user decisions (no/decline/skip). Emits updated
#                    counters and NEXT_N for the loop.
#
# All output to stdout is KEY=value (sourceable). Diagnostics go to stderr.
set -euo pipefail

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"

SUBCMD="${1:?subcommand required: prepare|execute}"
shift

case "$SUBCMD" in
    prepare)
        N="${1:?N required}"
        # ICF-E — Pre-check. Capture stdout only; let stderr pass through.
        rc=0
        PROPOSAL_PARENT=$(bash "$AGENTS_CONFIG_DIR/bin/github-issues/parent-close-proposal-prepare.sh" \
            "$OWNER_REPO" "$N") || rc=$?
        case "$rc" in
            0)
                echo "PROPOSAL_PARENT=$PROPOSAL_PARENT"
                echo "PROPOSAL_STATUS=ok"
                ;;
            1)
                echo "[step-g5: ICF-E returned 1 — skipping (no eligible parent)]" >&2
                echo "PROPOSAL_STATUS=skipped"
                ;;
            2)
                echo "[step-g5: ICF-E returned 2 — skipping (warning from prepare)]" >&2
                echo "PROPOSAL_STATUS=skipped"
                ;;
            *)
                echo "[step-g5: ICF-E unexpected rc=$rc]" >&2
                echo "PROPOSAL_STATUS=skipped"
                ;;
        esac
        ;;

    execute)
        PROPOSAL_PARENT="${1:?PROPOSAL_PARENT required}"
        ACTION="${2:?ACTION required: accept|decline|skip}"
        case "$ACTION" in
            accept)
                if ! bash "$AGENTS_CONFIG_DIR/bin/github-issues/parent-close-proposal-execute.sh" \
                        "$PROPOSAL_PARENT" >&2; then
                    echo "[step-g5: parent-close-proposal-execute.sh failed for #$PROPOSAL_PARENT]" >&2
                    echo "PROPOSAL_RESULT=execute-failed"
                    exit 0
                fi
                # Caller continues by invoking /issue-close-finalize $PROPOSAL_PARENT
                echo "PROPOSAL_RESULT=accepted"
                echo "NEXT_N=$PROPOSAL_PARENT"
                ;;
            decline)
                echo "PROPOSAL_RESULT=declined"
                ;;
            skip)
                echo "PROPOSAL_RESULT=skipped"
                ;;
            *)
                echo "[step-g5: unknown ACTION=$ACTION]" >&2
                exit 1
                ;;
        esac
        ;;

    *)
        echo "Error: unknown subcommand '$SUBCMD' (expected prepare|execute)" >&2
        exit 1
        ;;
esac
