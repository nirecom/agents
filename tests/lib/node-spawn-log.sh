#!/usr/bin/env bash
# tests/lib/node-spawn-log.sh — sourced. Bash side of tests/lib/node-spawn-log.js: records the
# process starts of every Node process run between nsl_on and nsl_off, on any OS.
#   nsl_on <log>                     export the preload (an existing NODE_OPTIONS is kept)
#   nsl_off                          restore NODE_OPTIONS and stop recording
#   nsl_count <log> <kind> <regex>   records of <kind> (spawn|main|any) matching <regex>; a regex
#                                    must not start with "/" (MSYS rewrites such an argv as a path)
# A test must check a "main" record of its entry point before trusting a zero count.

_NSL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

_nsl_native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

_NSL_JS="$(_nsl_native "$_NSL_ROOT/tests/lib/node-spawn-log.js")"
_NSL_SAVED_SET=0
_NSL_SAVED=""

nsl_on() {
  rm -f "$1"
  _NSL_SAVED_SET=0
  _NSL_SAVED=""
  if [ -n "${NODE_OPTIONS+x}" ]; then _NSL_SAVED_SET=1; _NSL_SAVED="$NODE_OPTIONS"; fi
  export TEST_NODE_SPAWN_LOG
  TEST_NODE_SPAWN_LOG="$(_nsl_native "$1")"
  export NODE_OPTIONS
  NODE_OPTIONS="${_NSL_SAVED:+$_NSL_SAVED }--require \"$_NSL_JS\""
}

nsl_off() {
  if [ "$_NSL_SAVED_SET" = 1 ]; then NODE_OPTIONS="$_NSL_SAVED"; else unset NODE_OPTIONS; fi
  unset TEST_NODE_SPAWN_LOG
}

nsl_count() {
  node "$_NSL_JS" count "$(_nsl_native "$1")" "$2" "$3"
}
