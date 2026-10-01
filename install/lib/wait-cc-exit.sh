#!/bin/bash
# wait-cc-exit.sh — poll for Claude Code process; exit 0=clear, exit 1=timeout.
# Overrides: WAIT_CC_POLL_INTERVAL (default 3s), WAIT_CC_MAX_POLLS (default 10).
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

# Return code alone decides "running" (0) vs "absent" (1); stdout (PIDs) is display-only
# and stays empty in the mock modes.
_cc_pids() {
    local poll_idx="${1:-0}" _out
    if [[ -n "${MOCK_PGREP_MODE:-}" ]]; then
        case "$MOCK_PGREP_MODE" in
            absent)  return 1 ;;
            alive)   return 0 ;;
            alive:*)
                local n="${MOCK_PGREP_MODE#alive:}"
                [[ "$poll_idx" -lt "$n" ]] && return 0 || return 1 ;;
        esac
    fi
    _out="$(pgrep -x "claude" 2>/dev/null)" || return 1
    printf '%s\n' "$_out"
    return 0
}

_pid_path() {
    local _p=""
    _p="$(readlink "/proc/$1/exe" 2>/dev/null)" || true
    if [[ -z "$_p" ]]; then
        _p="$(ps -p "$1" -o comm= 2>/dev/null)" || true
    fi
    printf '%s\n' "${_p:-(unknown)}"
}

_last_key=""
_poll=0
while [[ "$_poll" -lt "$_max_polls" ]]; do
    if ! _pids="$(_cc_pids "$_poll")"; then exit 0; fi
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

if ! _pids="$(_cc_pids "$_poll")"; then exit 0; fi

printf "Warning: Claude Code is still running after %ds — skipping this operation.\n" \
    "$((_max_polls * _interval))" >&2
exit 1
