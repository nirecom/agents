# shellcheck shell=bash
# bin/lib/test-embed-cases/order.sh — band order over TEC_CANDIDATES. Source only.
# tec_order_frequency <total> / tec_order_priority fill TEC_ORDER_RELS and TEC_ORDER_METRICS
# (parallel arrays). Caller: PWD = repo root, TEC_TMP set, tec_candidates already run.

_tec_order_read() {
  local rest rel metric
  TEC_ORDER_RELS=() TEC_ORDER_METRICS=()
  while IFS=$'\t' read -r _ rest rel metric; do
    [[ -n "$rel" ]] || continue
    TEC_ORDER_RELS+=("$rel")
    TEC_ORDER_METRICS+=("$metric")
  done <"$1"
}

# frequency: run-all ledger count desc, then git churn desc, then path asc. Churn = commits
# (last 1000, merges excluded) touching a source path whose select-tests stem occurs in the
# test's basename, so the order follows how often the code a test covers changes.
tec_order_frequency() {
  local total="$1" rel p
  local counts="$TEC_TMP/counts.tsv" log="$TEC_TMP/log.txt" stems="$TEC_TMP/stems.tsv"
  local cands="$TEC_TMP/cands.tsv" paths="$TEC_TMP/paths.txt" sorted="$TEC_TMP/order.tsv"
  run_all_dur_counts "$total" "$counts" || : >"$counts"
  git log --no-merges --name-only --format='%x01' -n 1000 >"$log" 2>/dev/null || : >"$log"
  awk 'NF && $0 != "\001" && !seen[$0]++' "$log" >"$paths"
  : >"$stems"
  while IFS= read -r p || [[ -n "$p" ]]; do
    sts_stems_of_path "$p"
    for rel in ${STS_STEMS[@]+"${STS_STEMS[@]}"}; do printf '%s\t%s\n' "$p" "$rel" >>"$stems"; done
  done <"$paths"
  : >"$cands"
  for rel in ${TEC_CANDIDATES[@]+"${TEC_CANDIDATES[@]}"}; do
    run_all_dur_key_into "$PWD/$rel" "$PWD" || RUN_ALL_DUR_KEY_OUT="$rel"
    printf '%s\t%s\n' "$rel" "$RUN_ALL_DUR_KEY_OUT" >>"$cands"
  done
  awk -F'\t' -v OFS='\t' '
    FILENAME == ARGV[1] { cnt[$1] = $2; next }
    FILENAME == ARGV[2] { nc++; rel[nc] = $1; key[nc] = $2; b = $1; sub(/.*\//, "", b); base[nc] = b; next }
    FILENAME == ARGV[3] { ns[$1]++; st[$1, ns[$1]] = $2; next }
    function flush(   c) { for (c in hit) churn[c]++; split("", hit) }
    $0 == "\001" { flush(); next }
    NF == 0 { next }
    {
      for (i = 1; i <= ns[$0]; i++) {
        s = st[$0, i]
        for (c = 1; c <= nc; c++) if (index(base[c], s) > 0) hit[c] = 1
      }
    }
    END {
      flush()
      for (c = 1; c <= nc; c++) {
        n = (key[c] in cnt) ? cnt[key[c]] + 0 : 0
        print n, churn[c] + 0, rel[c], "runs=" n ",churn=" (churn[c] + 0)
      }
    }
  ' "$counts" "$cands" "$stems" "$log" | LC_ALL=C sort -t$'\t' -k1,1nr -k2,2nr -k3,3 >"$sorted"
  _tec_order_read "$sorted"
}

# priority: 1 = a header token names a deleted path, 2 = a single-token header, 3 = the rest;
# path asc breaks ties.
tec_order_priority() {
  local rel pr out="$TEC_TMP/prio.tsv"
  : >"$out"
  for rel in ${TEC_CANDIDATES[@]+"${TEC_CANDIDATES[@]}"}; do
    classify_tests_header "$rel"
    if [[ "${CHR_HAS_C:-0}" -eq 1 ]]; then
      pr=1
    elif [[ "${TFM_PRESENT:-0}" -eq 1 && "${#TFM_TOKENS[@]}" -eq 1 ]]; then
      pr=2
    else
      pr=3
    fi
    printf '%s\t-\t%s\tpriority=%s\n' "$pr" "$rel" "$pr" >>"$out"
  done
  LC_ALL=C sort -t$'\t' -k1,1n -k3,3 "$out" >"$out.sorted"
  _tec_order_read "$out.sorted"
}
