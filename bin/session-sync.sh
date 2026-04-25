#!/bin/bash
# session-sync.sh - Sync Claude Code session history across machines
# Usage:
#   session-sync.sh push    # Commit and push session data
#   session-sync.sh pull    # Pull latest session data
#   session-sync.sh status  # Show sync status
#   session-sync.sh reset   # Force-sync local to remote (for initial setup or recovery)

set -euo pipefail

ACTION="${1:-}"
CLAUDE_DIR="$HOME/.claude"
_QUIET=0
_TOAST=0

# Parse options
shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --claude-dir) CLAUDE_DIR="$2"; shift 2 ;;
        --quiet) _QUIET=1; shift ;;
        --toast) _TOAST=1; shift ;;
        *) shift ;;
    esac
done

PROJECTS_DIR="$CLAUDE_DIR/projects"

if [ ! -d "$PROJECTS_DIR/.git" ]; then
    echo "Session sync not initialized. Run install.sh or install/linux/session-sync-init.sh first." >&2
    exit 1
fi

_toast() {
    local msg="$1"
    if command -v powershell.exe >/dev/null 2>&1; then
        powershell.exe -NoProfile -Command "[void][Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime];[void][Windows.Data.Xml.Dom.XmlDocument,Windows.Data.Xml.Dom.XmlDocument,ContentType=WindowsRuntime];\$x=[Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(1);\$t=\$x.GetElementsByTagName('text');\$t.Item(0).AppendChild(\$x.CreateTextNode('session-sync'))|Out-Null;\$t.Item(1).AppendChild(\$x.CreateTextNode('$msg'))|Out-Null;[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('PowerShell').Show([Windows.UI.Notifications.ToastNotification]::new(\$x))" 2>/dev/null
    elif command -v osascript >/dev/null 2>&1; then
        osascript -e "display notification \"$msg\" with title \"session-sync\""
    elif command -v notify-send >/dev/null 2>&1; then
        notify-send "session-sync" "$msg"
    fi
}


case "$ACTION" in
    push)
        # Warn if Claude Code is running
        if [ "$_QUIET" = "0" ] && pgrep -x "claude" >/dev/null 2>&1; then
            echo "WARNING: Claude Code is running. Close all sessions before push to ensure latest data is saved." >&2
        fi
        # Abort any interrupted rebase before proceeding
        if [ -d "$PROJECTS_DIR/.git/rebase-merge" ] || [ -d "$PROJECTS_DIR/.git/rebase-apply" ]; then
            git -C "$PROJECTS_DIR" rebase --abort 2>/dev/null || \
                rm -rf "$PROJECTS_DIR/.git/rebase-merge" "$PROJECTS_DIR/.git/rebase-apply" 2>/dev/null || true
        fi
        # Copy history.jsonl into sync area
        cp "$CLAUDE_DIR/history.jsonl" "$PROJECTS_DIR/.history.jsonl" 2>/dev/null || true
        git -C "$PROJECTS_DIR" add .
        _local_changes=$(git -C "$PROJECTS_DIR" status --porcelain)
        _unpushed=$(git -C "$PROJECTS_DIR" log origin/main..HEAD --oneline 2>/dev/null || true)
        if [ -z "$_local_changes" ] && [ -z "$_unpushed" ]; then
            echo "No changes to push."
            exit 0
        fi
        if [ -n "$_local_changes" ]; then
            timestamp=$(date "+%Y-%m-%d %H:%M")
            git -C "$PROJECTS_DIR" commit -q -m "sync: $(hostname -s) $timestamp"
        fi
        # Retry loop: handles simultaneous push race (e.g. Windows + macOS committing at the same time)
        _push_ok=0
        for _retry in 1 2 3; do
            # Commit any new session files written since the last commit
            git -C "$PROJECTS_DIR" add . 2>/dev/null || true
            if [ -n "$(git -C "$PROJECTS_DIR" status --porcelain 2>/dev/null)" ]; then
                _ts2=$(date "+%Y-%m-%d %H:%M")
                git -C "$PROJECTS_DIR" commit -q -m "sync: $(hostname -s) $_ts2" 2>/dev/null || true
            fi
            if ! git -C "$PROJECTS_DIR" pull --rebase origin main >/dev/null 2>&1; then
                # Auto-resolve JSONL conflicts: strip conflict markers and dedup
                _conflicts=$(git -C "$PROJECTS_DIR" diff --name-only --diff-filter=U 2>/dev/null || true)
                _resolved=0
                for _f in $_conflicts; do
                    case "$_f" in
                        *.jsonl)
                            grep -v -e '^<<<<<<<' -e '^=======' -e '^>>>>>>>' \
                                "$PROJECTS_DIR/$_f" | awk '!seen[$0]++' \
                                > "$PROJECTS_DIR/$_f.tmp" && \
                            mv "$PROJECTS_DIR/$_f.tmp" "$PROJECTS_DIR/$_f"
                            git -C "$PROJECTS_DIR" add "$_f" 2>/dev/null || true
                            _resolved=1
                            ;;
                    esac
                done
                if [ "$_resolved" = "1" ]; then
                    GIT_EDITOR=true git -C "$PROJECTS_DIR" rebase --continue >/dev/null 2>&1 || true
                else
                    git -C "$PROJECTS_DIR" rebase --abort 2>/dev/null || true
                fi
            fi
            if git -C "$PROJECTS_DIR" push -u origin main 2>/dev/null; then
                _push_ok=1
                break
            fi
        done
        if [ "$_push_ok" = "1" ]; then
            if [ "$_QUIET" = "1" ]; then
                [ "$_TOAST" = "1" ] && _toast "push complete"
                :
            else
                echo "Pushed session data."
            fi
        else
            if [ "$_QUIET" = "1" ]; then
                [ "$_TOAST" = "1" ] && _toast "push failed"
                :
            else
                echo "git push failed after 3 retries" >&2
                exit 1
            fi
        fi
        ;;
    pull)
        git -C "$PROJECTS_DIR" pull --rebase 2>&1 | grep -Ev '^\s*(create|delete) mode '; [ "${PIPESTATUS[0]}" -eq 0 ]
        # Merge remote history with local (dedup, preserve order)
        if [ -f "$PROJECTS_DIR/.history.jsonl" ]; then
            if [ -f "$CLAUDE_DIR/history.jsonl" ]; then
                cat "$PROJECTS_DIR/.history.jsonl" "$CLAUDE_DIR/history.jsonl"
            else
                cat "$PROJECTS_DIR/.history.jsonl"
            fi | awk '!seen[$0]++' > "$CLAUDE_DIR/history.jsonl.tmp"
            mv "$CLAUDE_DIR/history.jsonl.tmp" "$CLAUDE_DIR/history.jsonl"
        fi
        echo "Pulled session data."
        ;;
    status)
        git -C "$PROJECTS_DIR" status
        ;;
    reset)
        git -C "$PROJECTS_DIR" fetch origin main
        git -C "$PROJECTS_DIR" reset --hard origin/main
        # Restore mtime from JSONL timestamps (git doesn't preserve mtime)
        find "$PROJECTS_DIR" -name "*.jsonl" ! -name ".history.jsonl" | while read -r f; do
            ts=$(tail -1 "$f" 2>/dev/null | grep -o '"timestamp":"[^"]*"' | head -1 | cut -d'"' -f4) || true
            [ -z "$ts" ] && ts=$(head -1 "$f" 2>/dev/null | grep -o '"timestamp":"[^"]*"' | head -1 | cut -d'"' -f4) || true
            [ -n "$ts" ] && touch -d "$ts" "$f" 2>/dev/null || true
        done
        # Merge remote history with local (dedup, preserve order)
        if [ -f "$PROJECTS_DIR/.history.jsonl" ]; then
            if [ -f "$CLAUDE_DIR/history.jsonl" ]; then
                cat "$PROJECTS_DIR/.history.jsonl" "$CLAUDE_DIR/history.jsonl"
            else
                cat "$PROJECTS_DIR/.history.jsonl"
            fi | awk '!seen[$0]++' > "$CLAUDE_DIR/history.jsonl.tmp"
            mv "$CLAUDE_DIR/history.jsonl.tmp" "$CLAUDE_DIR/history.jsonl"
        fi
        echo "Reset to remote state."
        ;;
    *)
        echo "Usage: session-sync.sh {push|pull|status|reset}" >&2
        exit 1
        ;;
esac
