#!/usr/bin/env bash
# tests/lib/session-repo-fixture.sh — sourced.
# A hook decides "is this my own repo" from the checkout it is launched from, never from the
# environment. A test that wants a temp repo treated as the hook's own repo launches the hook from
# a copy of this checkout that belongs to that temp repo.
#   session_repo_fixture_create <checkout_dir> [prefix...]  copy the tracked files (default: hooks bin)
#   session_repo_fixture_attach <checkout_dir> <repo_dir>   make the copy a checkout of <repo_dir>
#   session_repo_fixture_path <checkout_dir> <rel_path>     print the copied file's path for node
# Copy once per test file, then attach per case: attaching is one small file write.

_SESSION_REPO_FIXTURE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/script-checkout-fixture.sh
. "$_SESSION_REPO_FIXTURE_LIB_DIR/script-checkout-fixture.sh"

_session_repo_fixture_native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

session_repo_fixture_create() {
  local checkout="${1:-}"
  if [[ -z "$checkout" ]]; then
    echo "session_repo_fixture_create: checkout directory required" >&2
    return 1
  fi
  shift
  if [[ "$#" -eq 0 ]]; then set -- hooks bin; fi
  script_checkout_fixture_copy "$checkout" "$@"
}

# Writes <checkout_dir>/.git as a pointer file to the common git dir of <repo_dir>, so git run
# inside the copy reports the same common dir as git run inside <repo_dir>. Re-attaching replaces
# the pointer; the work tree of <repo_dir> is not touched.
session_repo_fixture_attach() {
  local checkout="${1:-}" repo="${2:-}" raw common
  if [[ -z "$checkout" || -z "$repo" ]]; then
    echo "session_repo_fixture_attach: checkout directory and repo directory required" >&2
    return 1
  fi
  if [[ ! -d "$checkout" ]]; then
    echo "session_repo_fixture_attach: no checkout copy at $checkout" >&2
    return 1
  fi
  if ! raw="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null)" || [[ -z "$raw" ]]; then
    echo "session_repo_fixture_attach: $repo is not a git repository" >&2
    return 1
  fi
  case "$raw" in
    [/]*|[A-Za-z]:*) common="$(_session_repo_fixture_native "$raw")" ;;
    *) common="$(_session_repo_fixture_native "$repo")/$raw" ;;
  esac
  rm -rf "$checkout/.git"
  printf 'gitdir: %s\n' "$common" >"$checkout/.git"
}

session_repo_fixture_path() {
  local checkout="${1:-}" rel="${2:-}"
  if [[ -z "$checkout" || -z "$rel" ]]; then
    echo "session_repo_fixture_path: checkout directory and relative path required" >&2
    return 1
  fi
  printf '%s/%s\n' "$(_session_repo_fixture_native "$checkout")" "$rel"
}
