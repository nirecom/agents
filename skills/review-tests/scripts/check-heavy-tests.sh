#!/usr/bin/env bash
# skills/review-tests/scripts/check-heavy-tests.sh — RT-1c (#2932). Usage: check-heavy-tests.sh [--root <repo>]
# Maps each staged test file to the top-level file run-all runs (thj_dispatcher_of), judges each
# once against this host's duration ledger (thj_judge) and prints, per WARN or HARD file,
#   HEAVY: <path> tier=<WARN|HARD> basis=<b> samples=<n> median=<s> host=<tok> shrinks=<yes|no>
# A ledger that is missing or unreadable prints `HEAVY-SKIP: reason=<r>` instead. Always exit 0
# but on a usage error (2).
set -uo pipefail
_CHT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../bin/lib" && pwd)"
ROOT="$PWD"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) [ "$#" -ge 2 ] || { echo "check-heavy-tests: --root requires a value" >&2; exit 2; }; ROOT="$2"; shift 2 ;;
    *) echo "check-heavy-tests: unknown option: $1" >&2; exit 2 ;;
  esac
done
# shellcheck source=../../../bin/lib/test-heavy-judge.sh
. "$_CHT_LIB/test-heavy-judge.sh"
# shellcheck source=../../../bin/lib/repo-settings.sh
. "$_CHT_LIB/repo-settings.sh"

TMP="$(mktemp -d)" || exit 0
trap 'rm -rf "$TMP"' EXIT
rsf_categories_into "$ROOT"
: >"$TMP/paths"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  d="$(thj_dispatcher_of "$p" "$ROOT")"
  for t in ${RSF_TEST_DIRS[@]+"${RSF_TEST_DIRS[@]}"}; do
    [ "${d%/*}" = "$t" ] || continue
    grep -qxF -- "$d" "$TMP/paths" || printf '%s\n' "$d" >>"$TMP/paths"
    break
  done
done < <(git -C "$ROOT" diff --cached --name-only --diff-filter=ACMR 2>/dev/null)

thj_judge "$ROOT" "$TMP/paths" "$TMP/out"
IFS= read -r hdr <"$TMP/out" || hdr=""
reason="${hdr#*reason=}"; reason="${reason%% *}"
if [ "$reason" != ok ]; then
  printf 'HEAVY-SKIP: reason=%s\n' "${reason:-unreadable}"
  exit 0
fi
host="${hdr#*host=}"; host="${host%% *}"
# shrinks=yes when the staged change removes more lines than it adds under the dispatcher and its <stem>/ folder (plan A: advisory only).
_cht_shrinks() {
  local d="$1" add del
  read -r add del < <(git -C "$ROOT" diff --cached --numstat -- "$d" "${d%.*}/" 2>/dev/null | awk '{a+=$1; r+=$2} END {print a+0, r+0}')
  if [ "${del:-0}" -gt "${add:-0}" ]; then echo yes; else echo no; fi
}
while IFS=$'\t' read -r p tier basis n med _; do
  case "$tier" in WARN|HARD) printf 'HEAVY: %s tier=%s basis=%s samples=%s median=%s host=%s shrinks=%s\n' "$p" "$tier" "$basis" "$n" "$med" "$host" "$(_cht_shrinks "$p")" ;; esac
done < <(tail -n +2 "$TMP/out")
exit 0
