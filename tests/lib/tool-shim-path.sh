# shellcheck shell=bash
# tests/lib/tool-shim-path.sh — sourced. A PATH made of nothing but one wrapper per tool, so a
# test can take a tool away without dropping the PATH directory it shares with bash or git.
#   tsp_base_path <dir> [<tool>...] — <dir> filled with the TSP_REQUIRED / TSP_OPTIONAL wrappers
#   minus the named tools, printed. rc 1 + stderr: a required tool missing, or a left-out one
#   still resolving. pwsh and uv are never in the base; a case adds its own stub for them.
# A wrapper execs the absolute path PATH gave at build time (the command guard's git included).
# Wrappers are bash scripts a Windows-native child (a node spawn) cannot run: bash callers only.

TSP_REQUIRED=(bash git node awk sed grep head tail cat cut tr sort uniq wc paste mktemp mkdir rm mv cp
  ls touch dirname basename date env)
TSP_OPTIONAL=(sh cygpath timeout perl find xargs tee readlink realpath stat chmod ln cmp comm diff
  join expr seq sleep kill ps uname hostname id nproc getconf flock od sha1sum sha256sum shasum
  md5sum cksum gh glab codex)

# _tsp_wrap <dir> <bash-path> <tool> — rc 1 when <tool> is not on PATH.
_tsp_wrap() {
  local abs
  abs="$(command -v "$3" 2>/dev/null)" || return 1
  [[ "$abs" == /* || "$abs" == [A-Za-z]:* ]] || return 1
  printf '#!%s\nexec %q "$@"\n' "$2" "$abs" >"$1/$3"
}

tsp_base_path() {
  local dir="${1:?tsp_base_path: directory required}" bash_abs t
  shift
  local skip=" $* "
  bash_abs="$(command -v bash 2>/dev/null)" || { echo "tsp_base_path: bash is not on PATH" >&2; return 1; }
  case "$bash_abs" in
    *[[:space:]]*) echo "tsp_base_path: bash path has a space: $bash_abs" >&2; return 1 ;;
  esac
  rm -rf "$dir"
  mkdir -p "$dir" || return 1
  for t in "${TSP_REQUIRED[@]}"; do
    [[ "$skip" == *" $t "* ]] && continue
    _tsp_wrap "$dir" "$bash_abs" "$t" || { echo "tsp_base_path: required tool $t is not on PATH" >&2; return 1; }
  done
  for t in "${TSP_OPTIONAL[@]}"; do
    [[ "$skip" == *" $t "* ]] && continue
    _tsp_wrap "$dir" "$bash_abs" "$t" || true
  done
  chmod +x "$dir"/* || return 1
  for t in "$@"; do
    if PATH="$dir" command -v "$t" >/dev/null 2>&1; then
      echo "tsp_base_path: $t still resolves in $dir" >&2
      return 1
    fi
  done
  printf '%s' "$dir"
}
