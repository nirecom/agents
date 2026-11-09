#!/usr/bin/env bash
# run-issue-setup.sh — orchestration backend for the /migrate-tracker skill.
# Usage: run-issue-setup.sh --step labels|check-project|ensure-project|record-done --repo OWNER/REPO
#                           [--root DIR] [--no-push] [--dry-run]
#   labels / check-project / ensure-project: sync labels, check (rc=0 present, rc=1 absent) or
#     create the board. With --root on a gitlab origin they go through glab (gitlab-tracker.sh).
#   record-done: needs --root whose origin path is --repo (else exit 2); re-checks the board (absent or
#     incomplete → exit 1, nothing written); then sets migrate.tracker done and commits .agents.json (--no-push).
#   --dry-run: labels / ensure-project / record-done print what they would do and exit 0.
# --step / --repo / --root are validated before any dispatch, so a bad value reaches no command.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STEP=""
STEP_SET=0
REPO=""
REPO_SET=0
ROOT=""
ROOT_SET=0
NO_PUSH=0
DRY_RUN=0

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
        --root)
            if [ $# -lt 2 ]; then
                echo "Error: --root requires a value" >&2; exit 2
            fi
            ROOT="$2"; ROOT_SET=1; shift 2 ;;
        --root=*)
            ROOT="${1#--root=}"; ROOT_SET=1; shift ;;
        --no-push)
            NO_PUSH=1; shift ;;
        --dry-run)
            DRY_RUN=1; shift ;;
        *)
            echo "Error: unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Validate --step BEFORE any dispatch (unknown/missing → fail closed).
if [ "$STEP_SET" -ne 1 ] || [ -z "$STEP" ]; then
    echo "Error: --step required (labels|check-project|ensure-project|record-done)" >&2; exit 2
fi
case "$STEP" in
    labels|check-project|ensure-project|record-done) ;;
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

if [ "$ROOT_SET" -eq 1 ]; then
    if [ -z "$ROOT" ] || ! ROOT="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)"; then
        echo "Error: --root is not a git checkout: ${ROOT:-<empty>}" >&2; exit 2
    fi
elif [ "$STEP" = record-done ]; then
    echo "Error: --step record-done requires --root (the target repo's checkout)" >&2; exit 2
fi

GH_ISSUES_DIR="$SCRIPT_CHECKOUT_ROOT/bin/github-issues"
LABELS_YML="$SCRIPT_CHECKOUT_ROOT/.github/labels.yml"

HOST=github
if [ "$ROOT_SET" -eq 1 ]; then
    # shellcheck source=/dev/null
    . "$GH_ISSUES_DIR/lib/host-adapter.sh"
    HOST="$(hia_host "$ROOT")"
    if [ "$HOST" = gitlab ]; then
        # shellcheck source=gitlab-tracker.sh
        . "$SCRIPT_DIR/gitlab-tracker.sh"
    fi
fi

check_project() {
    if [ "$HOST" = gitlab ]; then
        gl_check_board "$REPO"
    else
        bash "$GH_ISSUES_DIR/issue-create-preflight.sh" --check-project --repo "$REPO"
    fi
}

root_matches_repo() {
    local slug
    slug="$(hia_repo_slug "$ROOT")" || slug=""
    if [ "${slug,,}" != "${REPO,,}" ]; then
        echo "Error: --root origin is '${slug:-<none>}', not --repo $REPO; nothing recorded" >&2; return 2
    fi
}

record_done() {
    local rc root_node
    root_matches_repo || return 2
    check_project
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "Error: no complete board for $REPO (check-project rc=$rc); migrate.tracker not recorded" >&2; return 1
    fi
    root_node="$ROOT"
    command -v cygpath >/dev/null 2>&1 && root_node="$(cygpath -m "$ROOT")"
    node "$SCRIPT_CHECKOUT_ROOT/bin/repo-settings" --root "$root_node" --set-migrate tracker || return 1
    local cma=("$GH_ISSUES_DIR/migration/commit-migration-artifacts.sh" "$ROOT" --skill migrate-tracker)
    [ "$NO_PUSH" -eq 1 ] && cma+=(--no-push)
    bash "${cma[@]}"
}

dry_run_plan() {
    local push=" and push"
    [ "$NO_PUSH" -eq 1 ] && push=""
    case "$STEP" in
        labels) echo "[dry-run] would sync the labels of $REPO ($HOST) from $LABELS_YML" ;;
        ensure-project) echo "[dry-run] would create or link the issue board of $REPO ($HOST)" ;;
        record-done)
            root_matches_repo || return 2
            echo "[dry-run] would set migrate.tracker done in $ROOT/.agents.json, then commit$push it" ;;
    esac
}

if [ "$DRY_RUN" -eq 1 ] && [ "$STEP" != check-project ]; then
    dry_run_plan
    exit $?
fi

case "$STEP" in
    labels)
        if [ "$HOST" = gitlab ]; then
            gl_labels "$REPO" "$LABELS_YML"
            exit $?
        fi
        bash "$GH_ISSUES_DIR/sync-labels.sh" --repo "$REPO" "$LABELS_YML"
        exit $?
        ;;
    check-project)
        check_project
        exit $?
        ;;
    record-done)
        record_done
        exit $?
        ;;
    ensure-project)
        if [ "$HOST" = gitlab ]; then
            gl_ensure_board "$REPO"
            exit $?
        fi
        # shellcheck source=/dev/null
        . "$GH_ISSUES_DIR/lib/ensure-project-ready.sh"
        # shellcheck source=/dev/null
        . "$GH_ISSUES_DIR/lib/resolve-project.sh"
        if ! ensure_project_ready "$REPO"; then
            echo "Error: ensure_project_ready failed for $REPO" >&2
            exit 1
        fi
        cache_dir="$(_resolve_project_cache_dir "$GH_ISSUES_DIR/lib")"
        cache_file="$cache_dir/project-resolve.tsv"
        _resolve_project_write_cache "$cache_dir" "$cache_file" "$REPO" \
            "${EPR_PROJECT_OWNER:-}" "${EPR_PROJECT_NUM:-}" "${EPR_PROJECT_ID:-}" \
            "${EPR_CONTENT_DATE_FIELD_ID:-}" "${EPR_STATUS_FIELD_ID:-}" \
            "${EPR_TODO_OPTION_ID:-}" "${EPR_IN_PROGRESS_OPTION_ID:-}" \
            "${EPR_DONE_OPTION_ID:-}" "${EPR_SESSION_ID_FIELD_ID:-}" || \
            echo "warn: cache write failed for $REPO (continuing)" >&2
        exit 0
        ;;
esac
