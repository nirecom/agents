#!/usr/bin/env bash
# Report a test written in another language than the code it tests (#2502 S4), after validating
# the test-lang-exception declaration that lets one through (bin/lib/test-language-match.sh).
# Usage: check-test-language-match.sh [--rel <rel>] [--head <copy> [--head <copy> [--base <copy>]]
#        | --declaration-only] <file>...
#   --rel: the original path of one temp copy (output name, registry entry); --head: a temp copy of
#   a parent version, absent for a new file; two heads (a merge, #2812) judge the 3-way against both
#   and --base, the merge-base copy. --declaration-only: validate only the declaration (a file equal
#   to a parent). Run from the repo root. Exit 0: no HIGH (WARN allowed). 1: HIGH found. 2: usage,
#   a missing file, the library or registry unavailable. Codes: docs/architecture/claude-code/case-marker-gate.md.
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
  echo "Usage: check-test-language-match.sh [--rel <rel>] [--head <copy> [--head <copy> [--base <copy>]] | --declaration-only] <file>..." >&2
  [[ -z "${1:-}" ]] || echo "check-test-language-match.sh: $1" >&2
  exit 2
}

rel=""
head=""
head2=""
base=""
decl_only=0
files=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --rel) [[ "$#" -ge 2 && -n "$2" ]] || _ctlm_usage "--rel needs a value"; rel="$2"; shift 2 ;;
    --head)
      [[ "$#" -ge 2 && -n "$2" ]] || _ctlm_usage "--head needs a value"
      if [[ -z "$head" ]]; then head="$2"; elif [[ -z "$head2" ]]; then head2="$2"; else _ctlm_usage "--head takes at most two copies"; fi
      shift 2 ;;
    --base) [[ "$#" -ge 2 && -n "$2" ]] || _ctlm_usage "--base needs a value"; base="$2"; shift 2 ;;
    --declaration-only) decl_only=1; shift ;;
    --) shift; files+=("$@"); break ;;
    -*) _ctlm_usage "unknown option: $1" ;;
    *) files+=("$1"); shift ;;
  esac
done
[[ "${#files[@]}" -gt 0 ]] || _ctlm_usage
if [[ "$decl_only" -eq 1 && ( -n "$head" || -n "$base" ) ]]; then _ctlm_usage "--declaration-only takes no --head or --base"; fi
if [[ -n "$base" && -z "$head2" ]]; then _ctlm_usage "--base needs two --head copies"; fi
if [[ -n "$rel" && "${#files[@]}" -ne 1 ]]; then _ctlm_usage "--rel takes exactly one file"; fi
if [[ -n "$head" && "${#files[@]}" -ne 1 ]]; then _ctlm_usage "--head takes exactly one file"; fi
for _ctlm_copy in "$head" "$head2" "$base"; do
  if [[ -n "$_ctlm_copy" && ! -f "$_ctlm_copy" ]]; then
    echo "check-test-language-match.sh: head copy not found: $_ctlm_copy" >&2
    exit 2
  fi
done

# Tests: tokens and case targets are repo-relative; extensionless ones are read for a shebang.
TRD_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
export TRD_ROOT
CASE_EMBED_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/check-test-language-match.XXXXXX")"
export CASE_EMBED_CACHE_DIR
trap 'rm -rf "$CASE_EMBED_CACHE_DIR"' EXIT

_ctlm_abs() { printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd)" "${1##*/}"; }

head_abs=""
head2_abs=""
base_abs=""
[[ -z "$head" ]] || head_abs="$(_ctlm_abs "$head")"
[[ -z "$head2" ]] || head2_abs="$(_ctlm_abs "$head2")"
[[ -z "$base" ]] || base_abs="$(_ctlm_abs "$base")"
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
  [[ "$decl_only" -eq 0 ]] || continue

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
  if [[ -n "$head2" ]]; then
    tlm_judge_multi "$abs" "$name" "$base_abs" "$head_abs" "$head2_abs" || rc=$?
  else
    tlm_judge "$abs" "$name" "$head_abs" || rc=$?
  fi
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
