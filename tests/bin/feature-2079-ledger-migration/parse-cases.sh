# shellcheck shell=bash
# tests/bin/feature-2079-ledger-migration/parse-cases.sh
# Tests: bin/lib/run-all-durations-consolidate.sh
# Tags: tests, bin, ledger, durations, consolidate, parser, table-driven, scope:issue-specific, TL2
# TL3 gap (what this test does NOT catch): owned by the dispatcher header, tests/bin/feature-2079-ledger-migration.sh.
# n22 (#2079 S6/S7b) table-driven parsing through the public entries (run_all_dur_consolidate
# and run_all_dur_lookup): segment-name states, record lines, and the `#os` / `#run` headers.
# Tables use `;` as the column separator because record lines themselves contain `|`.

[ "${DC_LIB_LOADED:-0}" = "1" ] || . "${BASH_SOURCE[0]%/*}/_lib-consolidate.sh"

cp_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# cp_rows <table-file> — each `;`-separated row as trimmed, tab-joined columns; `#` and blank
# lines skipped.
cp_rows() {
  local line f out
  local -a cols
  while IFS= read -r line; do
    case "$(cp_trim "$line")" in ''|'#'*) continue ;; esac
    out=""
    IFS=';' read -r -a cols <<< "$line"
    for f in "${cols[@]}"; do out="$out$(cp_trim "$f")"$'\t'; done
    printf '%s\n' "${out%$'\t'}"
  done < "$1"
}

# ---- child side ---------------------------------------------------------------

# cp_seg_path <tail> — `dur.*` tails are whole names (`TOK` = this host's token).
cp_seg_path() {
  case "$1" in
    dur.*) printf '%s/%s' "$(lm_dur_dir)" "${1//TOK/$(lm_tok)}" ;;
    *) printf '%s/%s' "$(lm_dur_dir)" "$(dc_name "$1")" ;;
  esac
}

# cp_in_base <path-to-skip> <fixed-line> — 0 when a base other than <path> holds the line.
cp_in_base() {
  local b f
  for b in $(dc_bases); do
    f="$(lm_dur_dir)/${b/.T./.$(lm_tok).}"
    [ "$f" = "$1" ] && continue
    grep -Fxq -- "$2" "$f" && return 0
  done
  return 1
}

# Each name row on an emptied ledger, beside a closed companion that forces a round:
# consumed = the file is gone and its record sits in a base; kept = byte-identical, not folded.
cp_names() {
  local name tail age want p sum rec got
  while IFS=$'\t' read -r name tail age want; do
    rm -rf "$(lm_dur_dir)"
    dc_plant "${DC_D}T090000-50.closed" 30 "#os $DC_L" 9:comp.sh
    p="$(cp_seg_path "$tail")"
    printf '#os %s\n%s|5|row.sh\n' "$DC_L" "$(lm_rid)" > "$p"; lm_age "$p" "$age"
    sum="$(lm_sum "$p")"; rec="$(lm_rid)|5|row.sh"
    dc_cons
    if ! cp_in_base - "$(lm_rid)|9|comp.sh"; then got="no-round"
    elif [ ! -e "$p" ] && cp_in_base "$p" "$rec"; then got=consumed
    elif [ "$(lm_sum "$p")" = "$sum" ] && ! cp_in_base "$p" "$rec"; then got=kept
    else got="odd:$([ -e "$p" ] && echo exists || echo gone)"; fi
    say "row.$name" "$got/$(lm_get row.sh)"
  done < <(cp_rows "$LM_XVAR")
}

# All record rows in one closed segment, in table order; the reader is asked before and after.
cp_lines() {
  local name line rkey want rid long items=() p
  rid="$(lm_rid)"; long="$(printf 'k%.0s' $(seq 1 600))"
  while IFS=$'\t' read -r name line rkey want; do
    line="${line//LONG/$long}"
    case "$line" in '#'*) items+=("$line") ;; *) items+=("=$line") ;; esac
  done < <(cp_rows "$LM_XVAR")
  dc_plant "${DC_D}T010000-11.closed" 30 "#os $DC_L" "${items[@]}"
  while IFS=$'\t' read -r name line rkey want; do
    [ "$rkey" = "-" ] || say "before.$name" "$(lm_get "$rkey")"
  done < <(cp_rows "$LM_XVAR")
  dc_cons
  while IFS=$'\t' read -r name line rkey want; do
    line="${line//LONG/$long}"; line="${line//RID/$rid}"
    if cp_in_base - "$line"; then p=in; else p=out; fi
    [ "$rkey" = "-" ] || p="$p/$(lm_get "$rkey")"
    say "row.$name" "$p"
  done < <(cp_rows "$LM_XVAR")
  say nrec "$(dc_body | tr ';' '\n' | grep -vc '^#')"
}

# Each header row: `<first>` and `<run>` lines (`-` = none) above one record, then the
# base's attribute and the provenance its `#run` line carries.
cp_headers() {
  local name first run want items
  while IFS=$'\t' read -r name first run want; do
    rm -rf "$(lm_dur_dir)"; items=()
    [ "$first" = "-" ] || items+=("$first")
    [ "$run" = "-" ] || items+=("$run")
    dc_plant "${DC_D}T010000-11.closed" 30 "${items[@]}" 1:p.sh
    dc_cons
    say "row.$name" "$(dc_heads)|$(dc_body | tr ';' '\n' | sed -n 's/^#run //p' | tr '\n' ' ' | sed 's/ $//')|$(lm_get p.sh)"
  done < <(cp_rows "$LM_XVAR")
}

# ---- parent side --------------------------------------------------------------

# cp_check <label> <table-file> <child-fn> — one assertion per named row against its 4th
# (want) column; the child's whole output is left in CP_LAST.
cp_check() {
  local r name a b want
  r="$(LM_XVAR="$2" lm_run "$(lm_cache)" "$3")"
  while IFS=$'\t' read -r name a b want; do
    ck "$1/$name" "$want" "$(lm_v "$r" "row\\.$name")"
  done < <(cp_rows "$2")
  CP_LAST="$r"
}

run_parse_name_cases() {
  local t="$LM_TMP/names.table"
  dc_lib_ck n22/names
  cat > "$t" <<TABLE
# name                          ; tail                                               ; age ; want
closed-segment                  ; ${DC_D}T010000-11.closed                           ; 30  ; consumed/5
consolidating-leftover          ; ${DC_D}T010000-11.consolidating                    ; 30  ; consumed/5
consolidating-fresh-mtime       ; ${DC_D}T010000-11.consolidating                    ; 0   ; consumed/5
open-abandoned-400min           ; ${DC_D}T010000-11                                  ; 400 ; consumed/5
open-young-30min                ; ${DC_D}T010000-11                                  ; 30  ; kept/5
base-pid-01                     ; ${DC_D}T010000-01                                  ; 30  ; consumed/5
aside-base                      ; ${DC_D}T010000-01.consolidating                    ; 30  ; consumed/5
foreign-token-closed            ; dur.2.0123456789abcdef.${DC_D}T010000-11.closed.log ; 30  ; kept/-
not-dot-log-suffix              ; dur.2.TOK.${DC_D}T010000-11.closed.txt             ; 30  ; kept/-
malformed-stamp-7-digit-date    ; 2026030T010000-11.closed                           ; 30  ; kept/5
malformed-stamp-no-t            ; ${DC_D}X010000-11.closed                           ; 30  ; kept/5
malformed-stamp-letter-in-time  ; ${DC_D}T01a000-11.closed                           ; 30  ; kept/5
malformed-stamp-5-digit-time    ; ${DC_D}T01000-11.closed                            ; 30  ; kept/5
non-numeric-pid                 ; ${DC_D}T010000-abc.closed                          ; 30  ; kept/5
pid-trailing-letter             ; ${DC_D}T010000-12x.closed                          ; 30  ; kept/5
empty-pid                       ; ${DC_D}T010000-.closed                             ; 30  ; kept/5
non-numeric-pid-abandoned-age   ; ${DC_D}T010000-abc                                 ; 400 ; kept/5
unknown-state-suffix            ; ${DC_D}T010000-11.done                             ; 30  ; kept/5
garbage-name                    ; garbage                                            ; 30  ; kept/5
TABLE
  cp_check "n22/names" "$t" cp_names
}

run_parse_line_cases() {
  local t="$LM_TMP/lines.table" name line rkey want r
  dc_lib_ck n22/lines
  cat > "$t" <<'TABLE'
# name                   ; line                         ; reader key     ; want (in-base[/reader after])
well-formed              ; RID|5|ok.sh                  ; ok.sh          ; in/5
secs-zero                ; RID|0|zero.sh                ; zero.sh        ; in/0
secs-four-digits         ; RID|9999|max4.sh             ; max4.sh        ; in/9999
secs-leading-zero        ; RID|007|lz.sh                ; lz.sh          ; in/007
key-with-space           ; RID|3|a b.sh                 ; a b.sh         ; in/3
key-with-path            ; RID|4|tests/bin/x.sh         ; tests/bin/x.sh ; in/4
other-repo-id-kept       ; ffffffffffffffff|3|other.sh  ; other.sh       ; in/-
secs-five-digits         ; RID|12345|five.sh            ; five.sh        ; out/-
secs-non-numeric         ; RID|x|nn.sh                  ; nn.sh          ; out/-
secs-empty               ; RID||es.sh                   ; es.sh          ; out/-
secs-negative            ; RID|-1|neg.sh                ; neg.sh         ; out/-
key-empty                ; RID|3|                       ; -              ; out
extra-field              ; RID|3|a|b                    ; -              ; out
too-few-fields           ; RID|3                        ; -              ; out
repo-id-short            ; abc|3|short.sh               ; short.sh       ; out/-
repo-id-non-alnum        ; ffffffffffffff-f|3|dash.sh   ; dash.sh        ; out/-
line-over-512-bytes      ; RID|5|LONG                   ; -              ; out
garbage-text             ; hello world                  ; -              ; out
os-line-mid-file         ; #os Windows/1.0              ; -              ; out
run-line-malformed       ; #run bogus                   ; -              ; out
TABLE
  cp_check "n22/lines" "$t" cp_lines
  r="$CP_LAST"
  # The reader applies the same record rules before consolidation as after it.
  while IFS=$'\t' read -r name line rkey want; do
    [ "$rkey" = "-" ] && continue
    ck "n22/lines/$name-reader-before" "${want#*/}" "$(lm_v "$r" "before\\.$name")"
  done < <(cp_rows "$t")
  ck "n22/lines/base-holds-exactly-the-in-rows" "7" "$(lm_v "$r" nrec)"
}

run_parse_header_cases() {
  local t="$LM_TMP/headers.table" p="${DC_D}T010000-11"
  dc_lib_ck n22/headers
  cat > "$t" <<TABLE
# name                ; first line              ; run line                 ; want (attr|provenance|reader)
os-valid              ; #os $DC_L               ; -                        ; $DC_L|$p|1
os-missing            ; -                       ; -                        ; Windows/unknown|$p|1
os-no-slash           ; #os Linux               ; -                        ; Windows/unknown|$p|1
os-with-space         ; #os Linux 6/1           ; -                        ; Windows/unknown|$p|1
os-with-pipe          ; #os Lin|ux/6            ; -                        ; Windows/unknown|$p|1
os-empty-version      ; #os Linux/              ; -                        ; Windows/unknown|$p|1
os-bare-tag           ; #os                     ; -                        ; Windows/unknown|$p|1
os-not-first-line     ; #run ${DC_D}T010000-11  ; #os $DC_L                ; Windows/unknown|$p|1
run-valid             ; #os $DC_L               ; #run ${DC_D}T080000-9    ; $DC_L|${DC_D}T080000-9|1
run-older-than-name   ; #os $DC_L               ; #run ${DC_D}T000000-3    ; $DC_L|${DC_D}T000000-3|1
run-garbage           ; #os $DC_L               ; #run bogus               ; $DC_L|$p|1
run-7-digit-date      ; #os $DC_L               ; #run 2026030T080000-9    ; $DC_L|$p|1
run-non-numeric-pid   ; #os $DC_L               ; #run ${DC_D}T080000-x    ; $DC_L|$p|1
run-empty-pid         ; #os $DC_L               ; #run ${DC_D}T080000-     ; $DC_L|$p|1
run-no-space          ; #os $DC_L               ; #run${DC_D}T080000-9     ; $DC_L|$p|1
TABLE
  cp_check "n22/headers" "$t" cp_headers
}
