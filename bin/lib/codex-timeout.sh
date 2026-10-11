#!/usr/bin/env bash
# Shared SSOT for the codex CLI timeout: every codex call site resolves through
# codex_timeout_resolve, so `.env`'s single CODEX_TIMEOUT_SECS moves all of them.
# Source: source "$(dirname "$0")/lib/codex-timeout.sh"
# Separate from lib/codex-core.sh so a caller needing only the timeout skips its
# init/logging surface. Provides: CODEX_TIMEOUT_SECS_DEFAULT, codex_timeout_resolve
# 900 s is ~5x the fastest observed full review round (184 s on a 127 KB payload);
# the previous 300 s ceiling killed rounds of that same payload three times.
CODEX_TIMEOUT_SECS_DEFAULT=900

# codex_timeout_resolve
# Echoes the codex CLI timeout in seconds.
# Resolution order: process env CODEX_TIMEOUT_SECS > .env CODEX_TIMEOUT_SECS >
# CODEX_TIMEOUT_SECS_DEFAULT (bin/get-config-var applies the first two, process env
# winning; this function only supplies the default and the integer guard).
# Only this checkout's own get-config-var is used: a PATH copy may belong to another
# checkout. When it is missing, a warning names it and process env applies; a non-integer
# falls to the default.
codex_timeout_resolve() {
  local _t="" _gcv="" _dir
  _dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
  if [ -x "$_dir/get-config-var" ]; then
    _gcv="$_dir/get-config-var"
  fi
  if [ -n "$_gcv" ]; then
    _t="$(cd "$_dir/.." && "$_gcv" CODEX_TIMEOUT_SECS "$CODEX_TIMEOUT_SECS_DEFAULT" 2> /dev/null || true)"
  else
    printf 'codex-timeout: %s/get-config-var not found; .env not read\n' "$_dir" >&2
    _t="${CODEX_TIMEOUT_SECS:-}"
  fi
  case "$_t" in
    '' | *[!0-9]*) _t="$CODEX_TIMEOUT_SECS_DEFAULT" ;;
  esac
  printf '%s\n' "$_t"
}
