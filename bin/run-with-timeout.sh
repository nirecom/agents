#!/usr/bin/env bash
# Portable timeout wrapper — GNU timeout where present, perl otherwise (macOS).
# Usage: bin/run-with-timeout.sh <seconds> <command> [args...]
# Exit: the command's code, or 124 when <seconds> ran out (both paths); see bin/lib/timed-exec.sh.
set -uo pipefail
: "${1:?Usage: run-with-timeout.sh <seconds> <command> [args...]}"
case "${BASH_SOURCE[0]}" in
  */*) _rwt_dir="${BASH_SOURCE[0]%/*}" ;;
  *) _rwt_dir="." ;;
esac
# shellcheck source=bin/lib/timed-exec.sh
. "$_rwt_dir/lib/timed-exec.sh"
timed_exec "$@"
