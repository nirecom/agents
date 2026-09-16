#!/bin/bash
# wait-cc-exit.sh — poll for Claude Code process; exit 0=clear, exit 1=timeout.
# Overrides: WAIT_CC_POLL_INTERVAL (default 3s), WAIT_CC_MAX_POLLS (default 10).
# Test hooks: MOCK_PGREP_MODE=absent|alive|alive:N

set -euo pipefail

_interval="${WAIT_CC_POLL_INTERVAL:-3}"
_max_polls="${WAIT_CC_MAX_POLLS:-10}"

_is_cc_running() {
    local poll_idx="${1:-0}"
    if [ -n "${MOCK_PGREP_MODE:-}" ]; then
        case "$MOCK_PGREP_MODE" in
            absent)  return 1 ;;
            alive)   return 0 ;;
            alive:*)
                local n="${MOCK_PGREP_MODE#alive:}"
                [ "$poll_idx" -lt "$n" ] && return 0 || return 1 ;;
        esac
    fi
    pgrep -x "claude" >/dev/null 2>&1
}

_poll=0
while [ "$_poll" -lt "$_max_polls" ]; do
    if ! _is_cc_running "$_poll"; then
        exit 0
    fi
    printf "Waiting for Claude Code to exit… (poll %d/%d)\n" \
        "$((_poll + 1))" "$_max_polls" >&2
    sleep "$_interval"
    _poll=$((_poll + 1))
done

if ! _is_cc_running "$_poll"; then
    exit 0
fi

printf "Warning: Claude Code is still running after %ds — skipping this operation.\n" \
    "$((_max_polls * _interval))" >&2
exit 1
