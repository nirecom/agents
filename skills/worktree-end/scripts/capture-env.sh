#!/usr/bin/env bash
# atomicity: This script IS the single Bash call required by SKILL.md Step 5.5 (b-d).
# Do NOT split into multiple Bash calls from SKILL.md. Atomicity required for Windows env-reset safety.
# BRANCH_DELETED MUST NOT appear in output JSON (issue #504 fail-safe).
# Output MUST include four restart categories: cc_restart / vscode_reload / installer_rerun / os_reboot.

set -euo pipefail

WORKTREE="${1:?worktree path required}"
REPO="${2:?owner/repo required}"
BACKUP_DIR="${3:?backup-dir required}"
SESSION_ID="${4:-}"

# Resolution priority (capture-env.sh layer):
#   arg4 > WORKTREE_NOTES.md 'Session-ID:' header > error (#642).
# arg4 (session-id) is optional since #642; empty → fallback to WORKTREE_NOTES.md header.
if [[ -z "$SESSION_ID" ]]; then
  SESSION_ID="$(awk '/^Session-ID:/{sub(/^Session-ID:[[:space:]]*/,""); sub(/\r/,""); print; exit}' \
    "$WORKTREE/WORKTREE_NOTES.md" 2>/dev/null || true)"
fi

if [[ -z "$SESSION_ID" ]]; then
  printf "ERROR: session-id unresolved — pass as arg4 or write 'Session-ID:' header in WORKTREE_NOTES.md\n" >&2
  exit 1
fi
[[ "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]] || { printf "ERROR: invalid SESSION_ID '%s'\n" "$SESSION_ID" >&2; exit 1; }

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR must be set}"
: "${PLANS_DIR:?PLANS_DIR must be set}"

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"

# Step 1: Re-fetch PR_NUMBER (env-reset safe — explicit repo + branch anchors).
BRANCH_NAME="$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
PR_NUMBER="$(gh -R "$REPO" pr list \
  --head "$BRANCH_NAME" --state all --limit 1 \
  --json number --jq '.[0].number')"
if [[ -z "$PR_NUMBER" ]]; then
  printf "ERROR: PR_NUMBER unresolved in capture-env.sh\n" >&2
  exit 1
fi

# Step 2: PR metadata (single gh call, parsed via extract-pr-fields.js).
PR_INFO="$(gh -R "$REPO" pr view "$PR_NUMBER" --json title,url,state)"
PR_FIELDS="$(printf '%s' "$PR_INFO" | node "$LIB_DIR/extract-pr-fields.js" --fields title,url,state)"
PR_TITLE="$(printf '%s\n' "$PR_FIELDS" | awk -F= '$1=="title"{sub(/^title=/,"");print;exit}')"
PR_URL="$(printf '%s\n' "$PR_FIELDS" | awk -F= '$1=="url"{sub(/^url=/,"");print;exit}')"
PR_STATE="$(printf '%s\n' "$PR_FIELDS" | awk -F= '$1=="state"{sub(/^state=/,"");print;exit}')"

# Merge SHA — resolved from PR's mergeCommit.oid (authoritative; survives
# main-worktree env reset). Retry once after 2s to absorb GitHub eventual-
# consistency lag between `gh pr merge` and `gh pr view` reflecting the SHA.
# Hard-fail if still empty: Step 6h cannot write history.md without it.
MERGE_SHA="$(gh -R "$REPO" pr view "$PR_NUMBER" --json mergeCommit --jq '.mergeCommit.oid // empty' 2>/dev/null || echo "")"
if [[ -z "$MERGE_SHA" ]]; then
  sleep 2
  MERGE_SHA="$(gh -R "$REPO" pr view "$PR_NUMBER" --json mergeCommit --jq '.mergeCommit.oid // empty' 2>/dev/null || echo "")"
fi
if [[ -z "$MERGE_SHA" ]]; then
  printf "ERROR: MERGE_SHA unresolved — 'gh -R %s pr view %s --json mergeCommit' returned no oid after retry. PR may not be merged yet, or gh lacks repo scope.\n" "$REPO" "$PR_NUMBER" >&2
  exit 1
fi

# Step 3: Restart detection (four categories).
RESTART_OUTPUT="$(bash "$LIB_DIR/detect-restart.sh" "$PR_NUMBER")"

parse_cat() {
  printf '%s\n' "$RESTART_OUTPUT" | tr -d '\r' \
    | awk -F= -v k="$1" '$1==k { v=$0; sub(/^[^=]*=/, "", v); split(v, a, "|"); print a[1] }'
}
parse_reason() {
  printf '%s\n' "$RESTART_OUTPUT" | tr -d '\r' \
    | awk -F= -v k="$1" '$1==k { v=$0; sub(/^[^=]*=/, "", v); idx=index(v, "|"); print substr(v, idx+1) }'
}

CC_RESTART_REQUIRED="$(parse_cat cc_restart)"
CC_RESTART_REASON="$(parse_reason cc_restart)"
VSCODE_RELOAD_REQUIRED="$(parse_cat vscode_reload)"
VSCODE_RELOAD_REASON="$(parse_reason vscode_reload)"
INSTALLER_RERUN_REQUIRED="$(parse_cat installer_rerun)"
INSTALLER_RERUN_REASON="$(parse_reason installer_rerun)"
# os_reboot: lib always outputs not_required (Option B). Env override permitted.
OS_REBOOT_REQUIRED="${OS_REBOOT_REQUIRED:-$(parse_cat os_reboot)}"
OS_REBOOT_REASON="${OS_REBOOT_REASON:-$(parse_reason os_reboot)}"
if [[ "$OS_REBOOT_REQUIRED" == "required" && -z "$OS_REBOOT_REASON" ]]; then
  OS_REBOOT_REASON="manual env override"
fi

# Legacy alias (deprecated; backward compat).
if [[ "$CC_RESTART_REQUIRED" == "required" ]]; then
  CLAUDE_CODE_RESTART_REQUIRED="yes"
else
  CLAUDE_CODE_RESTART_REQUIRED="no"
fi

# Step 4: Remaining env vars.
BRANCH="$BRANCH_NAME"
WORKTREE_PATH="$WORKTREE"
CREATED_DATE="$(date -u +%Y-%m-%d)"
# Fallback when BACKUP_DIR is the legacy '(none)' sentinel or points to a non-existent dir (discard branch skips Pass 2 — see SKILL.md Step 5, issue #634).
BACKUP_DIR_VALID=0
if [[ "$BACKUP_DIR" != "(none)" && -d "$BACKUP_DIR" ]]; then
  BACKUP_DIR_VALID=1
fi
if [[ "$BACKUP_DIR_VALID" == "1" ]]; then
  BACKUP_MANIFEST_PATH="$BACKUP_DIR/manifest.json"
else
  BACKUP_MANIFEST_PATH="(none)"
fi

# Step 5: Copy WORKTREE_NOTES.md to backup dir (if present).
NOTES_BACKUP_PATH=""
if [[ -f "$WORKTREE/WORKTREE_NOTES.md" ]]; then
  if [[ "$BACKUP_DIR_VALID" == "1" ]]; then
    cp -p "$WORKTREE/WORKTREE_NOTES.md" "$BACKUP_DIR/WORKTREE_NOTES.md"
    NOTES_BACKUP_PATH="$BACKUP_DIR/WORKTREE_NOTES.md"
  else
    NOTES_BACKUP_DIR="$PLANS_DIR/${SESSION_ID}-notes-backup"
    mkdir -p "$NOTES_BACKUP_DIR"
    cp -p "$WORKTREE/WORKTREE_NOTES.md" "$NOTES_BACKUP_DIR/WORKTREE_NOTES.md"
    NOTES_BACKUP_PATH="$NOTES_BACKUP_DIR/WORKTREE_NOTES.md"
  fi
fi

# Step 6: Persist env JSON (BRANCH_DELETED intentionally omitted).
ENV_FILE="$PLANS_DIR/${SESSION_ID}-final-report-env.json"

PR_NUMBER="$PR_NUMBER" PR_TITLE="$PR_TITLE" PR_URL="$PR_URL" PR_STATE="$PR_STATE" \
BRANCH="$BRANCH" WORKTREE_PATH="$WORKTREE_PATH" CREATED_DATE="$CREATED_DATE" \
BACKUP_MANIFEST_PATH="$BACKUP_MANIFEST_PATH" NOTES_BACKUP_PATH="$NOTES_BACKUP_PATH" \
MERGE_SHA="$MERGE_SHA" \
CLAUDE_CODE_RESTART_REQUIRED="$CLAUDE_CODE_RESTART_REQUIRED" \
CC_RESTART_REQUIRED="$CC_RESTART_REQUIRED" CC_RESTART_REASON="$CC_RESTART_REASON" \
VSCODE_RELOAD_REQUIRED="$VSCODE_RELOAD_REQUIRED" VSCODE_RELOAD_REASON="$VSCODE_RELOAD_REASON" \
INSTALLER_RERUN_REQUIRED="$INSTALLER_RERUN_REQUIRED" INSTALLER_RERUN_REASON="$INSTALLER_RERUN_REASON" \
OS_REBOOT_REQUIRED="$OS_REBOOT_REQUIRED" OS_REBOOT_REASON="$OS_REBOOT_REASON" \
  node "$LIB_DIR/write-env-json.js" "$ENV_FILE"

echo "env JSON written: $ENV_FILE"
