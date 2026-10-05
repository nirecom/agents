# shellcheck shell=bash
# bin/lib/test-embed-cases/stage-apply.sh — stage 3 of --embed-cases. Source only.
# tec_stage_apply <workdir> validates the workdir fail-closed (exit 2 before any write), puts
# back leftover verifier backups, then gates each pending / reverted item on
# bin/verify-case-embed.sh and one codex call for the band, and replaces passing files.
# Result lines: APPLIED / REVERTED / CAPPED / STALE / TOOL_FAILED (+ MERGED_TARGET, EXEMPT),
# then the EMBED-RETRY-STE4 block. Contract: docs/architecture/claude-code/sweep-tests-embed-cases.md.

W_IDX=() W_REL=() W_IN=() W_OUT=() W_DOC=() W_HS=() W_HASH=() W_STATE=() W_PRE=() W_ATT=()
TEC_WD="" TEC_RWD="" TEC_RETRY_ROWS="" TEC_CODEX_LABEL="EMBED_CASE_BOUNDARY"

# _tec_item_path_ok <idx> <path> — rc 0 when <path> stays inside items/<idx>/ of the workdir.
_tec_item_path_ok() {
  local idx="$1" p="$2"
  case "/$p/" in */../* | */./*) return 1 ;; esac
  case "$p" in
    "items/$idx/"*) return 0 ;;
    "$TEC_WD/items/$idx/"* | "$TEC_RWD/items/$idx/"*) return 0 ;;
  esac
  return 1
}

_tec_abs() { case "$1" in /* | [A-Za-z]:/*) printf '%s' "$1" ;; *) printf '%s/%s' "$TEC_WD" "$1" ;; esac; }

# _tec_out_file <output-column> <relpath> — the stage-2 output file an item is judged on.
_tec_out_file() {
  local out
  out="$(_tec_abs "$1")"
  if [[ -d "$out" || "$out" == */ ]]; then out="${out%/}/${2##*/}"; fi
  printf '%s' "$out"
}

# _tec_phys_in_item <idx> <path> — rc 0 when the existing parent of <path> resolves inside
# the physical items/<idx>/ (a symlinked directory on the way would leave it).
_tec_phys_in_item() {
  local d="${2%/}" rp
  d="${d%/*}"
  [[ -d "$d" ]] || return 0
  rp="$(cd -P "$d" 2>/dev/null && pwd -P)" || return 1
  [[ "$rp" == "$TEC_RWD/items/$1" || "$rp" == "$TEC_RWD/items/$1"/* ]]
}

# _tec_item_dir_ok <idx> <relpath> <in> <out> — rc 0 when items/<idx>/ is a real directory
# of the workdir and no file stage 3 reads or writes there is a symlink.
_tec_item_dir_ok() {
  local idx="$1" item="$TEC_WD/items/$1" p
  [[ -d "$item" && ! -L "$TEC_WD/items" && ! -L "$item" ]] || return 1
  [[ "$(cd -P "$item" 2>/dev/null && pwd -P)" == "$TEC_RWD/items/$idx" ]] || return 1
  for p in "$item/backup" "$item/backup/${2##*/}" "$item/failure.txt" "$item/verify.out" \
    "$item/verify.err" "$item/report.txt" "$(_tec_abs "$3")" "$(_tec_abs "$4")" "$(_tec_out_file "$4" "$2")"; do
    [[ ! -L "${p%/}" ]] || return 1
    _tec_phys_in_item "$idx" "$p" || return 1
  done
}

_tec_is_candidate() {
  local c
  for c in ${TEC_CANDIDATES[@]+"${TEC_CANDIDATES[@]}"}; do [[ "$c" != "$1" ]] || return 0; done
  return 1
}

# tec_apply_load <workdir> — validation; fills the W_* arrays.
tec_apply_load() {
  local wd="${1%/}" root rroot bad idx rel in out doc hs hash st att
  [[ -d "$wd" ]] || { tec_die "workdir not found: $wd"; return 2; }
  root="$(tec_plans_root)" || { tec_die "cannot resolve the plans dir"; return 2; }
  rroot="$(cd -P "$root" 2>/dev/null && pwd -P)" || { tec_die "no embed root at $root"; return 2; }
  TEC_RWD="$(cd -P "$wd" && pwd -P)"
  [[ "$TEC_RWD" == "$rroot"/* ]] || { tec_die "workdir is outside $root: $wd"; return 2; }
  TEC_WD="$wd"
  [[ -f "$wd/worklist.tsv" ]] || { tec_die "worklist.tsv missing in $wd"; return 2; }
  [[ ! -L "$wd/worklist.tsv" && ! -L "$wd/worklist.tsv.tmp" ]] || { tec_die "worklist.tsv is a symlink in $wd"; return 2; }
  bad="$(awk -F'\t' 'NF != 9 { print NR }' "$wd/worklist.tsv")"
  [[ -z "$bad" ]] || { tec_die "worklist.tsv row(s) without 9 columns: ${bad//$'\n'/ }"; return 2; }
  tec_candidates
  while IFS=$'\t' read -r idx rel in out doc hs hash st att; do
    [[ -n "$att" && "$idx" =~ ^[0-9]+$ && "$att" =~ ^[0-9]+$ ]] || { tec_die "malformed worklist row: $idx"; return 2; }
    case "$rel" in /* | [A-Za-z]:/*) tec_die "absolute relpath: $rel"; return 2 ;; esac
    case "/$rel/" in */../*) tec_die "relpath with ..: $rel"; return 2 ;; esac
    _tec_is_candidate "$rel" || { tec_die "relpath is not an embed candidate: $rel"; return 2; }
    _tec_item_path_ok "$idx" "$in" || { tec_die "input outside items/$idx/: $in"; return 2; }
    _tec_item_path_ok "$idx" "$out" || { tec_die "output outside items/$idx/: $out"; return 2; }
    _tec_item_dir_ok "$idx" "$rel" "$in" "$out" || { tec_die "items/$idx/ leaves the workdir or holds a symlink"; return 2; }
    if ! tec_lang_rules "$rel" || ! tec_part "$TEC_LANG_ID" rules-doc; then tec_die "rules-doc unavailable for $rel"; return 2; fi
    # The column is echoed in RETRY rows the subagent follows, so it must be the part's own answer.
    [[ "$doc" == "${TEC_PART_OUT%%$'\n'*}" ]] || { tec_die "rules_doc column of item $idx is not its language's rules-doc"; return 2; }
    W_IDX+=("$idx") W_REL+=("$rel") W_IN+=("$in") W_OUT+=("$out") W_DOC+=("$doc")
    W_HS+=("$hs") W_HASH+=("$hash") W_STATE+=("$st") W_PRE+=("$st") W_ATT+=("$att")
  done <"$wd/worklist.tsv"
  [[ "${#W_IDX[@]}" -gt 0 ]] || { tec_die "worklist.tsv has no item"; return 2; }
}

# A file left in items/<idx>/backup/ means a verifier was killed while another file stood in
# for the original; put the original back before anything is judged. Only a byte-exact
# original (its hash is orig_hash) is put back; anything else stops the run (exit 2).
tec_apply_restore_backups() {
  local i bk
  for i in "${!W_IDX[@]}"; do
    bk="$TEC_WD/items/${W_IDX[$i]}/backup/${W_REL[$i]##*/}"
    [[ -f "$bk" ]] || continue
    if [[ "$(git hash-object --path "${W_REL[$i]}" -- "$bk")" != "${W_HASH[$i]}" ]]; then
      tec_die "leftover backup is not the original of ${W_REL[$i]} (hash differs from orig_hash); not restored: $bk"
      return 2
    fi
    cp "$bk" "${W_REL[$i]}"
    rm -f "$bk"
    printf 'NOTE: restored %s from a leftover verifier backup\n' "${W_REL[$i]}" >&2
  done
  return 0
}

# _tec_ng <i> <reason> <failure-source-file> — one counted try failed.
_tec_ng() {
  local i="$1" reason="$2" idx="${W_IDX[$1]}" rel="${W_REL[$1]}" fail
  fail="$TEC_WD/items/$idx/failure.txt"
  { printf 'reason: %s\n' "$reason"; cat "$3" 2>/dev/null || true; } >"$fail"
  W_ATT[i]=$((W_ATT[i] + 1))
  if [[ "${W_ATT[$i]}" -lt 2 ]]; then
    W_STATE[i]=reverted
    printf 'REVERTED\t%s\t%s\n' "$rel" "$reason"
    TEC_RETRY_ROWS+="$(printf 'RETRY\t%s\t%s\t%s\t%s\t%s\t%s' "$idx" "$(_tec_abs "${W_IN[$i]}")" \
      "$(_tec_abs "${W_OUT[$i]}")" "${W_DOC[$i]}" "$TEC_WD/items/$idx/report.txt" "$fail")"$'\n'
  else
    W_STATE[i]=capped
    printf 'CAPPED\t%s\n' "$rel"
    tec_retry_record "${W_HASH[$i]}" "$rel" "${W_ATT[$i]}" "$reason"
  fi
}

# _tec_replace <i> <output> — atomic replace keeping the original's mode.
_tec_replace() {
  local rel="${W_REL[$1]}" tmp mode
  mode="$(stat -c '%a' "$rel" 2>/dev/null || stat -f '%Lp' "$rel" 2>/dev/null || true)"
  tmp="$(mktemp "${rel%/*}/.tec-apply.XXXXXX")"
  cp "$2" "$tmp"
  [[ -z "$mode" ]] || chmod "$mode" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$rel"
}

# _tec_codex_verdicts <codex-out> <i>... — sets TEC_VERDICTS[i] to OK or "NG <reason>".
# One band-wide prompt lets one AFTER file forge lines for another, so only exactly one line
# per relpath counts, and a line naming a file outside the band makes the whole band NG.
_tec_codex_verdicts() {
  local cout="$1" line in=0 i hit rest unknown=0
  local -a cnt=()
  shift
  TEC_VERDICTS=()
  for i in "$@"; do TEC_VERDICTS[i]="NG codex gave no CASE_BOUNDARY line" cnt[i]=0; done
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    case "$line" in
      '<!-- begin-codex-output'*) in=1; continue ;;
      '<!-- end-codex-output'*) in=0; continue ;;
    esac
    [[ "$in" -eq 1 && "$line" == "CASE_BOUNDARY: "* ]] || continue
    hit=""
    for i in "$@"; do
      if [[ "$line" == "CASE_BOUNDARY: ${W_REL[$i]}: "* ]]; then hit="$i"; break; fi
    done
    if [[ -z "$hit" ]]; then unknown=1; continue; fi
    cnt[hit]=$((cnt[hit] + 1))
    rest="${line#"CASE_BOUNDARY: ${W_REL[$hit]}: "}"
    if [[ "$rest" == OK ]]; then TEC_VERDICTS[hit]=OK; else TEC_VERDICTS[hit]="NG ${rest#NG }"; fi
  done <"$cout"
  for i in "$@"; do
    if [[ "$unknown" -eq 1 ]]; then
      TEC_VERDICTS[i]="NG a CASE_BOUNDARY line names a file outside the band"
    elif [[ "${cnt[$i]}" -gt 1 ]]; then
      TEC_VERDICTS[i]="NG more than one CASE_BOUNDARY line for this file"
    fi
  done
  return 0
}

tec_stage_apply() {
  local i rel out item vrc cur line pass=()
  tec_apply_load "$1"
  tec_apply_restore_backups
  : >"$TEC_TMP/codex-list.tsv"
  for i in "${!W_IDX[@]}"; do
    case "${W_STATE[$i]}" in pending | reverted) ;; *) continue ;; esac
    rel="${W_REL[$i]}" item="$TEC_WD/items/${W_IDX[$i]}"
    cur="$(git hash-object -- "$rel")"
    if [[ "$cur" != "${W_HASH[$i]}" ]]; then W_STATE[i]=stale; continue; fi
    out="$(_tec_out_file "${W_OUT[$i]}" "$rel")"
    if [[ ! -f "$out" ]]; then
      printf 'no stage-2 output at %s\n' "$out" >"$TEC_TMP/nf.txt"
      _tec_ng "$i" no-output "$TEC_TMP/nf.txt"
      continue
    fi
    local -a vargs=("$out" --relpath "$rel" --before "$rel" --backup-dir "$item/backup")
    [[ ! -f "$item/report.txt" ]] || vargs+=(--merged-report "$item/report.txt")
    vrc=0
    bash "$TEC_TOOL/bin/verify-case-embed.sh" "${vargs[@]}" >"$item/verify.out" 2>"$item/verify.err" || vrc=$?
    if [[ "$vrc" -ne 0 ]]; then
      line="$(awk -F'\t' '$2 == "FAIL" { print $1; exit }' "$item/verify.out")"
      cat "$item/verify.err" >>"$item/verify.out"
      _tec_ng "$i" "verify:${line:-error-rc$vrc}" "$item/verify.out"
      continue
    fi
    pass+=("$i")
    printf '%s\t%s\t%s\n' "$rel" "$PWD/$rel" "$out" >>"$TEC_TMP/codex-list.tsv"
  done
  if [[ "${#pass[@]}" -gt 0 ]]; then tec_apply_codex_gate "${pass[@]}"; fi
  tec_apply_report
}

# tec_apply_codex_gate <i>... — one codex call over every verifier-passing item.
tec_apply_codex_gate() {
  local i rel out item crc=0 cout="$TEC_TMP/codex.out" line tok
  bash "$_TEC_DIR/test-embed-cases/codex-band-check.sh" "$TEC_TMP/codex-list.tsv" >"$cout" 2>&1 || crc=$?
  if [[ "$crc" -ne 0 ]] || ! grep -q "^## $TEC_CODEX_LABEL: PERFORMED" "$cout"; then
    printf 'CODEX_UNAVAILABLE\n'
    for i in "$@"; do W_STATE[i]=tool-failed; done
    return 0
  fi
  _tec_codex_verdicts "$cout" "$@"
  for i in "$@"; do
    rel="${W_REL[$i]}" item="$TEC_WD/items/${W_IDX[$i]}"
    if [[ "${TEC_VERDICTS[$i]}" != OK ]]; then
      _tec_ng "$i" "codex:${TEC_VERDICTS[$i]#NG }" "$cout"
      continue
    fi
    out="$(awk -F'\t' -v r="$rel" '$1 == r { print $3; exit }' "$TEC_TMP/codex-list.tsv")"
    _tec_replace "$i" "$out"
    W_STATE[i]=applied
    printf 'APPLIED\t%s\n' "$rel"
    if [[ -f "$item/report.txt" ]]; then
      awk -F'\t' -v OFS='\t' -v r="$rel" '$1 == "MERGED_TARGET" { $1 = r; print "MERGED_TARGET", $0 }' "$item/report.txt"
    fi
    while IFS=$'\t' read -r line tok _; do
      [[ "$line" != EXEMPT ]] || printf 'EXEMPT\t%s\t%s\n' "$rel" "$tok"
    done <"$item/verify.out"
  done
}

# tec_apply_report — re-reports the settled items, rewrites worklist.tsv, prints the retry block.
tec_apply_report() {
  local i wl="$TEC_WD/worklist.tsv"
  for i in "${!W_IDX[@]}"; do
    case "${W_STATE[$i]}" in
      applied) if [[ "${W_PRE[$i]}" == applied ]]; then printf 'APPLIED\t%s\n' "${W_REL[$i]}"; fi ;;
      capped) if [[ "${W_PRE[$i]}" == capped ]]; then printf 'CAPPED\t%s\n' "${W_REL[$i]}"; fi ;;
      stale) printf 'STALE\t%s\n' "${W_REL[$i]}" ;;
      tool-failed) printf 'TOOL_FAILED\t%s\n' "${W_REL[$i]}" ;;
    esac
  done
  rm -f "$wl.tmp"
  : >"$wl.tmp"
  for i in "${!W_IDX[@]}"; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${W_IDX[$i]}" "${W_REL[$i]}" "${W_IN[$i]}" "${W_OUT[$i]}" \
      "${W_DOC[$i]}" "${W_HS[$i]}" "${W_HASH[$i]}" "${W_STATE[$i]}" "${W_ATT[$i]}" >>"$wl.tmp"
  done
  mv -f "$wl.tmp" "$wl"
  if [[ -n "$TEC_RETRY_ROWS" ]]; then
    printf '<<<EMBED-RETRY-STE4\n%s>>>\n' "$TEC_RETRY_ROWS"
  fi
  return 0
}
