#!/usr/bin/env bash
# bin/lib/run-all-duration-counts.sh — how many run-all invocations ran each test, from the
# duration ledger owned by bin/lib/run-all-durations.sh (read-only; the writer is unchanged).
# run_all_dur_counts <total-tests> <out-tsv> writes `<key>\t<segments-containing-key>`.
# A segment whose distinct own-repo keys reach half of <total-tests> is taken for a full
# (`--all`) run and excluded — a heuristic, since the ledger carries no run-mode flag.
# The repo id is the memoised one (run_all_dur_repo_id), else the repo of $PWD.

_RADC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/run-all-parallelism.sh
declare -F run_all_cache_dir >/dev/null || . "$_RADC_DIR/run-all-parallelism.sh"
# Guarded: re-sourcing would clear the memoised RUN_ALL_DUR_REPO_ID of the caller.
# shellcheck source=bin/lib/run-all-durations.sh
declare -F run_all_dur_segments_into >/dev/null || . "$_RADC_DIR/run-all-durations.sh"

run_all_dur_counts() {
    local radc_total="${1:-}" radc_out="${2:?run_all_dur_counts: out-tsv required}"
    local LC_ALL=C LC_CTYPE=C
    : >"$radc_out" || return 1
    case "$radc_total" in ''|*[!0-9]*) return 1 ;; esac
    command -v awk >/dev/null 2>&1 || return 0
    run_all_dur_repo_id "$PWD" >/dev/null
    run_all_dur_host_token >/dev/null
    run_all_dur_segments_into "$(run_all_dur_dir)" "$RUN_ALL_DUR_HOST_TOKEN"
    [ "${#RUN_ALL_DUR_SEGMENTS_OUT[@]}" -gt 0 ] || return 0
    awk -v RID="$RUN_ALL_DUR_REPO_ID" -v MAXREC="$RUN_ALL_DUR_MAX_RECORDS" -v TOTAL="$radc_total" '
function close_seg(   k) {
    if (nseg > 0 && nseg * 2 < TOTAL) for (k in seen) cnt[k]++
    split("", seen)
    nseg = 0
}
{
    if (++nline > MAXREC) exit
    if (FILENAME != pf) { close_seg(); pf = FILENAME }
    p1 = index($0, "|")
    if (p1 == 0 || substr($0, 1, p1 - 1) != RID) next
    r = substr($0, p1 + 1)
    p2 = index(r, "|")
    if (p2 == 0) next
    k = substr(r, p2 + 1)
    if (k == "" || index(k, "|") > 0) next
    if (!(k in seen)) { seen[k] = 1; nseg++ }
}
END {
    close_seg()
    for (k in cnt) printf "%s\t%d\n", k, cnt[k]
}
' "${RUN_ALL_DUR_SEGMENTS_OUT[@]}" >"$radc_out" 2>/dev/null || { : >"$radc_out"; return 1; }
    return 0
}
