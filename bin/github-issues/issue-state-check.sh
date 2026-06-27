#!/usr/bin/env bash
# issue-state-check.sh [--repo <owner/repo|repo>] <issue-number>
#
# Check whether a GitHub issue is OPEN, CLOSED, or unreachable.
#
# stdout: exactly one of `open`, `closed`, or `error` (newline-terminated).
# Exit 0: state determined (open or closed).
# Exit 1: gh failed or unexpected state.
# Exit 2: bad arguments.
#
# --repo: optional repository slug (short form "repo" or full "owner/repo").
#         Short form is normalized via `gh repo view` to full owner/repo.
#
# Dependencies: `gh` CLI only. Does NOT require AGENTS_CONFIG_DIR.
set -euo pipefail

REPO_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO_ARG="$2"; shift 2 ;;
        --repo=*) REPO_ARG="${1#--repo=}"; shift ;;
        --) shift; break ;;
        *) break ;;
    esac
done

# Validate arg: must be a single numeric issue number
if [[ $# -ne 1 ]] || [[ ! "$1" =~ ^[0-9]+$ ]]; then
    echo "Usage: issue-state-check.sh [--repo <owner/repo|repo>] <issue-number>" >&2
    exit 2
fi

N="$1"

# Validate --repo format before any use (prevents flag-injection into gh).
if [[ -n "$REPO_ARG" ]]; then
    if ! [[ "$REPO_ARG" =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)?$ ]]; then
        echo "Error: invalid --repo value: $REPO_ARG" >&2
        exit 2
    fi
fi

# Normalize short-form repo (no slash) to full owner/repo (fail-closed).
if [[ -n "$REPO_ARG" ]] && [[ "$REPO_ARG" != *"/"* ]]; then
    REPO_ARG=$(gh repo view "$REPO_ARG" --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null) || {
        echo "Error: failed to resolve short-form repo '$REPO_ARG'" >&2
        exit 2
    }
fi

# Call gh in an if-block to avoid set -e abort on failure
if RAW=$(gh issue view "$N" ${REPO_ARG:+--repo "$REPO_ARG"} --json state --jq '.state' 2>/dev/null); then
    case "$RAW" in
        OPEN)   echo "open";   exit 0 ;;
        CLOSED) echo "closed"; exit 0 ;;
        *)      echo "[issue-state-check] unexpected state '$RAW' for #$N" >&2
                echo "error"
                exit 1 ;;
    esac
else
    echo "[issue-state-check] gh call failed for #$N" >&2
    echo "error"
    exit 1
fi
