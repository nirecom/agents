#!/usr/bin/env bash
# Checks that tests/*.sh files carry a scope:issue-specific or scope:common tag.
# Usage:
#   bin/check-test-scope-tag.sh --staged <file1> [<file2>...]
#   bin/check-test-scope-tag.sh --all
# Exit:  0 = all OK, 1 = scope tag missing on one or more files, 2 = usage error

set -euo pipefail

# Accepts scope:common and scope:issue-specific with optional space after colon.
# Canonical form (test-design.md) has no space, but defensive tolerance is applied
# so hand-written files with 'scope: common' do not block commits unnecessarily.
check_file() {
  local f="$1"
  local tags_line
  tags_line="$(grep -m1 -E '^# Tags:' "$f" 2>/dev/null || true)"
  if [[ -z "$tags_line" ]]; then
    echo "MISSING_SCOPE_TAG: ${f} (no # Tags: line)" >&2
    return 1
  fi
  if echo "$tags_line" | grep -qE 'scope:[[:space:]]*(issue-specific|common)'; then
    return 0
  fi
  echo "MISSING_SCOPE_TAG: ${f} (# Tags: line lacks scope:issue-specific or scope:common)" >&2
  return 1
}

if [[ $# -eq 0 ]]; then
  echo "Usage:" >&2
  echo "  $(basename "$0") --staged <file1> [<file2>...]" >&2
  echo "  $(basename "$0") --all" >&2
  exit 2
fi

mode="$1"; shift

case "$mode" in
  --staged)
    FAIL=0
    for f in "$@"; do
      # Accept both relative paths (tests/foo.sh) and absolute paths (/tmp/.../tests/foo.sh).
      # _archive/ files are excluded regardless of path form.
      case "$f" in
        */tests/_archive/*|tests/_archive/*) continue ;;
        */tests/*.sh|tests/*.sh) ;;
        *) continue ;;
      esac
      check_file "$f" || FAIL=1
    done
    [[ "$FAIL" -eq 1 ]] && exit 1
    exit 0
    ;;
  --all)
    # Accept root as optional positional arg, then REPO_ROOT env var, then git toplevel.
    # This allows tests to pass a fixture root without touching the git index.
    if [[ $# -gt 0 && -n "$1" ]]; then
      root="$1"
    elif [[ -n "${REPO_ROOT:-}" ]]; then
      root="$REPO_ROOT"
    else
      root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
        echo "ERROR: not inside a git repository" >&2
        exit 2
      }
    fi
    shopt -s nullglob
    FAIL=0
    # tests/*.sh glob does not match _archive/ subdirectory
    for f in "$root/tests/"*.sh; do
      rel="tests/$(basename "$f")"
      check_file "$rel" || FAIL=1
    done
    [[ "$FAIL" -eq 1 ]] && exit 1
    exit 0
    ;;
  *)
    echo "Unknown mode: $mode" >&2
    echo "Usage:" >&2
    echo "  $(basename "$0") --staged <file1> [<file2>...]" >&2
    echo "  $(basename "$0") --all" >&2
    exit 2
    ;;
esac
