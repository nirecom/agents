#!/usr/bin/env bash
# clarify-commit-scope.sh — GH reconcile extraction for clarify-intent (#513)
# Args: --session-id <sid> --plans-dir <dir> --issues <csv>
#       [--repo-map IDX:owner/repo ...] [--non-github] [--repo <slug>]
# stdout: CREATED:<N> | CLOSED:<N> | RC2 | SCAN_BLOCKED
# exit: 0 success, 1 gh failure or missing intent.md, 2 CLOSED entry or WIP RC2,
#       2 bad plans-dir, 2 Path C outbound-scan block (stdout SCAN_BLOCKED)
#
# Path B (non-empty --issues): CLOSED pre-scan first (no side effects until all clear),
#   then per-N: gh issue edit --add-label → wip-set-single.sh → ensure-board-card.sh.
# Path C (empty --issues): title/body from <sid>-intent.md → outbound scan guard →
#   gh issue create --label intent:clarified → CREATED:<N>. A scan block prints
#   SCAN_BLOCKED, writes the reason to <plans-dir>/<sid>-intent-scan-block.txt
#   (the caller discards stderr), and exits 2.
# --non-github: skip all gh calls, exit 0.
# --repo-map IDX:owner/repo: per-issue repo routing for Path B (repeatable).
# --repo <slug>: repo for Path C gh issue create (backward compat).
set -uo pipefail

if [ "${AGENTS_BASH_MAJOR_OVERRIDE:-${BASH_VERSINFO:-0}}" -lt 4 ]; then
  printf '[clarify-commit-scope] requires bash >= 4 (found %s). Install a newer bash: '"'"'brew install bash'"'"'.\n' "${BASH_VERSION:-unknown}" >&2
  exit 1
fi

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR must be set}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/gh-outbound-guard.sh
source "$SCRIPT_DIR/../lib/gh-outbound-guard.sh"

SESSION_ID=""
PLANS_DIR_ARG=""
ISSUES_CSV=""
ISSUES_SET=0
NON_GITHUB=0
REPO_SLUG=""
declare -A REPO_OF

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session-id)  SESSION_ID="${2:-}"; shift 2 ;;
        --plans-dir)   PLANS_DIR_ARG="${2:-}"; shift 2 ;;
        --issues)      ISSUES_CSV="${2:-}"; ISSUES_SET=1; shift 2 ;;
        --non-github)  NON_GITHUB=1; shift ;;
        --repo)        REPO_SLUG="${2:-}"; shift 2 ;;
        --repo-map)
            [ $# -lt 2 ] && { echo "[clarify-commit-scope] --repo-map requires a value" >&2; exit 2; }
            KEY="${2%%:*}"; VAL="${2#*:}"; REPO_OF["$KEY"]="$VAL"; shift 2
            ;;
        --repo-map=*)
            PAIR="${1#--repo-map=}"; KEY="${PAIR%%:*}"; VAL="${PAIR#*:}"; REPO_OF["$KEY"]="$VAL"; shift
            ;;
        *) echo "[clarify-commit-scope] unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Hard-validate plans-dir: normalize and prefix-check against expected base.
REAL_PLANS_DIR=$(cd "$PLANS_DIR_ARG" 2>/dev/null && pwd) || {
    echo "[clarify-commit-scope] plans-dir does not exist or is inaccessible: $PLANS_DIR_ARG" >&2
    exit 2
}
EXPECTED_BASE="${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}"
REAL_EXPECTED_BASE=$(cd "$EXPECTED_BASE" 2>/dev/null && pwd) || REAL_EXPECTED_BASE="$EXPECTED_BASE"
case "$REAL_PLANS_DIR" in
    "$REAL_EXPECTED_BASE" | "$REAL_EXPECTED_BASE"/*) ;;
    *)
        echo "[clarify-commit-scope] plans-dir '$PLANS_DIR_ARG' is outside expected base '$EXPECTED_BASE'" >&2
        exit 2
        ;;
esac

# --non-github: skip all gh calls
if [[ "$NON_GITHUB" -eq 1 ]]; then
    exit 0
fi

REPO_ARGS=()
if [[ -n "$REPO_SLUG" ]]; then
    REPO_ARGS+=("--repo" "$REPO_SLUG")
fi

# Path C: empty --issues
if [[ "$ISSUES_SET" -eq 1 && -z "$ISSUES_CSV" ]]; then
    # shellcheck source=lib/intent-to-issue.sh
    source "$SCRIPT_DIR/lib/intent-to-issue.sh"
    INTENT_PATH="$REAL_PLANS_DIR/$SESSION_ID-intent.md"
    if [[ ! -f "$INTENT_PATH" ]]; then
        echo "[clarify-commit-scope] intent.md not found: $INTENT_PATH" >&2
        exit 1
    fi
    TITLE_LINE="$(intent_extract_title "$INTENT_PATH")"
    BODY_TEXT="$(intent_extract_body "$INTENT_PATH")"

    # Guard runs in THIS shell via redirection (never a pipe) so
    # GH_OUTBOUND_GUARD_MESSAGE survives for the sidecar write below.
    SCAN_TMP=$(mktemp)
    printf '%s\n\n%s\n' "$TITLE_LINE" "$BODY_TEXT" > "$SCAN_TMP"
    SIDECAR="$REAL_PLANS_DIR/$SESSION_ID-intent-scan-block.txt"
    # Fixed literal label, never the local intent.md path: the content scanned is
    # composed issue title/body text, not that file's own content, so a
    # caller-local path must never coincidentally match an unrelated allowlist glob.
    if ! gh_outbound_guard "intent-derived-issue-body" < "$SCAN_TMP"; then
        # run-completion.sh discards this script's stderr — the sidecar file is
        # the only channel the caller can surface the block reason through.
        printf '%s\n' "$GH_OUTBOUND_GUARD_MESSAGE" > "$SIDECAR"
        rm -f "$SCAN_TMP"
        echo "SCAN_BLOCKED"
        exit 2
    fi
    rm -f "$SCAN_TMP"

    GH_OUT=""
    if ! GH_OUT=$(gh issue create \
            --title "$TITLE_LINE" \
            --body "$BODY_TEXT" \
            --label "intent:clarified" \
            ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} 2>/dev/null); then
        echo "[clarify-commit-scope] gh issue create failed" >&2
        exit 1
    fi
    # Extract issue number from URL (last path component)
    ISSUE_NUM="${GH_OUT##*/}"
    echo "CREATED:${ISSUE_NUM}"
    exit 0
fi

# Path B: non-empty --issues
# Split CSV into array
IFS=',' read -ra ISSUE_LIST <<< "$ISSUES_CSV"

# Build clean array (trim spaces, skip blanks)
CLEAN_ISSUES=()
for N in "${ISSUE_LIST[@]}"; do
    N="${N// /}"
    [[ -z "$N" ]] && continue
    CLEAN_ISSUES+=("$N")
done

# CLOSED pre-scan FIRST — before any side effects
for i in "${!CLEAN_ISSUES[@]}"; do
    N="${CLEAN_ISSUES[$i]}"
    STATE_OUT=""
    STATE_RC=0
    STATE_OUT=$(issue-state-check.sh ${REPO_OF[$i]:+--repo "${REPO_OF[$i]}"} "$N" 2>/dev/null) || STATE_RC=$?
    if [[ "$STATE_OUT" = "closed" ]]; then
        echo "CLOSED:${N}"
        exit 2
    fi
done

# Per-N side effects: label → wip → board
for i in "${!CLEAN_ISSUES[@]}"; do
    N="${CLEAN_ISSUES[$i]}"
    ISSUE_REPO_ARGS=()
    if [ -n "${REPO_OF[$i]:-}" ]; then
        ISSUE_REPO_ARGS+=(--repo "${REPO_OF[$i]}")
    fi
    gh issue edit "$N" --add-label "intent:clarified" ${ISSUE_REPO_ARGS[@]+"${ISSUE_REPO_ARGS[@]}"} 2>/dev/null || true
    WIP_RC=0
    # C4 fix: wip-set-single.sh does not accept "set" as a positional verb
    WIP_OUT=$(wip-set-single.sh ${ISSUE_REPO_ARGS[@]+"${ISSUE_REPO_ARGS[@]}"} "$N" 2>/dev/null) || WIP_RC=$?
    if [[ "$WIP_RC" -eq 2 ]]; then
        echo "RC2"
        exit 2
    fi
    ensure-board-card.sh ${ISSUE_REPO_ARGS[@]+"${ISSUE_REPO_ARGS[@]}"} "$N" 2>/dev/null || true
done

exit 0
