#!/usr/bin/env bash
# Validates the frontmatter of tests/*.sh files: the `# Tests:` header (present,
# non-empty, each comma-separated token matching FRONTMATTER_TOKEN_VALID_RE) and
# the `# Tags:` scope tag (scope:issue-specific or scope:common).
# Usage:
#   bin/check-test-frontmatter.sh --staged <file1> [<file2>...]
#   bin/check-test-frontmatter.sh --all [<root>]
# Exit:  0 = all OK, 1 = validation failure on one or more files, 2 = usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/test-frontmatter-constants.sh
source "$SCRIPT_DIR/lib/test-frontmatter-constants.sh"

# _trim <var-name> — trims leading/trailing whitespace in place (no subprocess).
_trim() {
  local __v="${!1}"
  __v="${__v#"${__v%%[![:space:]]*}"}"
  __v="${__v%"${__v##*[![:space:]]}"}"
  printf -v "$1" '%s' "$__v"
}

# check_content <label> <tests-line> <tags-line>
# Validates the extracted `# Tests:` and `# Tags:` header lines. Both header
# lines are passed as strings (may be empty when absent). Returns 1 on any
# failure; all diagnostics go to stderr.
check_content() {
  local f="$1"; local tests_line="$2"; local tags_line="$3"
  local rc=0

  # --- # Tests: header validation ---
  if [[ -z "$tests_line" ]]; then
    echo "MISSING_TESTS_HEADER: ${f}" >&2
    rc=1
  else
    local csv="${tests_line#\# Tests:}"
    _trim csv
    if [[ -z "$csv" ]]; then
      echo "MISSING_TESTS_HEADER: ${f}" >&2
      rc=1
    else
      local toks tok trimmed
      IFS=',' read -r -a toks <<< "$csv"
      for tok in "${toks[@]}"; do
        trimmed="$tok"
        _trim trimmed
        [[ -z "$trimmed" ]] && continue
        if [[ ! "$trimmed" =~ $FRONTMATTER_TOKEN_VALID_RE ]]; then
          echo "INVALID_TESTS_TOKEN: ${f}: ${trimmed}" >&2
          rc=1
        fi
      done
    fi
  fi

  # --- # Tags: scope validation (preserved from check-test-scope-tag.sh) ---
  # Accepts scope:common and scope:issue-specific with optional space after colon.
  if [[ -z "$tags_line" ]]; then
    echo "MISSING_SCOPE_TAG: ${f} (no # Tags: line)" >&2
    rc=1
  elif echo "$tags_line" | grep -qE 'scope:[[:space:]]*(issue-specific|common)'; then
    : # scope tag present
  else
    echo "MISSING_SCOPE_TAG: ${f} (# Tags: line lacks scope:issue-specific or scope:common)" >&2
    rc=1
  fi

  return "$rc"
}

# extract_headers <content> — sets EXT_TESTS / EXT_TAGS from a content string.
extract_headers() {
  local content="$1"
  EXT_TESTS="$(printf '%s\n' "$content" | grep -m1 -E '^# Tests:' || true)"
  EXT_TAGS="$(printf '%s\n' "$content" | grep -m1 -E '^# Tags:' || true)"
}

# extract_headers_file <file> — sets EXT_TESTS / EXT_TAGS by reading a file
# directly (fewer subprocesses than cat|grep — matters for the --all repo scan).
extract_headers_file() {
  local file="$1"
  EXT_TESTS="$(grep -m1 -E '^# Tests:' "$file" 2>/dev/null || true)"
  EXT_TAGS="$(grep -m1 -E '^# Tags:' "$file" 2>/dev/null || true)"
}

# staged_content <file> — prints the content to validate in --staged mode.
# Reads the staged blob via `git show :<rel>` when the path is repo-relative and
# staged; otherwise falls back to the working-tree file (keeps non-git and
# absolute-path callers working).
staged_content() {
  local f="$1"
  local repo_root rel blob
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  rel="$f"
  if [[ "$f" == /* && -n "$repo_root" && "$f" == "$repo_root/"* ]]; then
    rel="${f#"$repo_root"/}"
  fi
  if [[ -n "$repo_root" && "$rel" != /* ]]; then
    if blob="$(git show ":${rel}" 2>/dev/null)"; then
      printf '%s' "$blob"
      return 0
    fi
  fi
  if [[ -f "$f" ]]; then
    cat "$f"
    return 0
  fi
  return 1
}

if [[ $# -eq 0 ]]; then
  echo "Usage:" >&2
  echo "  $(basename "$0") --staged <file1> [<file2>...]" >&2
  echo "  $(basename "$0") --all [<root>]" >&2
  exit 2
fi

mode="$1"; shift

case "$mode" in
  --staged)
    FAIL=0
    for f in "$@"; do
      # Accept both relative (tests/foo.sh) and absolute paths.
      # _archive/ files are excluded regardless of path form.
      case "$f" in
        */tests/_archive/*|tests/_archive/*) continue ;;
        */tests/*.sh|tests/*.sh) ;;
        *) continue ;;
      esac
      content="$(staged_content "$f")" || continue
      extract_headers "$content"
      check_content "$f" "$EXT_TESTS" "$EXT_TAGS" || FAIL=1
    done
    [[ "$FAIL" -eq 1 ]] && exit 1
    exit 0
    ;;
  --all)
    # Accept root as optional positional arg, then REPO_ROOT env var, then git toplevel.
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
      extract_headers_file "$f"
      check_content "$rel" "$EXT_TESTS" "$EXT_TAGS" || FAIL=1
    done
    [[ "$FAIL" -eq 1 ]] && exit 1
    exit 0
    ;;
  *)
    echo "Unknown mode: $mode" >&2
    echo "Usage:" >&2
    echo "  $(basename "$0") --staged <file1> [<file2>...]" >&2
    echo "  $(basename "$0") --all [<root>]" >&2
    exit 2
    ;;
esac
