# shellcheck shell=bash
# bin/lib/main-worktree.sh — sourced helper; hooks/lib/main-worktree.js is the canonical rule.
# main_worktree_of <dir>: prints the main worktree (the common dir minus its trailing /.git,
# accepted only when that .git is the common dir and core.bare is not true) and returns 0;
# prints nothing and returns 1 for a bare, --separate-git-dir or non-git repository.
# Lists no worktrees, so a failing listing cannot hide the main worktree. Forks only the
# subshell and git: scan-outbound runs this on every commit hook.

_main_worktree_core_bare_is_true() {
  local config="$1/config" line in_core=0 value had_nocase=0 result=1
  [[ -f "$config" ]] || return 0
  shopt -q nocasematch && had_nocase=1
  shopt -s nocasematch
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    if [[ "$line" =~ ^\[[[:space:]]*([^]\ \"]+) ]]; then
      in_core=0
      [[ "${BASH_REMATCH[1]}" == "core" ]] && in_core=1
      continue
    fi
    [[ "$in_core" -eq 1 ]] || continue
    [[ "$line" =~ ^bare([[:space:]]*=[[:space:]]*([^\;#]*))?[[:space:]]*([\;#].*)?$ ]] || continue
    if [[ -z "${BASH_REMATCH[1]}" ]]; then
      value="true"
    else
      value="${BASH_REMATCH[2]}"
      value="${value%"${value##*[![:space:]]}"}"
    fi
    if [[ "$value" =~ ^(true|yes|on|1)$ ]]; then
      result=0
      break
    fi
  done <"$config"
  [[ "$had_nocase" -eq 1 ]] || shopt -u nocasematch
  return "$result"
}

main_worktree_of() {
  local dir="${1:-}"
  [[ -n "$dir" && -d "$dir" ]] || return 1
  (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
    cd "$dir" 2>/dev/null || exit 1
    common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 1
    common="${common%$'\r'}"
    common="${common//\\//}"
    [[ -n "$common" && "${common##*/}" == ".git" ]] || exit 1
    entry="${common%/.git}"
    [[ -n "$entry" && -d "$entry/.git" && ! -L "$entry/.git" ]] || exit 1
    cd -P "$common" 2>/dev/null || exit 1
    common_real="$PWD"
    cd -P "$entry/.git" 2>/dev/null || exit 1
    dotgit_real="$PWD"
    _main_worktree_core_bare_is_true "$common_real" && exit 1
    case "${OSTYPE:-}" in
      msys*|cygwin*|win*) shopt -s nocasematch ;;
    esac
    [[ "$common_real" == "$dotgit_real" ]] || exit 1
    printf '%s\n' "$entry"
  )
}

# same_repository <a> <b>: returns 0 when the two dirs are one physical path, or two
# worktrees of one repository (the same main worktree); 1 otherwise.
same_repository() {
  local a b ma mb
  a="$(cd "${1:-}" 2>/dev/null && pwd -P)" || return 1
  b="$(cd "${2:-}" 2>/dev/null && pwd -P)" || return 1
  [[ "$a" == "$b" ]] && return 0
  ma="$(main_worktree_of "$a")" || return 1
  mb="$(main_worktree_of "$b")" || return 1
  ma="$(cd "$ma" 2>/dev/null && pwd -P)" || return 1
  mb="$(cd "$mb" 2>/dev/null && pwd -P)" || return 1
  [[ "$ma" == "$mb" ]]
}
