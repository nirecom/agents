#!/bin/bash
# session-sync.sh - Sync Claude Code session history across machines
# Usage:
#   session-sync.sh push    # Integrate local session data and publish it
#   session-sync.sh pull    # Integrate remote session data into this machine
#   session-sync.sh status  # Show sync status
#   session-sync.sh reset   # Integrate onto the remote state without pushing (setup / recovery)
# Integration lives in bin/session-sync-engine (#2658); this entry validates arguments,
# warns about a running Claude Code, and turns a quiet result into an optional toast.

set -euo pipefail

# Run from the link target so the checkout root below is the real checkout, not the link's directory.
if [ -L "${BASH_SOURCE[0]}" ] && _ss_real="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null)" && [ -n "$_ss_real" ]; then
    exec bash "$_ss_real" "$@"
fi
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

_usage() {
    echo "Usage: session-sync.sh {push|pull|status|reset} [--claude-dir DIR] [--quiet] [--toast]" >&2
}

ACTION="${1:-}"
CLAUDE_DIR="$HOME/.claude"
_QUIET=0
_TOAST=0

shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --claude-dir) [ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }; CLAUDE_DIR="$2"; shift 2 ;;
        --quiet) _QUIET=1; shift ;;
        --toast) _TOAST=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

case "$ACTION" in
    push|pull|status|reset) ;;
    *) _usage; exit 1 ;;
esac

PROJECTS_DIR="$CLAUDE_DIR/projects"
PLANS_DIR=""
if [ -x "$SCRIPT_CHECKOUT_ROOT/bin/workflow-plans-dir" ]; then
    PLANS_DIR="$("$SCRIPT_CHECKOUT_ROOT/bin/workflow-plans-dir")" || PLANS_DIR=""
fi
if [ -z "$PLANS_DIR" ]; then
    PLANS_DIR="$HOME/.workflow-plans"
    [ "$_QUIET" = "1" ] || echo "session-sync: $SCRIPT_CHECKOUT_ROOT/bin/workflow-plans-dir unavailable; using $PLANS_DIR" >&2
fi

if [ ! -d "$PROJECTS_DIR/.git" ]; then
    echo "Session sync not initialized. Run install.sh or install/linux/session-sync-init.sh first." >&2
    exit 1
fi

_toast() {
    local msg="$1"
    if command -v powershell.exe >/dev/null 2>&1; then
        powershell.exe -NoProfile -Command "[void][Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime];[void][Windows.Data.Xml.Dom.XmlDocument,Windows.Data.Xml.Dom.XmlDocument,ContentType=WindowsRuntime];\$x=[Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(1);\$t=\$x.GetElementsByTagName('text');\$t.Item(0).AppendChild(\$x.CreateTextNode('session-sync'))|Out-Null;\$t.Item(1).AppendChild(\$x.CreateTextNode('$msg'))|Out-Null;[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('PowerShell').Show([Windows.UI.Notifications.ToastNotification]::new(\$x))" 2>/dev/null || true
    elif command -v osascript >/dev/null 2>&1; then
        osascript -e "display notification \"$msg\" with title \"session-sync\"" || true
    elif command -v notify-send >/dev/null 2>&1; then
        notify-send "session-sync" "$msg" || true
    fi
}

if [ "$ACTION" = "push" ]; then
    # Transcripts still being written by a live session may be pushed half-flushed.
    if [ "$_QUIET" = "0" ] && pgrep -x "claude" >/dev/null 2>&1; then
        echo "WARNING: Claude Code is running. Close all sessions before push to ensure latest data is saved." >&2
    fi
fi

_engine_args=("$ACTION" --claude-dir "$CLAUDE_DIR" --plans-dir "$PLANS_DIR")
[ "$_QUIET" = "1" ] && _engine_args+=(--quiet)
_rc=0
node "$SCRIPT_CHECKOUT_ROOT/bin/session-sync-engine" "${_engine_args[@]}" || _rc=$?

if [ "$_QUIET" = "1" ]; then
    if [ "$ACTION" = "push" ]; then
        if [ "$_rc" -eq 0 ]; then
            [ "$_TOAST" = "1" ] && _toast "push complete"
        else
            [ "$_TOAST" = "1" ] && _toast "push failed (exit code $_rc)"
        fi
    fi
    exit 0
fi
[ "$_rc" -eq 0 ] || exit 1
