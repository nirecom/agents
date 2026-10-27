#!/usr/bin/env bash
# Report a test that builds its own harness (a hand-made pass/fail counter, or a redefinition of
# a helper-library name) through the caseEmbedRules self-impl op, for every registered language.
# Usage: check-self-impl.sh [--rel <rel>] [--head <copy> [--head <copy> [--base <copy>]]] <file>... | --manifest <m>
# --rel: the original path of one temp copy; it names the file in the output and picks the registry
# entry. --head: a parent version: a detection beyond its count of the (kind, detail) key is reported;
# a copy identical to any head is not checked. Two heads (a merge, #2812) count head1 + head2 - base
# per key; a baseline the op cannot analyse falls back to head1 alone, an unanalysable head1 to none.
# --manifest: lines "<rel>\t<copy>[\t<head1>[\t<head2>[\t<base>]]]", each judged as the flags would be.
# Prints HIGH ... code=SELF_IMPLEMENTED_HARNESS / WARN ... code=SELF_IMPL_CHECK_*. Exit 0: no HIGH,
# 1: HIGH, 2: usage, a missing file, library/registry unavailable, an op failure (case-marker-gate.md).
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
  echo "Usage: check-self-impl.sh [--rel <rel>] [--head <copy> [--head <copy> [--base <copy>]]] <file>... | --manifest <manifest>" >&2
  [[ -z "${1:-}" ]] || echo "check-self-impl.sh: $1" >&2
  exit 2
}

rel=""
head=""
head2=""
base=""
manifest=""
files=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --rel) [[ "$#" -ge 2 && -n "$2" ]] || _csi_usage "--rel needs a value"; rel="$2"; shift 2 ;;
    --head)
      [[ "$#" -ge 2 && -n "$2" ]] || _csi_usage "--head needs a value"
      if [[ -z "$head" ]]; then head="$2"; elif [[ -z "$head2" ]]; then head2="$2"; else _csi_usage "--head takes at most two copies"; fi
      shift 2 ;;
    --base) [[ "$#" -ge 2 && -n "$2" ]] || _csi_usage "--base needs a value"; base="$2"; shift 2 ;;
    --manifest) [[ "$#" -ge 2 && -n "$2" ]] || _csi_usage "--manifest needs a value"; manifest="$2"; shift 2 ;;
    --) shift; files+=("$@"); break ;;
    -*) _csi_usage "unknown option: $1" ;;
    *) files+=("$1"); shift ;;
  esac
done
if [[ -n "$manifest" ]]; then
  [[ -z "$rel" && -z "$head" && "${#files[@]}" -eq 0 ]] || _csi_usage "--manifest takes no --rel, --head or file"
  [[ -z "$base" ]] || _csi_usage "--manifest takes no --base"
  if [[ ! -f "$manifest" ]]; then
    echo "check-self-impl.sh: file not found: $manifest" >&2
    exit 2
  fi
else
  [[ "${#files[@]}" -gt 0 ]] || _csi_usage
  if [[ -n "$base" && -z "$head2" ]]; then _csi_usage "--base needs two --head copies"; fi
  if [[ -n "$rel" && "${#files[@]}" -ne 1 ]]; then _csi_usage "--rel takes exactly one file"; fi
  if [[ -n "$head" && "${#files[@]}" -ne 1 ]]; then _csi_usage "--head takes exactly one file"; fi
fi

CASE_EMBED_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/check-self-impl.XXXXXX")"
export CASE_EMBED_CACHE_DIR
trap 'rm -rf "$CASE_EMBED_CACHE_DIR"' EXIT

tab=$'\t'
# _csi_keys <copy> <name> — sets _csi_k to "<kind>\t<detail>" of each detection in <copy>, one per
# line; rc 1 when the op cannot analyse it.
_csi_k=""
_csi_keys() {
  local abs out _line kind detail
  _csi_k=""
  abs="$(cd "$(dirname "$1")" && pwd)/${1##*/}"
  out="$(tsi_report "$abs" "$2")" || return 1
  while IFS="$tab" read -r _line kind detail; do
    [[ -n "$_line" ]] || continue
    _csi_k+="${kind}${tab}${detail%$'\r'}"$'\n'
  done <<<"$out"
  return 0
}

# _csi_consume <key> — removes one occurrence of <key> from head_keys; rc 1 when it holds none.
_csi_consume() {
  local keys
  [[ $'\n'"$head_keys" == *$'\n'"$1"$'\n'* ]] || return 1
  keys=$'\n'"$head_keys"
  keys="${keys/$'\n'"$1"$'\n'/$'\n'}"
  head_keys="${keys#$'\n'}"
}

# _csi_head_keys <name> — sets head_keys to the existing detections, one key per line: head1's, or
# with two heads head1's + head2's minus one per base key. Empty when head1 cannot be analysed,
# so every working detection is reported.
head_keys=""
_csi_head_keys() {
  local h1 h2 b="" key
  head_keys=""
  _csi_keys "$head" "$1" || return 0
  h1="$_csi_k"
  head_keys="$h1"
  [[ -n "$head2" ]] || return 0
  _csi_keys "$head2" "$1" || return 0
  h2="$_csi_k"
  if [[ -n "$base" ]]; then
    _csi_keys "$base" "$1" || return 0
    b="$_csi_k"
  fi
  head_keys="$h1$h2"
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    _csi_consume "$key" || true
  done <<<"$b"
  return 0
}

violations=0
infra=0
# _csi_check <file> — judges one copy against the current rel and heads; exits 2 on a missing file.
_csi_check() {
  local file="$1" name abs rc=0 out line kind detail runtime
  if [[ ! -f "$file" ]]; then
    echo "check-self-impl.sh: file not found: $file" >&2
    exit 2
  fi
  # A copy identical to a parent has nothing that parent lacks, so there is nothing to check or report.
  [[ -n "$head" ]] && cmp -s "$head" "$file" && return 0
  [[ -n "$head2" ]] && cmp -s "$head2" "$file" && return 0
  name="${rel:-$file}"
  abs="$(cd "$(dirname "$file")" && pwd)/${file##*/}"
  out="$(tsi_report "$abs" "$name")" || rc=$?
  case "$rc" in
    0)
      # The parents are analysed only when there is a detection to subtract from.
      [[ -n "$head" && -n "$out" ]] && _csi_head_keys "$name"
      while IFS="$tab" read -r line kind detail; do
        [[ -n "$line" ]] || continue
        detail="${detail%$'\r'}"
        # Consume one existing occurrence, so a detection beyond the existing count of its key is reported.
        _csi_consume "${kind}${tab}${detail}" && continue
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

# _csi_need <copy>... — exits 2 when a given baseline copy is missing.
_csi_need() {
  local f
  for f in "$@"; do
    [[ -z "$f" || -f "$f" ]] && continue
    echo "check-self-impl.sh: file not found: $f" >&2
    exit 2
  done
}

if [[ -n "$manifest" ]]; then
  # fd 3, so an op's runtime cannot consume the manifest from stdin.
  while IFS="$tab" read -r -u 3 rel copy head head2 base || [[ -n "$rel" ]]; do
    [[ -n "$rel" ]] || continue
    [[ -n "${copy:-}" ]] || _csi_usage "malformed manifest line: $rel"
    head_keys=""
    _csi_need "$head" "$head2" "$base"
    _csi_check "$copy"
  done 3<"$manifest"
else
  _csi_need "$head" "$head2" "$base"
  for file in "${files[@]}"; do _csi_check "$file"; done
fi

[[ "$violations" -eq 1 ]] && exit 1
[[ "$infra" -eq 1 ]] && exit 2
exit 0
