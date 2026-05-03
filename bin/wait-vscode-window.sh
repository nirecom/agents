#!/bin/bash
# wait-vscode-window.sh - Wait for a VS Code window to close by polling window titles
# Usage: wait-vscode-window.sh <title-pattern> [poll-interval] [appear-timeout]
#
# Phase 1: Wait for a window matching "<title-pattern> - Visual Studio Code" to appear
# Phase 2: Wait for that window to disappear, then exit
#
# Detection tools (tried in order): xdotool, wmctrl, osascript (macOS)

set -euo pipefail

TITLE_PATTERN="${1:-}"
POLL_INTERVAL="${2:-5}"
APPEAR_TIMEOUT="${3:-30}"

if [ -z "$TITLE_PATTERN" ]; then
    echo "Usage: wait-vscode-window.sh <title-pattern>" >&2
    exit 1
fi

SUFFIX="$TITLE_PATTERN - Visual Studio Code"
SUFFIX_WS="$TITLE_PATTERN (Workspace) - Visual Studio Code"

# Select detection method and define has_vscode_window()
if type xdotool >/dev/null 2>&1; then
    has_vscode_window() {
        local wid title
        for wid in $(xdotool search --name "Visual Studio Code" 2>/dev/null); do
            title=$(xdotool getwindowname "$wid" 2>/dev/null) || continue
            case "$title" in
                *" - $SUFFIX"*|"$SUFFIX"*|*" - $SUFFIX_WS"*|"$SUFFIX_WS"*) return 0 ;;
            esac
        done
        return 1
    }
elif type wmctrl >/dev/null 2>&1; then
    has_vscode_window() {
        local t
        while IFS= read -r t; do
            # wmctrl -l format: <WID> <desktop> <hostname> <title>
            t="${t#* * * }"
            case "$t" in
                *" - $SUFFIX"*|"$SUFFIX"*|*" - $SUFFIX_WS"*|"$SUFFIX_WS"*) return 0 ;;
            esac
        done < <(wmctrl -l 2>/dev/null)
        return 1
    }
elif [ -n "${WSL_DISTRO_NAME:-}" ] && command -v powershell.exe >/dev/null 2>&1; then
    has_vscode_window() {
        local result
        result=$(powershell.exe -NoProfile -Command "[System.Diagnostics.Process]::GetProcessesByName('Code') | Where-Object { \$_.MainWindowTitle -like '* - $SUFFIX*' -or \$_.MainWindowTitle -like '$SUFFIX*' -or \$_.MainWindowTitle -like '* - $SUFFIX_WS*' -or \$_.MainWindowTitle -like '$SUFFIX_WS*' } | Select-Object -First 1 -ExpandProperty MainWindowTitle" 2>/dev/null | tr -d '\r')
        [ -n "$result" ]
    }
elif [ "$(uname)" = "Darwin" ]; then
    has_vscode_window() {
        local t
        while IFS= read -r t; do
            case "$t" in
                *" - $SUFFIX"*|"$SUFFIX"*|*" - $SUFFIX_WS"*|"$SUFFIX_WS"*) return 0 ;;
            esac
        done < <(osascript <<'APPLESCRIPT' 2>/dev/null
tell application "System Events"
    set output to ""
    repeat with p in (every process whose name contains "Code")
        repeat with w in (every window of p)
            set output to output & (name of w) & linefeed
        end repeat
    end repeat
    output
end tell
APPLESCRIPT
        )
        return 1
    }
else
    echo "Warning: No window detection tool found (xdotool/wmctrl). Session sync skipped." >&2
    exit 1
fi

# Phase 1: Wait for window to appear
appeared=false
elapsed=0
while [ "$elapsed" -lt "$APPEAR_TIMEOUT" ]; do
    sleep 3
    elapsed=$((elapsed + 3))
    if has_vscode_window; then appeared=true; break; fi
done
if [ "$appeared" = false ]; then exit 0; fi

# Phase 2: Wait for window to disappear
while has_vscode_window; do
    sleep "$POLL_INTERVAL"
done
