#!/bin/bash
# codes-launch.sh - Launch VS Code with session sync (push on close).
# Invoked as a separate process from profile-snippet.sh's `codes` wrapper -- every
# call re-reads this file from disk, so edits here (unlike edits to a function
# sourced into an interactive shell) take effect immediately, with no need to
# re-source the profile or open a new shell.

AGENTS_DIR="${AGENTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Re-apply the VS Code extension's worktree-visibility patch (every extension
# auto-upgrade overwrites it) and prune stale stub sessions before the extension
# host loads -- best-effort: a repair failure must never block a `codes` launch.
if [ -e "$AGENTS_DIR/bin/vscode-cc-repair" ]; then
    node "$AGENTS_DIR/bin/vscode-cc-repair" --prune-stub-sessions || true
fi

# Returns true if any VS Code window is currently open
_any_vscode_window() {
    if [ "$(uname)" = "Darwin" ]; then
        local count
        count=$(osascript -e 'tell application "System Events" to (count (every window of every process whose name contains "Code"))' 2>/dev/null)
        [ "${count:-0}" -gt 0 ]
    elif type xdotool >/dev/null 2>&1; then
        xdotool search --name "Visual Studio Code" 2>/dev/null | grep -q .
    elif type wmctrl >/dev/null 2>&1; then
        wmctrl -l 2>/dev/null | grep -q "Visual Studio Code"
    else
        return 1
    fi
}

target="${1:-.}"
if [[ "$target" == *.code-workspace ]]; then
    name="$(basename "$target" .code-workspace)"
else
    name="$(basename "$(cd "$target" 2>/dev/null && pwd || echo "$target")")"
fi
(
    code --new-window "$@"
    _ss_rc=0
    "$AGENTS_DIR/bin/get-config-var" --is-off SESSION_SYNC off >/dev/null 2>&1 || _ss_rc=$?
    _ss_on=0
    if [ "$_ss_rc" -eq 1 ]; then _ss_on=1; fi
    if [ "$_ss_on" = "1" ]; then
        "$AGENTS_DIR/bin/wait-vscode-window.sh" "$name"
        if _any_vscode_window; then
            "$AGENTS_DIR/bin/session-sync.sh" push --quiet
        else
            "$AGENTS_DIR/bin/session-sync.sh" push --quiet --toast
        fi
    fi
) &
disown
