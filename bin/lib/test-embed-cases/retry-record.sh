# shellcheck shell=bash
# bin/lib/test-embed-cases/retry-record.sh — embed-retry.tsv, the record of files that reached
# the 2-try cap. Source only. Row: <orig_hash>\t<relpath>\t<attempts>\t<reason>. A row matches
# on hash AND relpath, so a content change invalidates it and identical boilerplate under
# another name is not capped with it. The file is shared by every repo, so a recorded reason
# ends in " (repo <toplevel>)" and then matches that repo only; a row without it matches any.
# No associative arrays (bash 3.2): the loaded keys are one LF-delimited string.

tec_retry_file() { printf '%s/embed-retry.tsv\n' "${SWEEP_TESTS_STATE_DIR:-$HOME/.claude/sweep-tests}"; }

# tec_retry_load — sets TEC_RETRY_KEYS to "<hash>\t<relpath>\t<repo or empty>" per capped row.
tec_retry_load() {
  local f h rel att reason repo
  TEC_RETRY_KEYS=""
  f="$(tec_retry_file)"
  [[ -f "$f" ]] || return 0
  while IFS=$'\t' read -r h rel att reason || [[ -n "$h" ]]; do
    [[ -n "$h" && -n "$rel" && "$att" =~ ^[0-9]+$ && "$att" -ge 2 ]] || continue
    repo=""
    if [[ "$reason" == *" (repo "*")" ]]; then
      repo="${reason##* (repo }"
      repo="${repo%)}"
    fi
    TEC_RETRY_KEYS="${TEC_RETRY_KEYS}"$'\n'"$h"$'\t'"$rel"$'\t'"$repo"
  done <"$f"
  [[ -z "$TEC_RETRY_KEYS" ]] || TEC_RETRY_KEYS="${TEC_RETRY_KEYS}"$'\n'
  return 0
}

# tec_retry_capped <hash> <relpath> — rc 0 when a capped row carries both and fits this repo ($PWD).
tec_retry_capped() {
  case "$TEC_RETRY_KEYS" in
    *$'\n'"$1"$'\t'"$2"$'\t\n'* | *$'\n'"$1"$'\t'"$2"$'\t'"$PWD"$'\n'*) return 0 ;;
  esac
  return 1
}

# tec_retry_record <hash> <relpath> <attempts> <reason> — appends one row scoped to $PWD.
tec_retry_record() {
  local f reason="${4:-unknown}"
  f="$(tec_retry_file)"
  reason="${reason//$'\t'/ }"
  reason="${reason//$'\n'/ } (repo $PWD)"
  mkdir -p "${f%/*}"
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$reason" >>"$f"
}
