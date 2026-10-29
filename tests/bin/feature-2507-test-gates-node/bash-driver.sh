#!/usr/bin/env bash
# Tests: hooks/lib/test-gates/case-records.js
# Tags: TL1, bin, parity, test-lang-exception:symmetry, scope:issue-specific
# The bash side of the #2507 D7 parity checks: one process answers a list of requests, so the
# registry loads once. Usage: bash-driver.sh <request-file>; each line is <op>\t<a>\t<b>, and
# each answer is the op's stdout followed by a line "@@END\t<rc>". Ops: crr <file> <match>,
# tsi <file> <match>, token <root> <token>, embed <op> <file>. The headers and place ops went
# with the bash libraries #2507 retired; headers.js and placement.js are pinned by Node tables.
set -u
DRV_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=../../../bin/lib/test-language-registry.sh
. "$DRV_REPO/bin/lib/test-language-registry.sh" || exit 2
tlr_load || exit 2
. "$DRV_REPO/bin/lib/case-record-reader.sh" || exit 2
. "$DRV_REPO/bin/lib/test-self-impl-window.sh" || exit 2
. "$DRV_REPO/bin/lib/test-route-destination/language.sh" || exit 2
. "$DRV_REPO/bin/lib/test-language-parts/bash-case-embed.sh" || exit 2
_cfg_dir="$DRV_REPO"

drv_answer() {
  local op="$1" a="$2" b="$3" rc=0
  case "$op" in
    crr) crr_read "$a" "$b" || rc=$? ;;
    tsi) tsi_report "$a" "$b" || rc=$? ;;
    token)
      TRD_ROOT="$a"
      _trl_init || rc=$?
      if _trl_token_index "$b"; then printf '%s\n' "${_TRL_ID[$_TRL_HIT]}"; else printf '%s\n' "-"; fi ;;
    embed) bash_case_embed "$a" "$b" || rc=$? ;;
    *) printf 'unknown op %s\n' "$op"; rc=2 ;;
  esac
  printf '@@END\t%s\n' "$rc"
}

while IFS=$'\t' read -r drv_op drv_a drv_b || [[ -n "${drv_op:-}" ]]; do
  [[ -n "$drv_op" ]] || continue
  drv_answer "$drv_op" "${drv_a:-}" "${drv_b:-}"
done < "${1:?request file required}"
