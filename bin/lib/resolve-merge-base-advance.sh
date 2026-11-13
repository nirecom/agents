#!/usr/bin/env bash
# bin/lib/resolve-merge-base-advance.sh — layer-1 base advance for bin/resolve-merge-base.sh (#2757).
# Sourced library; the caller defines g() (git -C <repo>).
# run_tests runs before a merge of main is committed, so HEAD alone never moves the base: the
# candidates are merge-base(X, M) for X in {HEAD, MERGE_HEAD...} and M in {origin/main, main}.
# rmba_merge_heads           fills RMBA_MERGE_HEADS with the verified MERGE_HEAD shas (at most 8).
# rmba_advance <rec-base>    sets RMBA_BASE to the newest candidate that descends from <rec-base>
#                            and has every candidate as its ancestor; else to <rec-base> (fail-safe).
# shellcheck disable=SC2034  # RMBA_* are this library's outputs, read by the sourcing script.

RMBA_MERGE_HEADS=()
RMBA_BASE=""

rmba_merge_heads() {
  local gitdir mh_file line sha
  RMBA_MERGE_HEADS=()
  gitdir="$(g rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  [[ -n "$gitdir" ]] || return 0
  mh_file="$gitdir/MERGE_HEAD"
  [[ -f "$mh_file" ]] || return 0
  while IFS= read -r line || [[ -n "${line:-}" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || continue
    [[ "${#RMBA_MERGE_HEADS[@]}" -ge 8 ]] && break
    sha="$(g rev-parse --verify --quiet "${line}^{commit}" 2>/dev/null)" || continue
    [[ "$sha" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || continue
    RMBA_MERGE_HEADS+=("$sha")
  done <"$mh_file"
  return 0
}

rmba_advance() {
  local rec="$1" x m mb c top="" cands=() desc=()
  RMBA_BASE="$rec"
  rmba_merge_heads
  for x in HEAD ${RMBA_MERGE_HEADS[@]+"${RMBA_MERGE_HEADS[@]}"}; do
    for m in origin/main main; do
      mb="$(g merge-base "$x" "$m" 2>/dev/null)" || continue
      [[ "$mb" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] && cands+=("$mb")
    done
  done
  for c in ${cands[@]+"${cands[@]}"}; do
    [[ "$c" == "$rec" ]] && continue
    g merge-base --is-ancestor "$rec" "$c" >/dev/null 2>&1 && desc+=("$c")
  done
  for c in ${desc[@]+"${desc[@]}"}; do
    top="$c"
    for x in "${cands[@]}"; do
      g merge-base --is-ancestor "$x" "$c" >/dev/null 2>&1 || { top=""; break; }
    done
    [[ -n "$top" ]] && break
  done
  [[ -n "$top" ]] && RMBA_BASE="$top"
  return 0
}
