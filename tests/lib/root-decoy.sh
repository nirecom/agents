#!/usr/bin/env bash
# tests/lib/root-decoy.sh — sourced. Points AGENTS_MAIN_ROOT and every retired root
# environment name at a tree of stubs (tests/lib/root-decoy-build.js), so a test that reaches
# the wrong root fails loudly. A test that needs the real main worktree settings opts back in
# with root_decoy_use_real_main_root.
#   root_decoy_ensure                reuse ROOT_DECOY_DIR or build under the cache dir, then export
#   root_decoy_use_real_main_root    export AGENTS_MAIN_ROOT from ROOT_DECOY_REAL_AGENTS_MAIN_ROOT
#   root_decoy_hits <tree>           one "<stub path><TAB><test id>" line per recorded hit
#   root_decoy_hit_count <tree>      number of recorded hits

_ROOT_DECOY_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

_root_decoy_native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

_root_decoy_cache_base() {
  if declare -F run_all_cache_dir >/dev/null 2>&1; then
    printf '%s/root-decoy\n' "$(run_all_cache_dir)"
  else
    printf '%s/root-decoy\n' "${RUN_ALL_CACHE_DIR:-${HOME:-.}/.claude/run-all}"
  fi
}

root_decoy_ensure() {
  local builder names name dir key
  builder="$(_root_decoy_native "$_ROOT_DECOY_SCRIPT_CHECKOUT_ROOT/tests/lib/root-decoy-build.js")"
  if ! names="$(node "$builder" --print-retired-env-names)" || [[ -z "$names" ]]; then
    echo "root_decoy_ensure: the retired environment names are unavailable; refusing to run without the old-name decoy" >&2
    return 1
  fi
  dir="${ROOT_DECOY_DIR:-}"
  if [[ -z "$dir" ]]; then
    if ! key="$(node "$builder" --cache-key)" || [[ -z "$key" ]]; then
      echo "root_decoy_ensure: cannot compute the decoy cache key" >&2
      return 1
    fi
    dir="$(_root_decoy_cache_base)/$key"
  fi
  dir="$(_root_decoy_native "$dir")"
  if ! node "$builder" --out "$dir"; then
    echo "root_decoy_ensure: cannot build the decoy at $dir" >&2
    return 1
  fi
  if [[ -z "${ROOT_DECOY_REAL_AGENTS_MAIN_ROOT+x}" ]]; then
    export ROOT_DECOY_REAL_AGENTS_MAIN_ROOT="${AGENTS_MAIN_ROOT:-}"
  fi
  export ROOT_DECOY_DIR="$dir"
  export AGENTS_MAIN_ROOT="$dir/main"
  while IFS= read -r name; do
    name="${name%$'\r'}"
    [[ -n "$name" ]] || continue
    export "$name=$dir/old"
  done <<<"$names"
}

root_decoy_use_real_main_root() {
  if [[ -z "${ROOT_DECOY_REAL_AGENTS_MAIN_ROOT:-}" ]]; then
    echo "root_decoy_use_real_main_root: ROOT_DECOY_REAL_AGENTS_MAIN_ROOT is empty; no real main worktree root was recorded" >&2
    return 1
  fi
  export AGENTS_MAIN_ROOT="$ROOT_DECOY_REAL_AGENTS_MAIN_ROOT"
}

root_decoy_hits() {
  local tree="${1:-}" f line stub=""
  [[ -n "$tree" ]] || { echo "root_decoy_hits: tree directory required" >&2; return 2; }
  for f in "$tree"/hits/*.hit; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      case "$line" in
        stub=*) stub="${line#stub=}" ;;
        test_id=*) printf '%s\t%s\n' "$stub" "${line#test_id=}"; stub="" ;;
      esac
    done <"$f"
  done
}

root_decoy_hit_count() {
  local tree="${1:-}" n=0 _line
  [[ -n "$tree" ]] || { echo "root_decoy_hit_count: tree directory required" >&2; return 2; }
  while IFS= read -r _line; do n=$((n + 1)); done < <(root_decoy_hits "$tree")
  printf '%s\n' "$n"
}
