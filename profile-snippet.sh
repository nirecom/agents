#!/usr/bin/env bash
# Sourced from dotfiles' .profile_common (sibling-detected) or directly from ~/.bashrc.
# Idempotent — safe to source twice.
if [ -n "${ZSH_VERSION-}" ]; then
    _agents_root="$(cd "$(dirname "${(%):-%x}")" && pwd)"
else
    _agents_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
export AGENTS_CONFIG_DIR="$_agents_root"
export AGENTS_DIR="$_agents_root"

_agent_broken=0
for _f in "$HOME/.claude/CLAUDE.md" "$HOME/.claude/skills" "$HOME/.claude/rules" "$HOME/.claude/agents"; do
    if [ -e "$_f" ] && [ ! -L "$_f" ]; then _agent_broken=1; break; fi
done
if [ "$_agent_broken" = "1" ]; then
    echo "Repairing agents symlink(s)..."
    "$_agents_root/install/linux/dotfileslink.sh"
fi

# Auto-pull Claude Code session sync repo (~/.claude/projects/) on startup.
_session_dir="$HOME/.claude/projects"
if type git >/dev/null 2>&1 && [ -d "$_session_dir/.git" ]; then
    echo "git fetch Claude session sync ..."
    ( git -C "$_session_dir" fetch ) &
    _pid_ss=$!
    _ss_deadline=$(( $(date +%s) + 3 ))
    while kill -0 "$_pid_ss" 2>/dev/null; do
        if [ "$(date +%s)" -ge "$_ss_deadline" ]; then kill "$_pid_ss" 2>/dev/null; break; fi
        sleep 0.2
    done
    wait "$_pid_ss" 2>/dev/null
    _rc_ss=$?
    [ "$_rc_ss" -eq 0 ] && git -C "$_session_dir" merge --ff-only FETCH_HEAD 2>/dev/null
    unset _pid_ss _ss_deadline _rc_ss
fi
unset _session_dir

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

# Launch VS Code with session sync (push on close)
codes() {
    local target="${1:-.}"
    local name
    if [[ "$target" == *.code-workspace ]]; then
        name="$(basename "$target" .code-workspace)"
    else
        name="$(basename "$(cd "$target" 2>/dev/null && pwd || echo "$target")")"
    fi
    (
        code --new-window "$@"
        "$AGENTS_DIR/bin/wait-vscode-window.sh" "$name"
        if _any_vscode_window; then
            "$AGENTS_DIR/bin/session-sync.sh" push --quiet
        else
            "$AGENTS_DIR/bin/session-sync.sh" push --quiet --toast
        fi
    ) &
    disown
}

unset _agents_root _agent_broken _f
