#!/usr/bin/env bash
# run-issue-setup.sh — orchestration backend for the /issue-setup skill.
#
# Usage:
#   run-issue-setup.sh --step labels        --repo OWNER/REPO
#   run-issue-setup.sh --step check-project --repo OWNER/REPO
#   run-issue-setup.sh --step ensure-project --repo OWNER/REPO
#
# Steps:
#   labels         : sync-labels.sh --repo REPO on the target repo. Propagates
#                    the sync-labels exit code verbatim.
#   check-project  : issue-create-preflight.sh --check-project --repo REPO.
#                    rc=0 project present, rc=1 absent.
#   ensure-project : ensure_project_ready REPO, then write the resolved ids as a
#                    10-column cache row. Propagates ensure failure.
#
# --repo is required and format-validated (OWNER/REPO) before any dispatch, so
# an injection payload never reaches a downstream command.
set -uo pipefail

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"

STEP=""
STEP_SET=0
REPO=""
REPO_SET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --step)
            if [ $# -lt 2 ]; then
                echo "Error: --step requires a value" >&2; exit 2
            fi
            STEP="$2"; STEP_SET=1; shift 2 ;;
        --step=*)
            STEP="${1#--step=}"; STEP_SET=1; shift ;;
        --repo)
            if [ $# -lt 2 ]; then
                echo "Error: --repo requires a value" >&2; exit 2
            fi
            REPO="$2"; REPO_SET=1; shift 2 ;;
        --repo=*)
            REPO="${1#--repo=}"; REPO_SET=1; shift ;;
        *)
            echo "Error: unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Validate --step BEFORE any dispatch (unknown/missing → fail closed).
if [ "$STEP_SET" -ne 1 ] || [ -z "$STEP" ]; then
    echo "Error: --step required (labels|check-project|ensure-project)" >&2; exit 2
fi
case "$STEP" in
    labels|check-project|ensure-project) ;;
    *) echo "Error: unknown --step value: $STEP" >&2; exit 2 ;;
esac

# Validate --repo BEFORE any dispatch (required + format-checked). Whole-string
# anchored so embedded newlines / injection payloads are rejected.
if [ "$REPO_SET" -ne 1 ] || [ -z "$REPO" ]; then
    echo "Error: --repo required (OWNER/REPO)" >&2; exit 2
fi
if ! [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "Error: invalid --repo value: $REPO" >&2; exit 2
fi

GH_ISSUES_DIR="$AGENTS_CONFIG_DIR/bin/github-issues"

case "$STEP" in
    labels)
        bash "$GH_ISSUES_DIR/sync-labels.sh" --repo "$REPO" "$AGENTS_CONFIG_DIR/.github/labels.yml"
        exit $?
        ;;
    check-project)
        bash "$GH_ISSUES_DIR/issue-create-preflight.sh" --check-project --repo "$REPO"
        exit $?
        ;;
    ensure-project)
        # shellcheck source=/dev/null
        . "$GH_ISSUES_DIR/lib/ensure-project-ready.sh"
        # shellcheck source=/dev/null
        . "$GH_ISSUES_DIR/lib/resolve-project.sh"
        if ! ensure_project_ready "$REPO"; then
            echo "Error: ensure_project_ready failed for $REPO" >&2
            exit 1
        fi
        plans_dir="${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}"
        cache_dir="$plans_dir/cache"
        cache_file="$cache_dir/project-resolve.tsv"
        _resolve_project_write_cache "$cache_dir" "$cache_file" "$REPO" \
            "${EPR_PROJECT_OWNER:-}" "${EPR_PROJECT_NUM:-}" "${EPR_PROJECT_ID:-}" \
            "${EPR_CONTENT_DATE_FIELD_ID:-}" "${EPR_STATUS_FIELD_ID:-}" \
            "${EPR_TODO_OPTION_ID:-}" "${EPR_IN_PROGRESS_OPTION_ID:-}" \
            "${EPR_DONE_OPTION_ID:-}" "${EPR_FINGERPRINT_FIELD_ID:-}" || \
            echo "warn: cache write failed for $REPO (continuing)" >&2
        exit 0
        ;;
esac
