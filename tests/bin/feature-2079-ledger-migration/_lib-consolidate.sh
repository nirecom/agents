# shellcheck shell=bash
# tests/bin/feature-2079-ledger-migration/_lib-consolidate.sh
# Tests: bin/lib/run-all-durations-consolidate.sh
# Tags: tests, bin, ledger, durations, consolidate, helpers, scope:issue-specific, TL2
# TL3 gap (what this test does NOT catch): owned by the dispatcher header, tests/bin/feature-2079-ledger-migration.sh.
# Helpers for the #2079 S7b consolidation parts, on top of the ledger-migration helpers
# (lm_run, ck, lm_v, lm_plant_dur, lm_get ...). Sourced by every part, parent and child.

DC_LIB_LOADED=1
# Every direct consolidation gets this fixed "now"; planted provenances sit on DC_D, five
# days earlier, so nothing expires unless a case plants an older stamp on purpose.
DC_NOW="20260310T120000"
DC_D="20260305"
DC_A="Darwin/23.1.0"; DC_L="Linux/6.1.0"; DC_W="Windows/10.0.26300"

# ---- parent side --------------------------------------------------------------

# dc_lib_ck <label> — the consolidation entry must be loadable; a missing module fails here,
# loudly, before the case's own checks fail on it.
dc_lib_ck() { ck "$1/consolidate-lib-loaded" "yes" "$(lm_run "$(lm_cache)" dc_have)"; }

# ---- child side ---------------------------------------------------------------

dc_have() { command -v run_all_dur_consolidate >/dev/null 2>&1 && echo yes || echo no; }

# dc_name <stamp-pid[.state]> — this host's segment name for that tail.
dc_name() { printf 'dur.2.%s.%s.log' "$(lm_tok)" "$1"; }

# dc_plant <stamp-pid[.state]> <age-min> <item>... — item `#...` is written verbatim, `=<line>`
# raw with RID replaced by this repo's id, anything else `<secs>:<key>` as a record.
dc_plant() {
  local f age rid it
  f="$(lm_dur_dir)/$(dc_name "$1")"; age="$2"; shift 2
  rid="$(lm_rid)"; mkdir -p "$(lm_dur_dir)"; : > "$f"
  for it in "$@"; do
    case "$it" in
      '#'*) printf '%s\n' "$it" >> "$f" ;;
      =*) it="${it#=}"; printf '%s\n' "${it//RID/$rid}" >> "$f" ;;
      *) printf '%s|%s|%s\n' "$rid" "${it%%:*}" "${it#*:}" >> "$f" ;;
    esac
  done
  lm_age "$f" "$age"
}

# dc_cons [now] — one consolidation round over this host's ledger.
dc_cons() { run_all_dur_consolidate "$(lm_dur_dir)" "${1:-$DC_NOW}"; }

# dc_ls — the ledger listing with this host's token shown as `T`.
dc_ls() { local t; t="$(lm_tok)"; lm_ls | sed -e "s/$t/T/g" -e 's/ *$//'; }

# dc_bases — base segments (`-0<k>.log`, not moved aside), name order, token shown as `T`.
dc_bases() {
  local f t out=""; t="$(lm_tok)"
  for f in "$(lm_dur_dir)"/dur.2."$t".*-0*.log; do
    [ -f "$f" ] || continue
    case "$f" in *.consolidating.log|*.closed.log) continue ;; esac
    out="$out ${f##*/}"
  done
  printf '%s\n' "${out# }" | sed "s/$t/T/g"
}

# dc_heads — the first line of every base, `#os ` cut, comma-joined, name order.
dc_heads() {
  local b out=""
  for b in $(dc_bases); do out="$out,$(head -n 1 "$(lm_dur_dir)/${b/.T./.$(lm_tok).}" | sed 's/^#os //')"; done
  printf '%s\n' "${out#,}"
}

# dc_body — every base's lines, repo id shown as `R`, `;`-joined, name order.
dc_body() {
  local b rid; rid="$(lm_rid)"
  for b in $(dc_bases); do cat "$(lm_dur_dir)/${b/.T./.$(lm_tok).}"; done | sed "s/^$rid|/R|/" | tr '\n' ';'
}

# dc_snap — name:cksum of every ledger entry (directories show as `dir`).
dc_snap() {
  local e f
  for e in $(lm_ls); do
    f="$(lm_dur_dir)/$e"
    if [ -d "$f" ]; then printf '%s:dir ' "$e"; else printf '%s:%s ' "$e" "$(lm_sum "$f")"; fi
  done
  echo
}

# dc_count_own_closed — this host's well-formed closed segments only (the ones consolidation
# consumes); other-token and malformed-name closed files are not counted.
dc_count_own_closed() {
  local f n=0 d='[0-9]' t; t="$(lm_tok)"
  for f in "$(lm_dur_dir)"/dur.2."$t".$d$d$d$d$d$d$d$d"T"$d$d$d$d$d$d-$d*.closed.log; do
    [ -e "$f" ] || continue
    n=$((n + 1))
  done
  echo "$n"
}

# dc_report <key>... — the standard after-state of one case.
dc_report() {
  say vals "$(lm_get "$@")"
  say ls "$(dc_ls)"
  say bases "$(dc_bases)"
  say nb "$(dc_bases | wc -w | tr -d ' ')"
  say heads "$(dc_heads)"
  say ncons "$(lm_count '*.consolidating.log')"
  say nclosed "$(dc_count_own_closed)"
  say lock "$([ -e "$(lm_dur_dir)/.ledger.lock" ] && echo 1 || echo 0)"
  say ntmp "$(lm_count '.dur.tmp.*')"
}

# dc_spy_on / dc_spy_off — record every lock, rename, read, check or delete process the
# library starts; the quiet path must start none of them (`find` is allowed: rule 4).
dc_spy_on() {
  local c
  DC_SPY="$LM_TMP/spy.$$"; : > "$DC_SPY"
  run_all_dur_host_token >/dev/null; run_all_dur_repo_id "$LM_REPO" >/dev/null
  for c in mkdir mv awk cksum wc rm touch cat; do
    eval "$c() { printf '%s\n' $c >> \"\$DC_SPY\"; command $c \"\$@\"; }"
  done
}
dc_spy_off() { unset -f mkdir mv awk cksum wc rm touch cat; say spy "$(LC_ALL=C sort -u "$DC_SPY" | tr '\n' ' ')"; }
