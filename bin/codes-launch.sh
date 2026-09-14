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
# Read CC_NATIVE_* pinned model versions from .env and resolve CLAUDE_MODEL / CLAUDE_SMALL_MODEL.
# Tier detection reads ~/.claude/settings.json so each tier var applies only when CC is configured
# for that tier -- all four can be set simultaneously without conflict.
_pinned_model=""
_pinned_subagent=""
if [ -x "$AGENTS_DIR/bin/get-config-var" ]; then
    _cc_model=""
    _cc_settings="$HOME/.claude/settings.json"
    if [ -f "$_cc_settings" ]; then
        _cc_model=$(node -e "try{var s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));process.stdout.write((s.model||'').toLowerCase())}catch{}" "$_cc_settings" 2>/dev/null) || true
    fi
    _tier_var="CC_NATIVE_OPUS"
    case "$_cc_model" in
        *fable*)  _tier_var="CC_NATIVE_FABLE"  ;;
        *sonnet*) _tier_var="CC_NATIVE_SONNET" ;;
        *haiku*)  _tier_var="CC_NATIVE_HAIKU"  ;;
    esac
    _pinned_model=$("$AGENTS_DIR/bin/get-config-var" "$_tier_var" 2>/dev/null) || true
    _pinned_subagent=$("$AGENTS_DIR/bin/get-config-var" CC_NATIVE_SUBAGENT 2>/dev/null) || true
fi
(
    [ -n "$_pinned_model" ]    && export CLAUDE_MODEL="$_pinned_model"
    [ -n "$_pinned_subagent" ] && export CLAUDE_SMALL_MODEL="$_pinned_subagent"
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
