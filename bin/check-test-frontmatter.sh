#!/usr/bin/env bash
# Validates the frontmatter of test entrypoints (*.sh / *.Tests.ps1 / test_*.py
# under tests/): the `# Tests:` header (present,
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

# _is_test_entrypoint <rel> — true for a test entrypoint path: flat tests/<file>.sh
# or 2-level tests/<category>/<file>.sh (canonical category, no deeper nesting).
_is_test_entrypoint() {
  local rel="$1" base cat rest
  base="${rel#tests/}"
  [[ "$base" == "$rel" ]] && return 1
  [[ "$base" != */* ]] && return 0
  cat="${base%%/*}"; rest="${base#*/}"
  [[ "$cat" =~ ^(hooks|bin|skills|agents|install|tests)$ && "$rest" == *.sh && "$rest" != */* ]]
}

# _is_flat_test_sh <rel> — true for a flat tests/<file>.sh (depth-1, no category
# subdir), excluding the run-all.sh infra runner. New flat .sh tests are rejected
# (#1834): a .sh test entrypoint must live under tests/<category>/.
_is_flat_test_sh() {
  local rel="$1" base
  base="${rel#tests/}"
  [[ "$base" == "$rel" ]] && return 1      # not under tests/
  [[ "$base" == */* ]] && return 1          # has a subdir → 2-level, not flat
  [[ "$base" == *.sh ]] || return 1         # only .sh entrypoints
  [[ "$base" == "run-all.sh" ]] && return 1 # infra runner exempt
  return 0
}

# _is_flat_test_nonsh <rel> — sibling of _is_flat_test_sh for a flat tests/*.Tests.ps1
# or tests/test_*.py; new ones are rejected (#2392) under FLAT_TEST_REJECTED.
_is_flat_test_nonsh() {
  local rel="$1" base
  base="${rel#tests/}"
  [[ "$base" == "$rel" ]] && return 1
  [[ "$base" == */* ]] && return 1
  [[ "$base" == *.Tests.ps1 || "$base" == test_*.py ]]
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

# check_harness_source <label> <content>
# Returns 0 when the staged blob contains an actual source/. line that loads
# tests/lib/harness.sh. Comments, echo, and # Tests: headers are NOT counted.
check_harness_source() {
  local f="$1" content="$2"
  if printf '%s\n' "$content" \
       | grep -Eq '^[[:space:]]*(source|\.)[[:space:]]+([^#]*/)?tests/lib/harness\.sh'; then
    return 0
  fi
  echo "MISSING_HARNESS_SOURCE: ${f}" >&2
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
        */tests/*.Tests.ps1|tests/*.Tests.ps1|*/tests/test_*.py|tests/test_*.py|*/tests/*/test_*.py|tests/*/test_*.py) ;;
        *) continue ;;
      esac
      # Compute the repo-relative path once; reused by both the flat-layout
      # rejection and the harness-source check below.
      rel="$f"
      repo_root_hs="$(git rev-parse --show-toplevel 2>/dev/null || true)"
      if [[ "$f" == /* && -n "$repo_root_hs" && "$f" == "$repo_root_hs/"* ]]; then
        rel="${f#"$repo_root_hs"/}"
      fi
      # 2-level enforcement (#1834): a NEWLY-ADDED flat tests/<name>.sh is rejected —
      # .sh test entrypoints must live under tests/<category>/. Existing flat files
      # are grandfathered (swept by #2372); run-all.sh is the infra runner (exempted
      # by _is_flat_test_sh). _is_flat_test_nonsh applies the same rule to
      # .Tests.ps1 / test_*.py (#2392).
      if _is_flat_test_sh "$rel" && ! git cat-file -e "HEAD:${rel}" 2>/dev/null; then
        echo "FLAT_TEST_SH_REJECTED: ${f} (new .sh tests must live under tests/<category>/; categories: hooks bin skills agents install tests)" >&2
        FAIL=1
        continue
      fi
      if _is_flat_test_nonsh "$rel" && ! git cat-file -e "HEAD:${rel}" 2>/dev/null; then
        echo "FLAT_TEST_REJECTED: ${f} (new .Tests.ps1 / test_*.py tests must live under tests/<category>/; categories: hooks bin skills agents install tests)" >&2
        FAIL=1
        continue
      fi
      content="$(staged_content "$f")" || continue
      extract_headers "$content"
      check_content "$f" "$EXT_TESTS" "$EXT_TAGS" || FAIL=1
      # Harness source check: new top-level tests/*.sh files must source harness.sh.
      # Only applies when the repo ships tests/lib/harness.sh (gradual adoption).
      # Only applies to newly-added files (not to edits of existing files).
      if _is_test_entrypoint "$rel" \
         && [[ -n "$repo_root_hs" && -f "$repo_root_hs/tests/lib/harness.sh" ]]; then
        if ! git cat-file -e "HEAD:${rel}" 2>/dev/null; then
          check_harness_source "$f" "$content" || FAIL=1
        fi
      fi
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
    # 2-level layout: scan tests/<category>/{*.sh,*.Tests.ps1,test_*.py} for the six
    # canonical categories. Globs do not cross '/', so split dispatchers' <name>/
    # sub-files are excluded; tests/_archive/ and tests/lib/ are not scanned.
    for cat in hooks bin skills agents install tests; do
      for f in "$root/tests/$cat/"*.sh "$root/tests/$cat/"*.Tests.ps1 "$root/tests/$cat/"test_*.py; do
        rel="${f#"$root"/}"
        extract_headers_file "$f"
        check_content "$rel" "$EXT_TESTS" "$EXT_TAGS" || FAIL=1
      done
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
