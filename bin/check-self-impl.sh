#!/usr/bin/env bash
# Report a test that builds its own harness (a hand-made pass/fail counter, or a redefinition of
# a helper-library name) through the caseEmbedRules self-impl op, for every registered language.
# Usage: check-self-impl.sh [--rel <rel>] [--head <head-copy>] <file>... | --manifest <manifest>
# --rel: the original path of one temp copy; it names the file in the output and picks the registry
# entry. --head: a copy of its HEAD version: a detection beyond HEAD's count of its (kind, detail)
# key is reported; an identical copy is not checked; a HEAD copy the op cannot analyse reports every detection.
# --manifest: lines "<rel>\t<copy>\t<head-copy or empty>", each judged as --rel/--head would be.
# Prints HIGH: ... code=SELF_IMPLEMENTED_HARNESS per detection and WARN: ... code=SELF_IMPL_CHECK_
# UNSUPPORTED | SELF_IMPL_CHECK_RUNTIME_UNAVAILABLE per unchecked file. Exit 0: no HIGH. Exit 1: HIGH.
# Exit 2: usage, a missing file, library/registry unavailable, an op failure. Codes: case-marker-gate.md.
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
  echo "Usage: check-self-impl.sh [--rel <rel>] [--head <head-copy>] <file>... | --manifest <manifest>" >&2
  [[ -z "${1:-}" ]] || echo "check-self-impl.sh: $1" >&2
  exit 2
}

rel=""
head=""
manifest=""
files=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --rel) [[ "$#" -ge 2 && -n "$2" ]] || _csi_usage "--rel needs a value"; rel="$2"; shift 2 ;;
    --head) [[ "$#" -ge 2 && -n "$2" ]] || _csi_usage "--head needs a value"; head="$2"; shift 2 ;;
    --manifest) [[ "$#" -ge 2 && -n "$2" ]] || _csi_usage "--manifest needs a value"; manifest="$2"; shift 2 ;;
    --) shift; files+=("$@"); break ;;
    -*) _csi_usage "unknown option: $1" ;;
    *) files+=("$1"); shift ;;
  esac
done
if [[ -n "$manifest" ]]; then
  [[ -z "$rel" && -z "$head" && "${#files[@]}" -eq 0 ]] || _csi_usage "--manifest takes no --rel, --head or file"
  if [[ ! -f "$manifest" ]]; then
    echo "check-self-impl.sh: file not found: $manifest" >&2
    exit 2
  fi
else
  [[ "${#files[@]}" -gt 0 ]] || _csi_usage
  if [[ -n "$rel" && "${#files[@]}" -ne 1 ]]; then _csi_usage "--rel takes exactly one file"; fi
  if [[ -n "$head" && "${#files[@]}" -ne 1 ]]; then _csi_usage "--head takes exactly one file"; fi
fi

CASE_EMBED_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/check-self-impl.XXXXXX")"
export CASE_EMBED_CACHE_DIR
trap 'rm -rf "$CASE_EMBED_CACHE_DIR"' EXIT

tab=$'\t'
# _csi_head_keys <name> — sets head_keys to "<kind>\t<detail>" of each HEAD-version detection, one
# per line; empty when the HEAD copy cannot be analysed, so every working detection is reported.
head_keys=""
_csi_head_keys() {
  local head_abs head_out _line kind detail
  head_abs="$(cd "$(dirname "$head")" && pwd)/${head##*/}"
  head_out="$(tsi_report "$head_abs" "$1")" || head_out=""
  while IFS="$tab" read -r _line kind detail; do
    [[ -n "$_line" ]] || continue
    head_keys+="${kind}${tab}${detail%$'\r'}"$'\n'
  done <<<"$head_out"
}

violations=0
infra=0
# _csi_check <file> — judges one copy against the current rel and head; exits 2 on a missing file.
_csi_check() {
  local file="$1" name abs rc=0 out line kind detail key keys runtime
  if [[ ! -f "$file" ]]; then
    echo "check-self-impl.sh: file not found: $file" >&2
    exit 2
  fi
  # A copy identical to HEAD has nothing HEAD lacks, so there is nothing to check or report.
  [[ -n "$head" ]] && cmp -s "$head" "$file" && return 0
  name="${rel:-$file}"
  abs="$(cd "$(dirname "$file")" && pwd)/${file##*/}"
  out="$(tsi_report "$abs" "$name")" || rc=$?
  case "$rc" in
    0)
      # HEAD is analysed only when there is a detection to subtract from.
      [[ -n "$head" && -n "$out" ]] && _csi_head_keys "$name"
      while IFS="$tab" read -r line kind detail; do
        [[ -n "$line" ]] || continue
        detail="${detail%$'\r'}"
        key="${kind}${tab}${detail}"
        if [[ $'\n'"$head_keys" == *$'\n'"$key"$'\n'* ]]; then
          # Consume one HEAD occurrence, so a detection beyond HEAD's count of its key is reported.
          keys=$'\n'"$head_keys"
          keys="${keys/$'\n'"$key"$'\n'/$'\n'}"
          head_keys="${keys#$'\n'}"
          continue
        fi
        echo "HIGH: $name line $line: self-implemented harness ($kind $detail) code=SELF_IMPLEMENTED_HARNESS"
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
  return 0
}

if [[ -n "$manifest" ]]; then
  # fd 3, so an op's runtime cannot consume the manifest from stdin.
  while IFS="$tab" read -r -u 3 rel copy head || [[ -n "$rel" ]]; do
    [[ -n "$rel" ]] || continue
    [[ -n "${copy:-}" ]] || _csi_usage "malformed manifest line: $rel"
    head_keys=""
    if [[ -n "$head" && ! -f "$head" ]]; then
      echo "check-self-impl.sh: file not found: $head" >&2
      exit 2
    fi
    _csi_check "$copy"
  done 3<"$manifest"
else
  if [[ -n "$head" && ! -f "$head" ]]; then
    echo "check-self-impl.sh: file not found: $head" >&2
    exit 2
  fi
  for file in "${files[@]}"; do _csi_check "$file"; done
fi

[[ "$violations" -eq 1 ]] && exit 1
[[ "$infra" -eq 1 ]] && exit 2
exit 0
