#!/usr/bin/env bash
# bin/verify-case-embed/run-compare.sh <relpath> <after> <before> <backup-dir> — check 2 of
# bin/verify-case-embed.sh: run the before and the after file at <relpath> (cwd = repo root)
# and print one CHECK2 line comparing result class and pass/fail counts.
# The original waits in <backup-dir> while another file stands at <relpath>; a SIGKILL leaves
# it there on purpose (the caller's restore-needed signal). A trap restores it otherwise.
set -euo pipefail

RC_REL="$1" RC_AFTER="$2" RC_BEFORE="$3" RC_BK="$4"
RC_ROOT="$PWD"
RC_BK_FILE="$RC_BK/${RC_REL##*/}"
RC_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vce-compare.XXXXXX")"

rc_restore() {
  if [[ -f "$RC_BK_FILE" && ! -L "$RC_BK_FILE" ]]; then cp "$RC_BK_FILE" "$RC_REL" && rm -f "$RC_BK_FILE"; fi
  rm -rf "$RC_TMP"
}
trap rc_restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# shellcheck source=../lib/run-all-launch.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/run-all-launch.sh"

rc_out() { printf 'CHECK2\t%s\t%s\n' "$1" "$2"; exit 0; }

# rc_place <file> — put <file> at the relpath, backing the original up once.
rc_place() {
  if [[ -L "${RC_BK%/}" || -L "$RC_BK_FILE" ]]; then rc_out FAIL "inconclusive: backup path is a symlink"; fi
  [[ -f "$RC_BK_FILE" ]] || cp "$RC_REL" "$RC_BK_FILE"
  cp "$1" "$RC_REL"
}

# rc_run <side> — run the relpath; sets RC_CLASS / RC_PASS / RC_FAIL for that side.
rc_run() {
  local side="$1" rc=0 sum
  run_all_exec "$RC_ROOT/$RC_REL" "$RC_TMP/$side.out" "$RC_TMP/$side.err" || rc=$?
  if [[ "$RUN_ALL_EXEC_LAUNCHED" != 1 ]]; then rc_out FAIL "inconclusive: $side not launched (rc=$rc)"; fi
  if [[ "$rc" -eq 124 || "$rc" -eq 142 ]]; then rc_out FAIL "inconclusive: $side timed out"; fi
  RC_PASS="" RC_FAIL=""
  tlr_match "$RC_REL" || true
  if _tlr_get "$TLR_ID" caseEmbedRules.file && sum="$(tlr_call_part "$TLR_ID" caseEmbedRules result-summary "$rc" "$RC_TMP/$side.out")"; then
    IFS=$'\t' read -r RC_CLASS RC_PASS RC_FAIL <<<"$sum"
  else
    case "$rc" in 0) RC_CLASS=pass ;; 77) RC_CLASS=skip ;; *) RC_CLASS=fail ;; esac
  fi
}

if cmp -s "$RC_BEFORE" "$RC_REL"; then :; else rc_place "$RC_BEFORE"; fi
rc_run before
B_CLASS="$RC_CLASS" B_PASS="$RC_PASS" B_FAIL="$RC_FAIL"
rc_place "$RC_AFTER"
rc_run after

if [[ "$B_CLASS" != "$RC_CLASS" ]]; then rc_out FAIL "class $B_CLASS -> $RC_CLASS"; fi
if [[ -n "$B_PASS" && -n "$B_FAIL" && -n "$RC_PASS" && -n "$RC_FAIL" ]]; then
  if [[ "$B_PASS/$B_FAIL" != "$RC_PASS/$RC_FAIL" ]]; then
    rc_out FAIL "counts $B_PASS/$B_FAIL -> $RC_PASS/$RC_FAIL (passed/failed)"
  fi
  rc_out PASS "class $RC_CLASS, counts $RC_PASS/$RC_FAIL"
fi
rc_out PASS "class $RC_CLASS, count-unavailable"
