#!/bin/bash
# wait-cc-exit.sh — poll for Claude Code process.
# Exit 0 = not running. Exit 1 = still running after the polls, or no way to tell at all.
# Overrides: WAIT_CC_POLL_INTERVAL (default 3s), WAIT_CC_MAX_POLLS (default 10),
#            WAIT_CC_PROC_ROOT (default /proc).
# WAIT_CC_RESULT=clear|timeout (exported once by install.sh) answers at once without polling.
# Test hooks: MOCK_PGREP_MODE=absent|alive|alive:N

set -euo pipefail

case "${WAIT_CC_RESULT:-}" in
    "") ;;
    clear) exit 0 ;;
    timeout) exit 1 ;;
    *) printf 'Ignoring invalid WAIT_CC_RESULT=%s; polling.\n' "$WAIT_CC_RESULT" >&2 ;;
esac

_interval="${WAIT_CC_POLL_INTERVAL:-3}"
_max_polls="${WAIT_CC_MAX_POLLS:-10}"
_proc_root="${WAIT_CC_PROC_ROOT:-/proc}"

# Every probe answers 0 = running (PIDs on stdout), 1 = not running, 2 = this means is unusable
# here. Only builtins parse the answers: the PATH may hold nothing but the probed tool itself.

_probe_pgrep() {
    local _out _rc=0
    command -v pgrep >/dev/null 2>&1 || return 2
    _out="$(pgrep -x "claude" 2>/dev/null)" || _rc=$?
    case "$_rc" in
        0) printf '%s\n' "$_out" ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

# Usable only when at least one process directory exposes a comm file: an empty or foreign
# tree (MSYS lists its own processes without comm) says nothing about a native claude.
_probe_proc() {
    local _dir _pid _comm _usable=2 _found=""
    for _dir in "$_proc_root"/[0-9]*/; do
        _pid="${_dir%/}"
        _pid="${_pid##*/}"
        [[ "$_pid" =~ ^[0-9]+$ && -r "${_dir}comm" ]] || continue
        _usable=1
        _comm=""
        { IFS= read -r _comm < "${_dir}comm"; } 2>/dev/null || true
        if [[ "$_comm" == "claude" ]]; then _found+="${_pid}"$'\n'; fi
    done
    [[ -n "$_found" ]] || return "$_usable"
    printf '%s' "$_found"
}

# No arguments: MSYS rewrites a /FI filter as a path. Case-sensitive on purpose: the Desktop
# app shell is Claude.exe, which the installer does not wait for (wait-cc-exit-target.ps1).
_probe_tasklist() {
    local _out _line _found="" _row='^"?claude\.exe"?[[:space:],]+"?([0-9]+)'
    command -v tasklist >/dev/null 2>&1 || return 2
    _out="$(tasklist 2>/dev/null)" || return 2
    while IFS= read -r _line; do
        if [[ "$_line" =~ $_row ]]; then _found+="${BASH_REMATCH[1]}"$'\n'; fi
    done <<< "$_out"
    [[ -n "$_found" ]] || return 1
    printf '%s' "$_found"
}

# The first usable means decides; a later one is never asked to overrule it. Stdout (PIDs) is
# display-only and stays empty in the mock modes.
_cc_pids() {
    local poll_idx="${1:-0}" _rc=0
    if [[ -n "${MOCK_PGREP_MODE:-}" ]]; then
        case "$MOCK_PGREP_MODE" in
            absent)  return 1 ;;
            alive)   return 0 ;;
            alive:*)
                local n="${MOCK_PGREP_MODE#alive:}"
                [[ "$poll_idx" -lt "$n" ]] && return 0 || return 1 ;;
        esac
    fi
    _probe_pgrep || _rc=$?
    if [[ "$_rc" -eq 2 ]]; then _rc=0; _probe_proc || _rc=$?; fi
    if [[ "$_rc" -eq 2 ]]; then _rc=0; _probe_tasklist || _rc=$?; fi
    return "$_rc"
}

# Sets _pids and returns when Claude Code is running; otherwise ends the script. "Cannot tell"
# is exit 1, never "not running": the caller rewrites settings.json on exit 0 (#2561).
_require_running() {
    local _rc=0
    _pids="$(_cc_pids "$1")" || _rc=$?
    case "$_rc" in
        0) return 0 ;;
        1) exit 0 ;;
    esac
    printf 'Error: cannot determine whether Claude Code is running — no usable pgrep, no process list under %s (the /proc fallback), and no usable tasklist. Skipping this operation.\n' \
        "$_proc_root" >&2
    exit 1
}

_pid_path() {
    local _p=""
    _p="$(readlink "$_proc_root/$1/exe" 2>/dev/null)" || true
    if [[ -z "$_p" ]]; then
        _p="$(ps -p "$1" -o comm= 2>/dev/null)" || true
    fi
    printf '%s\n' "${_p:-(unknown)}"
}

_pids=""
_last_key=""
_poll=0
while [[ "$_poll" -lt "$_max_polls" ]]; do
    _require_running "$_poll"
    if [[ -n "$_pids" ]]; then
        _key="$(printf '%s\n' "$_pids" | sort | tr '\n' ' ')"
        if [[ "$_key" != "$_last_key" ]]; then
            while IFS= read -r _pid; do
                [[ -n "$_pid" ]] || continue
                printf '  PID %s  %s\n' "$_pid" "$(_pid_path "$_pid")" >&2
            done <<< "$_pids"
            _last_key="$_key"
        fi
    fi
    printf "Waiting for Claude Code to exit… (poll %d/%d)\n" \
        "$((_poll + 1))" "$_max_polls" >&2
    sleep "$_interval"
    _poll=$((_poll + 1))
done

_require_running "$_poll"

printf "Warning: Claude Code is still running after %ds — skipping this operation.\n" \
    "$((_max_polls * _interval))" >&2
exit 1
