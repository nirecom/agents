# shellcheck shell=bash
# bin/lib/test-embed-cases/stage-plan.sh — stage 1 of --embed-cases. Source only.
# tec_stage_plan <band-size> <order> prints SKIP / BAND lines and, unless DRY_RUN=1, writes
# the workdir (worklist.tsv + items/<idx>/{input,output,backup}) and the EMBED-GATE-STE4 block.
# Every candidate is judged, so each skipped file gets its SKIP line even past the band.

TEC_BAND_RELS=() TEC_BAND_IDS=()

tec_stage_plan() {
  local band="$1" order="$2" total i rel n=0
  tec_candidates
  total="$(tec_total_tests)"
  tec_retry_load
  "tec_order_$order" "$total"
  TEC_BAND_RELS=() TEC_BAND_IDS=()
  for i in "${!TEC_ORDER_RELS[@]}"; do
    rel="${TEC_ORDER_RELS[$i]}"
    tec_skip_reason "$rel"
    if [[ -n "$TEC_SKIP" ]]; then
      printf 'SKIP\t%s\t%s\n' "$rel" "$TEC_SKIP"
      continue
    fi
    [[ "$n" -lt "$band" ]] || continue
    n=$((n + 1))
    TEC_BAND_RELS+=("$rel")
    TEC_BAND_IDS+=("$TEC_LANG_ID")
    printf 'BAND\t%s\t%s\t%s\n' "$n" "$rel" "${TEC_ORDER_METRICS[$i]}"
  done
  [[ "${DRY_RUN:-0}" != 1 ]] || return 0
  if [[ "$n" -eq 0 ]]; then
    printf 'NOTE: no file to embed in this band; no workdir written\n'
    return 0
  fi
  tec_write_workdir
}

# tec_write_workdir — materialises the band under <plans>/sweep-tests-embed/<UTC stamp>-<n>/.
tec_write_workdir() {
  local root wd i idx rel base item hs hash doc applied
  root="$(tec_plans_root)" || { tec_die "cannot resolve the plans dir"; return 2; }
  mkdir -p "$root"
  wd="$root/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  i=0
  while ! mkdir "$wd.$i" 2>/dev/null; do
    i=$((i + 1))
    [[ "$i" -lt 100 ]] || { tec_die "cannot create a workdir under $root"; return 2; }
  done
  wd="$wd.$i"
  : >"$wd/worklist.tsv"
  for i in "${!TEC_BAND_RELS[@]}"; do
    idx=$((i + 1))
    rel="${TEC_BAND_RELS[$i]}"
    base="${rel##*/}"
    item="$wd/items/$idx"
    mkdir -p "$item/input" "$item/output" "$item/backup"
    cp -p "$rel" "$item/input/$base"
    applied="$(_fix_headers_apply "$rel" "$item/input/$base")"
    hs=clean
    [[ "$applied" != APPLIED:* ]] || hs=applied
    tec_part "${TEC_BAND_IDS[$i]}" rules-doc || { tec_die "rules-doc failed for $rel"; return 2; }
    doc="${TEC_PART_OUT%%$'\n'*}"
    hash="$(git hash-object -- "$rel")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$rel" "items/$idx/input/$base" \
      "items/$idx/output/" "$doc" "$hs" "$hash" pending 0 >>"$wd/worklist.tsv"
  done
  printf 'EMBED_WORKDIR: %s\n' "$wd"
  printf '<<<EMBED-GATE-STE4\n'
  while IFS=$'\t' read -r idx rel base item doc _ _ _ _; do
    printf 'ITEM\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$wd/$base" "$wd/$item" "$doc" "$wd/items/$idx/report.txt"
  done <"$wd/worklist.tsv"
  printf '>>>\n'
}
