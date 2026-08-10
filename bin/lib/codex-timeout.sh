#!/usr/bin/env bash
# Shared SSOT for the codex CLI timeout. Source this file:
#   source "$(dirname "$0")/lib/codex-timeout.sh"
#
# Every codex invocation in this repo — plan review, outline review, security-plan
# review, test-coverage review, and the issue-dedupe verdict review — resolves its
# timeout through codex_timeout_resolve, so `.env`'s single CODEX_TIMEOUT_SECS moves
# all of them together and the default lives in exactly one place.
#
# This file is deliberately separate from lib/codex-core.sh: that library exports
# SYSTEM_OPS_APPROVED=1 at source time, and a caller that only needs the timeout
# constant must not inherit that.
#
# Provides: CODEX_TIMEOUT_SECS_DEFAULT, codex_timeout_resolve

# Canonical default, in seconds. 900 s is ~5x the fastest observed full review round
# (184 s measured on a 127 KB test-review payload); the previous 300 s ceiling killed
# rounds of that same payload three times, so the headroom absorbs run-to-run variance
# rather than a systematic shortfall.
CODEX_TIMEOUT_SECS_DEFAULT=900

# codex_timeout_resolve
# Echoes the codex CLI timeout in seconds.
# Resolution order: process env CODEX_TIMEOUT_SECS > .env CODEX_TIMEOUT_SECS >
# CODEX_TIMEOUT_SECS_DEFAULT (bin/get-config-var applies the first two, process env
# winning; this function only supplies the default and the integer guard).
# A missing get-config-var or a non-integer at any layer falls through to the default.
codex_timeout_resolve() {
  local _t="" _gcv="" _dir
  _dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
  if [ -x "$_dir/get-config-var" ]; then
    _gcv="$_dir/get-config-var"
  elif command -v get-config-var > /dev/null 2>&1; then
    _gcv="get-config-var"
  fi
  if [ -n "$_gcv" ]; then
    _t="$(cd "${AGENTS_CONFIG_DIR:-.}" && "$_gcv" CODEX_TIMEOUT_SECS "$CODEX_TIMEOUT_SECS_DEFAULT" 2> /dev/null || true)"
  else
    _t="${CODEX_TIMEOUT_SECS:-}"
  fi
  case "$_t" in
    '' | *[!0-9]*) _t="$CODEX_TIMEOUT_SECS_DEFAULT" ;;
  esac
  printf '%s\n' "$_t"
}
