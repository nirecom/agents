#!/bin/bash
# bin/github-issues/wip-state.sh — WIP signaling for issue #N via Projects v2.
#
# Verbs:
#   set <N>:   write fingerprint THEN Status=In Progress; then write lock file.
#   check <N>: print same|other|none on stdout.
#   clear <N>: Status=Done + clear fingerprint + delete lock (idempotent).
#   abandon <N>: Status=Todo + clear fingerprint + delete lock (OPEN issues only).
#   setup:     one-shot field/option ID discovery; append to $AGENTS_CONFIG_DIR/.env.
#
# Fingerprint: sha256(session_id + ":" + N)[:8]. Issue-salted. Collision risk
# for N parallel sessions ≈ N²/2^33 (N=1000: <0.001%). Practical N=1–3.
#
# GraphQL usage: writes via `gh project item-edit` only (no mutations).
# Reads use `gh api graphql` queries because `gh project item-list` does not
# reliably surface both a single-select Status value AND a custom text field
# value for a given item in one call.
#
# Run from inside the target repo's worktree (gh uses cwd-based repo resolution).

set -uo pipefail

CMD=""
N=""
INJECTED_SID=""
SID_SET=0
REPO_OVERRIDE=""

usage() {
    sed -n '2,18p' "$0" >&2
    exit "${1:-2}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --session-id)
            if [ $# -lt 2 ]; then
                echo "Error: --session-id requires a value" >&2; exit 2
            fi
            INJECTED_SID="$2"
            SID_SET=1
            shift 2
            ;;
        --session-id=*)
            INJECTED_SID="${1#--session-id=}"
            SID_SET=1
            shift
            ;;
        --repo)
            if [ $# -lt 2 ]; then
                echo "Error: --repo requires a value" >&2; exit 2
            fi
            REPO_OVERRIDE="$2"
            shift 2
            ;;
        --repo=*)
            REPO_OVERRIDE="${1#--repo=}"
            if [[ -z "$REPO_OVERRIDE" ]]; then
                echo "Error: --repo requires a non-empty value" >&2; exit 2
            fi
            shift
            ;;
        -h|--help) usage 0 ;;
        --) shift; break ;;
        -*)
            echo "Error: unknown option: $1" >&2; exit 2
            ;;
        *)
            if [ -z "$CMD" ]; then CMD="$1"
            elif [ -z "$N" ]; then N="$1"
            else echo "Error: extra positional argument: $1" >&2; exit 2
            fi
            shift
            ;;
    esac
done

case "$CMD" in
    set|check|clear|abandon|setup) ;;
    *) echo "Error: usage: wip-state.sh {set|check|clear|abandon|setup} [<N>] [--session-id <SID>]" >&2; exit 2 ;;
esac

if [ "$CMD" = "clear" ] && [ "$SID_SET" -eq 1 ]; then
    echo "Error: 'clear' does not accept --session-id (verb does not consume session id)" >&2
    exit 2
fi

if [ "$CMD" = "abandon" ] && [ "$SID_SET" -eq 1 ]; then
    echo "Error: 'abandon' does not accept --session-id (verb does not consume session id)" >&2
    exit 2
fi

if [[ -n "$REPO_OVERRIDE" ]]; then
    if ! [[ "$REPO_OVERRIDE" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*(/[A-Za-z0-9][A-Za-z0-9_.-]*)?$ ]]; then
        echo "Error: invalid --repo value: $REPO_OVERRIDE" >&2
        exit 2
    fi
fi

# --- BEGIN temporary: WIP_STATE_* .env → resolve-project.sh cache migration ---
# .env auto-source. Claude Code's Bash subprocess shell does not propagate
# .env automatically, so a `setup`-written WIP_STATE_*_ID would still be
# invisible to a same-session `set`/`check`/`clear`. Source defensively.
# Field IDs are now resolved on demand by resolve-project.sh; .env WIP_STATE_*
# values are deprecated but still honored this session (precedence over resolver).
load_env_file() {
    [ -z "${AGENTS_CONFIG_DIR:-}" ] && return 0
    local envfile="$AGENTS_CONFIG_DIR/.env"
    [ ! -r "$envfile" ] && return 0
    ENV_OS_FILTER="$AGENTS_CONFIG_DIR/bin/env-os-filter"
    set -a
    if [ -x "$ENV_OS_FILTER" ]; then
        # shellcheck disable=SC1090,SC1091
        . <("$ENV_OS_FILTER" "$envfile") 2>/dev/null || echo "warn: failed to source $envfile (continuing)" >&2
    else
        # shellcheck disable=SC1090
        . "$envfile" 2>/dev/null || echo "warn: failed to source $envfile (continuing)" >&2
    fi
    set +a
    return 0
}
load_env_file
if [ -n "${WIP_STATE_STATUS_FIELD_ID:-}" ] || [ -n "${WIP_STATE_TODO_OPTION_ID:-}" ] \
   || [ -n "${WIP_STATE_IN_PROGRESS_OPTION_ID:-}" ] || [ -n "${WIP_STATE_DONE_OPTION_ID:-}" ] \
   || [ -n "${WIP_STATE_FINGERPRINT_FIELD_ID:-}" ]; then
    echo "warn: .env WIP_STATE_* values are deprecated. They are still honored for this session, but please remove them from \$AGENTS_CONFIG_DIR/.env. Field IDs are now resolved on demand from GitHub Projects by resolve-project.sh." >&2
fi
# --- END temporary: WIP_STATE_* .env → resolve-project.sh cache migration ---

BOARD_CARD_REPO_OVERRIDE="${REPO_OVERRIDE:-}"
export BOARD_CARD_REPO_OVERRIDE

# shellcheck source=lib/board-card.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/board-card.sh"

if [ -z "${AGENTS_CONFIG_DIR:-}" ]; then
    echo "Error: AGENTS_CONFIG_DIR not set" >&2
    exit 2
fi

# Projects v2 config: auto-resolved from git remote (#641).
# shellcheck source=lib/resolve-project.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/resolve-project.sh"
PROJECT_ID=""
OWNER=""
PROJECT_NUM=""

# ensure_resolved
#   Populate PROJECT_ID/OWNER/PROJECT_NUM via resolver. Returns 0 on success, 1 on failure.
#   Caller decides fatality.
ensure_resolved() {
    if resolve_project_for_repo; then
        PROJECT_ID="$RESOLVED_PROJECT_ID"
        OWNER="$RESOLVED_OWNER"
        PROJECT_NUM="$RESOLVED_PROJECT_NUM"
        return 0
    fi
    return 1
}

# ensure_wip_field_ids
#   Populate WIP_STATE_* field/option IDs from the resolver — but never overwrite
#   a value already provided by the deprecated .env migration block (precedence:
#   .env wins). Runs as a preprocessing step before preflight_field_ids in the
#   set/check/clear verbs. Resolver failure is non-fatal here: when .env already
#   supplied the IDs, preflight still passes; otherwise the verb's own
#   ensure_resolved call decides the exit behavior.
ensure_wip_field_ids() {
    # Soft project-scope check (warn-only) — same pattern as issue-create.sh.
    if command -v gh >/dev/null 2>&1; then
        if ! gh auth status 2>&1 | grep -q "'project'"; then
            echo "warn: gh auth lacks 'project' scope — field-id resolve may fail." >&2
        fi
    fi
    if resolve_project_for_repo; then
        [ -z "${WIP_STATE_STATUS_FIELD_ID:-}" ]      && WIP_STATE_STATUS_FIELD_ID="$RESOLVED_STATUS_FIELD_ID"
        [ -z "${WIP_STATE_TODO_OPTION_ID:-}" ]       && WIP_STATE_TODO_OPTION_ID="$RESOLVED_TODO_OPTION_ID"
        [ -z "${WIP_STATE_IN_PROGRESS_OPTION_ID:-}" ] && WIP_STATE_IN_PROGRESS_OPTION_ID="$RESOLVED_IN_PROGRESS_OPTION_ID"
        [ -z "${WIP_STATE_DONE_OPTION_ID:-}" ]       && WIP_STATE_DONE_OPTION_ID="$RESOLVED_DONE_OPTION_ID"
        [ -z "${WIP_STATE_FINGERPRINT_FIELD_ID:-}" ] && WIP_STATE_FINGERPRINT_FIELD_ID="$RESOLVED_FINGERPRINT_FIELD_ID"
    fi
    return 0
}

# Per-verb preflight: only required env vars actually consumed by the verb.
preflight_field_ids() {
    local missing=()
    case "$CMD" in
        set)
            [ -z "${WIP_STATE_STATUS_FIELD_ID:-}" ]      && missing+=("WIP_STATE_STATUS_FIELD_ID")
            [ -z "${WIP_STATE_IN_PROGRESS_OPTION_ID:-}" ] && missing+=("WIP_STATE_IN_PROGRESS_OPTION_ID")
            [ -z "${WIP_STATE_FINGERPRINT_FIELD_ID:-}" ] && missing+=("WIP_STATE_FINGERPRINT_FIELD_ID")
            ;;
        check)
            [ -z "${WIP_STATE_STATUS_FIELD_ID:-}" ]      && missing+=("WIP_STATE_STATUS_FIELD_ID")
            [ -z "${WIP_STATE_FINGERPRINT_FIELD_ID:-}" ] && missing+=("WIP_STATE_FINGERPRINT_FIELD_ID")
            ;;
        clear)
            [ -z "${WIP_STATE_STATUS_FIELD_ID:-}" ]      && missing+=("WIP_STATE_STATUS_FIELD_ID")
            [ -z "${WIP_STATE_DONE_OPTION_ID:-}" ]       && missing+=("WIP_STATE_DONE_OPTION_ID")
            [ -z "${WIP_STATE_FINGERPRINT_FIELD_ID:-}" ] && missing+=("WIP_STATE_FINGERPRINT_FIELD_ID")
            ;;
        abandon)
            [ -z "${WIP_STATE_STATUS_FIELD_ID:-}" ]      && missing+=("WIP_STATE_STATUS_FIELD_ID")
            [ -z "${WIP_STATE_TODO_OPTION_ID:-}" ]       && missing+=("WIP_STATE_TODO_OPTION_ID")
            [ -z "${WIP_STATE_FINGERPRINT_FIELD_ID:-}" ] && missing+=("WIP_STATE_FINGERPRINT_FIELD_ID")
            ;;
    esac
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "Error: missing required env vars for '$CMD': ${missing[*]}" >&2
        echo "Hint: run 'bash $0 setup' to discover and persist them in .env" >&2
        exit 2
    fi
}

validate_n() {
    [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || { echo "Error: issue number must be a positive integer, got: '${1:-}'" >&2; exit 2; }
}

resolve_plans_dir() {
    if [ -x "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" ]; then
        bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" 2>/dev/null \
            || printf '%s' "${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}"
    else
        printf '%s' "${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}"
    fi
}

compute_fingerprint() {
    printf '%s:%s' "$1" "$2" | sha256sum | cut -c1-8
}

# resolve_owner_repo and resolve_item_id are sourced from lib/board-card.sh.
# resolve_item_id reads $PROJECT_ID from caller scope (set near the top of this
# script). See lib/board-card.sh contract comment.

write_lock_file() {
    local n="$1"
    local sid="$2"
    local plans
    plans=$(resolve_plans_dir)
    [ -z "$plans" ] && return 1
    mkdir -p "$plans" 2>/dev/null || return 1
    local started
    started=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date)
    {
        printf 'issue: %s\n' "$n"
        printf 'session-id: %s\n' "$sid"
        printf 'started: %s\n' "$started"
    } > "$plans/wip-lock-$n.md" 2>/dev/null
}

delete_lock_file() {
    local n="$1"
    local plans
    plans=$(resolve_plans_dir)
    [ -z "$plans" ] && return 0
    rm -f "$plans/wip-lock-$n.md" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Verb implementations sourced from wip-state/ sibling directory.
# All globals above (CMD, N, SID_SET, INJECTED_SID, PROJECT_ID, OWNER,
# PROJECT_NUM, WIP_STATE_* env) are available to the sourced functions.
# ---------------------------------------------------------------------------
_WS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wip-state"
# shellcheck source=wip-state/session-id.sh
. "$_WS_DIR/session-id.sh"
# shellcheck source=wip-state/cmd-set.sh
. "$_WS_DIR/cmd-set.sh"
# shellcheck source=wip-state/cmd-check.sh
. "$_WS_DIR/cmd-check.sh"
# shellcheck source=wip-state/cmd-clear.sh
. "$_WS_DIR/cmd-clear.sh"
# shellcheck source=wip-state/cmd-setup.sh
. "$_WS_DIR/cmd-setup.sh"
# shellcheck source=wip-state/cmd-abandon.sh
. "$_WS_DIR/cmd-abandon.sh"

case "$CMD" in
    set)   cmd_set   "$N" ;;
    check) cmd_check "$N" ;;
    clear) cmd_clear "$N" ;;
    setup) cmd_setup ;;
    abandon) cmd_abandon "$N" ;;
esac
