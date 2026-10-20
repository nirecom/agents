#!/usr/bin/env bash
# Report a test that builds its own harness (a hand-made pass/fail counter, or a redefinition of
# a helper-library name) through the caseEmbedRules self-impl op, for every registered language.
# Usage: check-self-impl.sh [--rel <rel>] <file>...   (--rel: the original path of one temp copy;
# it names the file in the output and picks the registry entry)
# Prints HIGH: ... code=SELF_IMPLEMENTED_HARNESS per detection and
# WARN: ... code=SELF_IMPL_CHECK_UNSUPPORTED | SELF_IMPL_CHECK_RUNTIME_UNAVAILABLE per unchecked file.
# Exit 0: no HIGH (WARN lines allowed). Exit 1: HIGH found. Exit 2: usage, a missing file, the
# library or the registry unavailable, or an op failure (infra error). Codes: case-marker-gate.md.
set -euo pipefail

_csi_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/test-language-registry.sh
if [[ ! -f "$_csi_lib/test-language-registry.sh" || ! -f "$_csi_lib/test-self-impl-window.sh" ]] \
   || ! source "$_csi_lib/test-language-registry.sh" 2>/dev/null \
   || ! source "$_csi_lib/test-self-impl-window.sh" 2>/dev/null || ! declare -F tsi_report >/dev/null; then
  echo "check-self-impl.sh: library unavailable" >&2
  exit 2
fi
if ! tlr_load; then
  echo "check-self-impl.sh: registry unreadable" >&2
  exit 2
fi

_csi_usage() {
  echo "Usage: check-self-impl.sh [--rel <rel>] <file>..." >&2
  [[ -z "${1:-}" ]] || echo "check-self-impl.sh: $1" >&2
  exit 2
}

rel=""
files=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --rel) [[ "$#" -ge 2 && -n "$2" ]] || _csi_usage "--rel needs a value"; rel="$2"; shift 2 ;;
    --) shift; files+=("$@"); break ;;
    -*) _csi_usage "unknown option: $1" ;;
    *) files+=("$1"); shift ;;
  esac
done
[[ "${#files[@]}" -gt 0 ]] || _csi_usage
if [[ -n "$rel" && "${#files[@]}" -ne 1 ]]; then _csi_usage "--rel takes exactly one file"; fi

CASE_EMBED_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/check-self-impl.XXXXXX")"
export CASE_EMBED_CACHE_DIR
trap 'rm -rf "$CASE_EMBED_CACHE_DIR"' EXIT

tab=$'\t'
violations=0
infra=0
for file in "${files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "check-self-impl.sh: file not found: $file" >&2
    exit 2
  fi
  name="${rel:-$file}"
  abs="$(cd "$(dirname "$file")" && pwd)/${file##*/}"
  rc=0
  out="$(tsi_report "$abs" "$name")" || rc=$?
  case "$rc" in
    0)
      while IFS="$tab" read -r line kind detail; do
        [[ -n "$line" ]] || continue
        echo "HIGH: $name line $line: self-implemented harness ($kind ${detail%$'\r'}) code=SELF_IMPLEMENTED_HARNESS"
        violations=1
      done <<<"$out" ;;
    3) echo "WARN: $name: harness self-implementation not checked (no caseEmbedRules) code=SELF_IMPL_CHECK_UNSUPPORTED" ;;
    69)
      runtime="its runtime"
      if tlr_match "$name" && _tlr_get "$TLR_ID" launch.requires; then runtime="$_TLR_V"; fi
      echo "WARN: $name: harness self-implementation not checked ($runtime is not installed) code=SELF_IMPL_CHECK_RUNTIME_UNAVAILABLE" ;;
    *)
      echo "check-self-impl.sh: self-impl op failed (rc=$rc): $name" >&2
      infra=1 ;;
  esac
done

[[ "$violations" -eq 1 ]] && exit 1
[[ "$infra" -eq 1 ]] && exit 2
exit 0
