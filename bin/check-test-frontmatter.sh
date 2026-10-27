#!/usr/bin/env bash
# Validates the frontmatter of test entrypoints (files under tests/ whose name matches a
# supported test-language registry entry): the `# Tests:` header (present,
# non-empty, each comma-separated token matching FRONTMATTER_TOKEN_VALID_RE) and
# the `# Tags:` scope tag (scope:issue-specific or scope:common).
# Usage:
#   bin/check-test-frontmatter.sh --staged [--merge-parents <file>] <file1> [<file2>...]
#   bin/check-test-frontmatter.sh --all [<root>]
#   --merge-parents: the bin/merge-parents record file; without it, one CLI call is made here.
# Exit:  0 = all OK, 1 = validation failure on one or more files, 2 = usage error
#        or the registry is unreadable

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/test-frontmatter-constants.sh
source "$SCRIPT_DIR/lib/test-frontmatter-constants.sh" || { echo "ERROR: test language registry not readable" >&2; exit 2; }
# shellcheck source=lib/test-frontmatter-headers.sh
source "$SCRIPT_DIR/lib/test-frontmatter-headers.sh" || { echo "ERROR: lib/test-frontmatter-headers.sh not readable" >&2; exit 2; }

# _trim <var-name> — trims leading/trailing whitespace in place (no subprocess).
_trim() {
  local __v="${!1}"
  __v="${__v#"${__v%%[![:space:]]*}"}"
  __v="${__v%"${__v##*[![:space:]]}"}"
  printf -v "$1" '%s' "$__v"
}

# _is_supported_test <path> — the name matches a supported registry entry (sets TLR_ID).
_is_supported_test() {
  tlr_match "$1" && [[ "$TLR_STATUS" == supported ]]
}

# _is_test_entrypoint <rel> — true for a test entrypoint whose entry has a helperLibrary:
# flat tests/<file> or 2-level tests/<category>/<file> (canonical category, no deeper
# nesting). Sets HL_PATH / HL_RE from that entry.
_is_test_entrypoint() {
  local rel="$1" base cat rest
  base="${rel#tests/}"
  [[ "$base" == "$rel" ]] && return 1
  if [[ "$base" == */* ]]; then
    cat="${base%%/*}"; rest="${base#*/}"
    [[ "$cat" =~ ^(hooks|bin|skills|agents|install|tests)$ && "$rest" != */* ]] || return 1
  fi
  _is_supported_test "$base" && _tlr_get "$TLR_ID" helperLibrary.path || return 1
  HL_PATH="$_TLR_V"
  _tlr_get "$TLR_ID" helperLibrary.sourceRegex || return 1
  HL_RE="$_TLR_V"
}

# _is_flat_test <rel> — true for a flat tests/<file> (depth-1, no category subdir) of a
# supported entry, excluding the run-all.sh infra runner. New flat tests are rejected
# (#1834, #2392): a test entrypoint must live under tests/<category>/.
_is_flat_test() {
  local rel="$1" base
  base="${rel#tests/}"
  [[ "$base" == "$rel" ]] && return 1      # not under tests/
  [[ "$base" == */* ]] && return 1          # has a subdir → 2-level, not flat
  [[ "$base" == "run-all.sh" ]] && return 1 # infra runner exempt
  _is_supported_test "$base"
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
    local csv="${tests_line#*Tests:}"
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

# staged_content <file> <repo-root> — prints the content to validate in --staged mode.
# Reads the staged blob via `git show :<rel>` when the path is repo-relative and
# staged; otherwise falls back to the working-tree file (keeps non-git and
# absolute-path callers working). <repo-root> is empty outside a git repository.
staged_content() {
  local f="$1" repo_root="$2"
  local rel blob
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

# check_harness_source <label> <content> <regex>
# Returns 0 when the staged blob has a line matching the entry's helperLibrary.sourceRegex
# (an actual load of the helper library; comments and headers do not match).
check_harness_source() {
  local f="$1" content="$2"
  if printf '%s\n' "$content" | grep -Eq -- "$3"; then
    return 0
  fi
  echo "MISSING_HARNESS_SOURCE: ${f}" >&2
  return 1
}

if [[ $# -eq 0 ]]; then
  echo "Usage:" >&2
  echo "  $(basename "$0") --staged [--merge-parents <file>] <file1> [<file2>...]" >&2
  echo "  $(basename "$0") --all [<root>]" >&2
  exit 2
fi

mode="$1"; shift

case "$mode" in
  --staged)
    FAIL=0
    mp_file=""
    if [[ "${1:-}" == --merge-parents ]]; then
      [[ "$#" -ge 2 && -n "$2" ]] || { echo "ERROR: --merge-parents needs a file" >&2; exit 2; }
      mp_file="$2"; shift 2
    fi
    # The self-impl sibling is staged-mode only, so --all never needs it on disk.
    # shellcheck source=check-test-frontmatter/self-impl.sh
    source "$SCRIPT_DIR/check-test-frontmatter/self-impl.sh" || { echo "ERROR: check-test-frontmatter/self-impl.sh not readable" >&2; exit 2; }
    repo_root_hs="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    st_files=()
    st_rels=()
    for f in "$@"; do
      # Accept both relative (tests/foo.sh) and absolute paths.
      # _archive/ files are excluded regardless of path form.
      case "$f" in
        */tests/_archive/*|tests/_archive/*) continue ;;
        */tests/*|tests/*) _is_supported_test "$f" || continue ;;
        *) continue ;;
      esac
      # Compute the repo-relative path once; reused by every check below.
      rel="$f"
      if [[ "$f" == /* && -n "$repo_root_hs" && "$f" == "$repo_root_hs/"* ]]; then
        rel="${f#"$repo_root_hs"/}"
      fi
      st_files+=("$f")
      st_rels+=("$rel")
    done
    # A test any parent commit has (HEAD, or MERGE_HEAD during a merge, #2812) is not a new one.
    ctf_parents_load "$mp_file" ${st_rels[@]+"${st_rels[@]}"}
    for ((st_i = 0; st_i < ${#st_files[@]}; st_i++)); do
      f="${st_files[st_i]}"
      rel="${st_rels[st_i]}"
      # 2-level enforcement (#1834, #2392): a NEWLY-ADDED flat test is rejected with its
      # entry's flatRejectCode and nameLabel. Existing flat files are grandfathered
      # (swept by #2372); run-all.sh is the infra runner (exempted by _is_flat_test).
      if _is_flat_test "$rel" && ! ctf_in_parent "$rel"; then
        _tlr_get "$TLR_ID" diagnostics.flatRejectCode || true
        code="$_TLR_V"
        _tlr_get "$TLR_ID" diagnostics.nameLabel || true
        echo "${code}: ${f} (new ${_TLR_V} tests must live under tests/<category>/; categories: hooks bin skills agents install tests)" >&2
        FAIL=1
        continue
      fi
      content="$(staged_content "$f" "$repo_root_hs")" || continue
      extract_headers "$content" "$f"
      check_content "$f" "$EXT_TESTS" "$EXT_TAGS" || FAIL=1
      # Helper-library check: a new entrypoint of an entry with a helperLibrary must load
      # it, once the repo ships that library (gradual adoption). Edits are exempt.
      if _is_test_entrypoint "$rel" \
         && [[ -n "$repo_root_hs" && -f "$repo_root_hs/$HL_PATH" ]]; then
        if ! ctf_in_parent "$rel"; then
          check_harness_source "$f" "$content" "$HL_RE" || FAIL=1
        fi
      fi
      # Self-implemented harness check (#2502): every language; an existing file blocks only on
      # a detection its parent versions lack. Queued here, judged in one run after the loop.
      ctf_self_impl_add "$rel" "$content"
    done
    ctf_self_impl_run || FAIL=1
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
    FAIL=0
    # 2-level layout: the supported tests directly in tests/<category>/ for the six
    # canonical categories. Split dispatchers' <name>/ sub-files are excluded;
    # tests/_archive/ and tests/lib/ are not scanned.
    for cat in hooks bin skills agents install tests; do
      tlr_list_dir_into "$root/tests/$cat" supported || continue
      for f in ${TLR_LIST[@]+"${TLR_LIST[@]}"}; do
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
    echo "  $(basename "$0") --staged [--merge-parents <file>] <file1> [<file2>...]" >&2
    echo "  $(basename "$0") --all [<root>]" >&2
    exit 2
    ;;
esac
