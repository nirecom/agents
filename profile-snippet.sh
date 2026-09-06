#!/usr/bin/env bash
# Sourced from dotfiles' .profile_common (sibling-detected) or directly from ~/.bashrc.
# Idempotent — safe to source twice.
[ -n "${_AGENTS_PROFILE_LOADED-}" ] && return 0 2>/dev/null
_AGENTS_PROFILE_LOADED=1
if [ -n "${ZSH_VERSION-}" ]; then
    _agents_root="$(cd "$(dirname "${(%):-%x}")" && pwd)"
else
    _agents_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
export AGENTS_CONFIG_DIR="$_agents_root"
export AGENTS_DIR="$_agents_root"

# Startup progress wording, shared with bin/sweep-shell-snapshots.sh (issue #2160).
# The inline fallback covers a checkout missing the lib; keep the two literals
# byte-identical to the library's, or the sweep stops recognising the corruption.
# shellcheck source=bin/lib/session-sync-markers.sh
if [ -f "$_agents_root/bin/lib/session-sync-markers.sh" ]; then
    . "$_agents_root/bin/lib/session-sync-markers.sh"
else
    AGENTS_SESSION_SYNC_FETCH_MARKER='git fetch Claude session sync ...'
    AGENTS_SYMLINK_REPAIR_MARKER='Repairing agents symlink(s)...'
fi

# Global default for Claude Code's auto-compact token window, read from .env.
# get-config-var resolves process-env-wins-over-.env precedence itself, so a value
# already set in this shell (or by a launcher such as code-ccgw.cmd for a single
# local-LLM session) is left untouched.
if [ -x "$_agents_root/bin/get-config-var" ]; then
    _acw="$("$_agents_root/bin/get-config-var" CLAUDE_CODE_AUTO_COMPACT_WINDOW 2>/dev/null)"
    [ -n "$_acw" ] && export CLAUDE_CODE_AUTO_COMPACT_WINDOW="$_acw"
    unset _acw
fi

_agent_broken=0
for _f in "$HOME/.claude/CLAUDE.md" "$HOME/.claude/skills" "$HOME/.claude/rules" "$HOME/.claude/agents"; do
    if [ -L "$_f" ]; then
        # symlink present — check if target resolves
        [ ! -e "$_f" ] && { _agent_broken=1; break; }
    elif [ -e "$_f" ]; then
        # regular file/dir occupying the slot
        _agent_broken=1; break
    else
        # missing entirely
        _agent_broken=1; break
    fi
done
if [ "$_agent_broken" = "1" ]; then
    # Both lines go to stderr: Claude Code captures a login shell's stdout into
    # ~/.claude/shell-snapshots/*.sh, where any stray line corrupts the snapshot's
    # `export PATH='...'` (issue #2160).
    echo "$AGENTS_SYMLINK_REPAIR_MARKER" >&2
    "$_agents_root/install/linux/dotfileslink.sh" >&2
fi

# Auto-pull Claude Code session sync repo (~/.claude/projects/) on startup.
# Claude Code's Bash tool always runs non-interactively, so CLAUDECODE set plus a
# non-TTY stdout reliably identifies a CC-launched shell — skip the fetch there.
# No effect when Windows-native Claude Code bridges into WSL2 (CLAUDECODE does not
# propagate into that shell); WSL-native Claude Code is unaffected. Mirrors the
# guard in dotfiles' .profile_common (issue #335).
if [ -n "${CLAUDECODE:-}" ] && [ ! -t 1 ]; then
    :
else
_session_dir="$HOME/.claude/projects"
if type git >/dev/null 2>&1 && [ -d "$_session_dir/.git" ]; then
    # SESSION_SYNC is opt-in (default off): only an explicit `on` enables automatic
    # session sync. get-config-var --is-off exits 1 for explicit ON; every other
    # exit (off / empty / unrecognized / internal failure / node missing) keeps it
    # off. Always use `if ...; then ...; fi` below, never `[ cond ] && var=1` — the
    # latter is a top-level command whose failure status kills the script under
    # set -e (see install.sh).
    _ss_rc=0
    "$_agents_root/bin/get-config-var" --is-off SESSION_SYNC off >/dev/null 2>&1 || _ss_rc=$?
    _ss_on=0
    if [ "$_ss_rc" -eq 1 ]; then _ss_on=1; fi
    if [ "$_ss_on" = "1" ]; then
        # Frequency guard (issue #2160): fetch at most once per 30 minutes, keyed on
        # the mtime of a stamp inside .git/ so session-sync's own `git add .` can
        # never pick it up. An absent stamp fails OPEN (first shell after install
        # must still sync), and every step is written as `if ...; then ...; fi` —
        # `[ cond ] && var=1` as a script's last command returns its own failure
        # status and can kill a login shell running under `set -e`.
        _ss_stamp="$_session_dir/.git/agents-last-fetch"
        _ss_due=1
        if [ -f "$_ss_stamp" ]; then
            _ss_mtime="$(stat -c %Y "$_ss_stamp" 2>/dev/null || stat -f %m "$_ss_stamp" 2>/dev/null || echo 0)"
            _ss_now="$(date +%s)"
            if [ "$(( _ss_now - _ss_mtime ))" -lt 1800 ]; then _ss_due=0; fi
        fi
        if [ "$_ss_due" = "1" ]; then
            # Stamp the ATTEMPT, before launching it: a stamp written afterwards
            # lets a shell started mid-fetch launch a second one, and a stamp
            # written only on success retries a broken remote every startup.
            # Failing to write it costs the suppression, never the fetch.
            touch "$_ss_stamp" 2>/dev/null || true
            # Honour a configured core.sshCommand instead of overriding it. Read
            # from the session repo (`-C`), never the caller's CWD, and compared
            # as a quoted string — the value is repo config, i.e. untrusted input,
            # so it must never be re-expanded or evaluated. Empty counts as unset:
            # git answers 0 with an empty line for `key =`, and exporting an empty
            # GIT_SSH_COMMAND breaks git's ssh launch.
            _ss_sshcmd="$(git -C "$_session_dir" config --get core.sshCommand 2>/dev/null || true)"
            _session_sync_fetch() {
                if [ -n "${ZSH_VERSION-}" ]; then setopt LOCAL_OPTIONS NO_MONITOR; fi
                echo "$AGENTS_SESSION_SYNC_FETCH_MARKER" >&2
                if [ -n "$_ss_sshcmd" ]; then
                    ( GIT_TERMINAL_PROMPT=0 git -C "$_session_dir" fetch 2>/dev/null ) &
                else
                    ( GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' git -C "$_session_dir" fetch 2>/dev/null ) &
                fi
                _pid_ss=$!
                _ss_deadline=$(( $(date +%s) + 3 ))
                while kill -0 "$_pid_ss" 2>/dev/null; do
                    if [ "$(date +%s)" -ge "$_ss_deadline" ]; then kill "$_pid_ss" 2>/dev/null || true; break; fi
                    sleep 0.2
                done
                _rc_ss=0
                wait "$_pid_ss" 2>/dev/null || _rc_ss=$?
            }
            _session_sync_fetch
            unset -f _session_sync_fetch 2>/dev/null
            # `merge --ff-only` prints "Updating .../Fast-forward" on stdout.
            if [ "${_rc_ss:-1}" -eq 0 ]; then git -C "$_session_dir" merge --ff-only FETCH_HEAD >/dev/null 2>&1 || true; fi
            unset _pid_ss _ss_deadline _rc_ss _ss_sshcmd
        fi
        unset _ss_stamp _ss_due _ss_mtime _ss_now
    fi
    unset _ss_on _ss_rc
fi
unset _session_dir
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
}

unset _agents_root _agent_broken _f AGENTS_SESSION_SYNC_FETCH_MARKER AGENTS_SYMLINK_REPAIR_MARKER
