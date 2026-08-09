#!/usr/bin/env bash
# issue-create-preflight.sh — independent label/project existence checks used by
# issue-create Phase 0a (label auto-repair) and the /issue-create skill Phase 0b
# (project AskUserQuestion). The two checks are independent — one's result never
# affects the other.
#
# Usage:
#   issue-create-preflight.sh --check-labels  [--label NAME] [--repo OWNER/REPO]
#   issue-create-preflight.sh --check-project [--repo OWNER/REPO]
#
# --check-labels : rc=0 when the label exists, rc=1 when absent.
#                  --label NAME selects which label is checked (default `type:task`);
#                  the dispatcher uses `--label meta` before make-parent.
#                  A gh HARD failure (network/auth) fails CLOSED with a distinct
#                  rc (2) — never conflated with the rc=1 "absent" verdict.
# --check-project: rc=0 when a Projects v2 board resolves, rc=1 when none.
set -uo pipefail

MODE=""
REPO_FLAG=""
REPO_FLAG_SET=0
LABEL_NAME="type:task"
LABEL_NAME_SET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --check-labels)  MODE="labels";  shift ;;
        --check-project) MODE="project"; shift ;;
        --label)
            if [ $# -lt 2 ]; then
                echo "Error: --label requires a value" >&2; exit 2
            fi
            LABEL_NAME="$2"; LABEL_NAME_SET=1; shift 2 ;;
        --label=*)
            LABEL_NAME="${1#--label=}"; LABEL_NAME_SET=1; shift ;;
        --repo)
            if [ $# -lt 2 ]; then
                echo "Error: --repo requires a value" >&2; exit 2
            fi
            REPO_FLAG="$2"; REPO_FLAG_SET=1; shift 2 ;;
        --repo=*)
            REPO_FLAG="${1#--repo=}"; REPO_FLAG_SET=1; shift ;;
        *)
            echo "Error: unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$MODE" ]; then
    echo "Error: one of --check-labels or --check-project is required" >&2; exit 2
fi

# Validate --repo before any gh call. Whole-string anchored (rejects embedded
# newlines and injection payloads); empty value is invalid.
if [ "$REPO_FLAG_SET" -eq 1 ]; then
    if ! [[ "$REPO_FLAG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        echo "Error: invalid --repo value: $REPO_FLAG" >&2; exit 2
    fi
fi

# Validate --label before any gh call, for the same reason --repo is validated above:
# the name is compared against repo data, and an unvalidated one (`.*`, an empty
# string) would match labels it does not name. Anchored, GitHub's own label charset.
if [ "$LABEL_NAME_SET" -eq 1 ]; then
    if ! [[ "$LABEL_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.:/-]*$ ]]; then
        echo "Error: invalid --label value: $LABEL_NAME" >&2; exit 2
    fi
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh CLI not found" >&2; exit 2
fi

case "$MODE" in
    labels)
        # gh HARD failure (rc != 0) → fail closed with rc=2 (distinct from the
        # rc=1 "label absent" verdict so a transient error is never misread
        # as "label absent").
        if ! names=$(gh label list ${REPO_FLAG:+--repo "$REPO_FLAG"} --json name --jq '.[].name' 2>/dev/null); then
            echo "error: issue-create-preflight: gh label list failed" >&2
            exit 2
        fi
        # -F, not a regex: `meta-foo` must not satisfy `meta`, and a name carrying a
        # regex metacharacter must be compared as the literal it is.
        if printf '%s\n' "$names" | grep -qxF -- "$LABEL_NAME"; then
            exit 0
        fi
        exit 1
        ;;
    project)
        script_dir="$(cd "$(dirname "$0")" && pwd)"
        BOARD_CARD_REPO_OVERRIDE="${REPO_FLAG:-}"
        export BOARD_CARD_REPO_OVERRIDE
        # shellcheck source=lib/resolve-project.sh
        . "$script_dir/lib/resolve-project.sh"
        if resolve_project_for_repo; then
            exit 0
        fi
        exit 1
        ;;
esac
