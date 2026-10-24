#!/usr/bin/env bash
# Report a test written in another language than the code it tests (#2502 S4), after validating
# the test-lang-exception declaration that lets one through (bin/lib/test-language-match.sh).
# Usage: check-test-language-match.sh [--rel <rel>] [--head <head-copy>] <file>...
#   --rel: the original path of one temp copy (output name, registry entry); --head: a temp copy
#   of the HEAD version, absent for a new file. Both take one file. Run from the repo root.
# Exit 0: no HIGH (WARN lines allowed). 1: HIGH found. 2: usage, a missing file, the library or
# the registry unavailable (infra error). Codes: docs/architecture/claude-code/case-marker-gate.md.
set -euo pipefail

_ctlm_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/test-language-match.sh
if [[ ! -f "$_ctlm_lib/test-language-match.sh" ]] || ! source "$_ctlm_lib/test-language-match.sh" 2>/dev/null \
   || ! declare -F tlm_judge >/dev/null; then
  echo "check-test-language-match.sh: library unavailable" >&2
  exit 2
fi
if ! tlr_load; then
  echo "check-test-language-match.sh: registry unreadable" >&2
  exit 2
fi

_ctlm_usage() {
  echo "Usage: check-test-language-match.sh [--rel <rel>] [--head <head-copy>] <file>..." >&2
  [[ -z "${1:-}" ]] || echo "check-test-language-match.sh: $1" >&2
  exit 2
}

rel=""
head=""
files=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --rel) [[ "$#" -ge 2 && -n "$2" ]] || _ctlm_usage "--rel needs a value"; rel="$2"; shift 2 ;;
    --head) [[ "$#" -ge 2 && -n "$2" ]] || _ctlm_usage "--head needs a value"; head="$2"; shift 2 ;;
    --) shift; files+=("$@"); break ;;
    -*) _ctlm_usage "unknown option: $1" ;;
    *) files+=("$1"); shift ;;
  esac
done
[[ "${#files[@]}" -gt 0 ]] || _ctlm_usage
if [[ -n "$rel" && "${#files[@]}" -ne 1 ]]; then _ctlm_usage "--rel takes exactly one file"; fi
if [[ -n "$head" && "${#files[@]}" -ne 1 ]]; then _ctlm_usage "--head takes exactly one file"; fi
if [[ -n "$head" && ! -f "$head" ]]; then
  echo "check-test-language-match.sh: head copy not found: $head" >&2
  exit 2
fi

# Tests: tokens and case targets are repo-relative; extensionless ones are read for a shebang.
TRD_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
export TRD_ROOT
CASE_EMBED_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/check-test-language-match.XXXXXX")"
export CASE_EMBED_CACHE_DIR
trap 'rm -rf "$CASE_EMBED_CACHE_DIR"' EXIT

_ctlm_abs() { printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd)" "${1##*/}"; }

head_abs=""
[[ -z "$head" ]] || head_abs="$(_ctlm_abs "$head")"
violations=0
infra=0
for file in "${files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "check-test-language-match.sh: file not found: $file" >&2
    exit 2
  fi
  name="${rel:-$file}"
  abs="$(_ctlm_abs "$file")"

  # (a) The declaration is validated on every file; an invalid one counts as no declaration.
  exception=""
  if tlm_lang_exception "$abs" "$name"; then
    exception="$TLM_LANG_EXCEPTION"
  else
    echo "HIGH: $name: invalid test-lang-exception value '$TLM_LANG_EXCEPTION_BAD' (allowed: ${TLR_LANG_EXCEPTIONS:-none}) code=INVALID_TEST_LANG_EXCEPTION"
    violations=1
  fi

  # (b) A test language the registry does not support is reported, not passed silently.
  if ! tlr_match "$name"; then
    echo "WARN: $name: test language not checked (no test language registry entry matches this name) code=TEST_LANGUAGE_UNSUPPORTED"
    continue
  fi
  if [[ "$TLR_STATUS" != supported ]]; then
    echo "WARN: $name: test language not checked ($TLR_ID is $TLR_STATUS in the test language registry) code=TEST_LANGUAGE_UNSUPPORTED"
    continue
  fi

  # (c) A valid declaration lets a mismatch through.
  [[ -z "$exception" ]] || continue
  rc=0
  tlm_judge "$abs" "$name" "$head_abs" || rc=$?
  case "$rc" in
    0) ;;
    1) violations=1 ;;
    *)
      echo "check-test-language-match.sh: language match not judged (rc=$rc): $name" >&2
      infra=1 ;;
  esac
done

[[ "$violations" -eq 1 ]] && exit 1
[[ "$infra" -eq 1 ]] && exit 2
exit 0
