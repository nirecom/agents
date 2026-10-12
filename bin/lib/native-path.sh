# shellcheck shell=bash
# bin/lib/native-path.sh — hand a file path to a native Windows program (gh.exe).
# Callers run gh under MSYS_NO_PATHCONV=1, so MSYS no longer rewrites /tmp/...
# arguments; the conversion happens here, once, at the gh boundary (#2221).
#
# native_path <path> — prints the path to use:
#   `-` (stdin) unchanged, without consulting cygpath;
#   `cygpath -m -- <path>` when cygpath exists and succeeds;
#   the input unchanged otherwise (non-MSYS hosts, or a cygpath failure).
# Sourced library: never exits, always returns 0.

native_path() {
  local in="$1" out
  if [ "$in" = "-" ]; then
    printf '%s' "$in"
    return 0
  fi
  if command -v cygpath >/dev/null 2>&1 && out="$(cygpath -m -- "$in" 2>/dev/null)" && [ -n "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  printf '%s' "$in"
  return 0
}
