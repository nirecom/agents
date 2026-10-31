#!/usr/bin/env bash
# tests/bin/feature-2814-upstream-cli.sh
# Tests: bin/review-loop-upstream, bin/lib/concern-ledger/upstream-tag.sh
# Tags: TL2, review-loop, upstream-inconsistency, concern-ledger, security, idempotency, issue-2814, scope:issue-specific, pwsh-not-required, dup-group-keep:size-hard-limit
# #2814 T5 bin/review-loop-upstream. list: one TSV from the codex RAW and the three CC fallback
# shapes, in every format; only tagged concerns; prior_choice keyed by cycle + id + exact body
# (fallback ids remapped via seen.tsv); a codex-path candidate needs an open ledger ID AND its body
# hash; an unreadable ledger fails closed; a tab or CR never shifts the 14 columns. decide records
# A/B/C/D only for the latest listed pair (C alone accepts; a failed accept rolls it back); return
# (exit 3 unless --to is pending) clears the work data at and after its step, bumps the cycle.
# TL3 gap: live reviewers, AskUserQuestion and WORKFLOW_RESET_FROM_ are not driven; shapes are fixtures.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
UP_ROOT="$(make_tmp)"
readonly UP_ROOT
trap 'cd / 2>/dev/null; rm -rf "$UP_ROOT"' EXIT
harness_isolate "$UP_ROOT/iso"
unset CLAUDE_CODE_SESSION_ID
cd "$UP_ROOT" || exit 1
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2814-upstream/common.sh"

FMT=detail-plan
t_n() { up_tag upstream-gap C intent "$UP_Q_LINE" "defect number $1 of the fixture"; }
T1="$(t_n 1)"; T2="$(t_n 2)"; T3="$(t_n 3)"; T4="$(t_n 4)"; T99="$(t_n 99)"
PLAIN="the retry path is not covered by any step"
ls_run() { up list --session "$1" --format "$FMT" --round "$2" --from-report "$3"; }
drop_id() { printf '%s\n' "$1" | awk -F'\t' 'BEGIN{OFS="\t"} NF{$2=""; print}'; }

case_begin "list-shapes-give-one-tsv" "bin/review-loop-upstream"
REF=""
for shape in raw detail outline test; do
  sid="sh-$shape"; up_write_plans "$sid"
  up_report "$shape" "$UP_ROOT/shape-$shape.md" "1|HIGH|$T1" "2|MEDIUM|$PLAIN" "3|LOW|$T2"
  ls_run "$sid" 1 "$UP_ROOT/shape-$shape.md"
  ck "shape $shape: list exits 0" "0" "$UP_RC"
  ck "shape $shape: only the two tagged concerns are listed" "2" "$(up_rows "$UP_OUT")"
  ck "shape $shape: every row has 14 columns" "14 14" "$(printf '%s\n' "$UP_OUT" | awk -F'\t' 'NF{printf "%s%s", s, NF; s=" "}')"
  ck "shape $shape: the ids are the tagged lines' ids" "1 3" "$(up_ids "$UP_OUT")"
  ck_lacks "shape $shape: the untagged concern is not listed" "$PLAIN" "$UP_OUT"
  if [ "$shape" = raw ]; then REF="$(drop_id "$UP_OUT")"
  else ck "shape $shape: the TSV equals the RAW one (id column aside)" "$REF" "$(drop_id "$UP_OUT")"; fi
done
ck "shape: the RAW reference is not empty (precondition)" "yes" "$([ -n "$REF" ] && printf yes || printf no)"
case_end

case_begin "list-each-format-explicit" "bin/review-loop-upstream"
# codex review C3: each format runs as itself; its upstream roles and B return steps come from the
# core.md format table, and its seen.tsv is its own file. Rows: format|shape|source|quote var|step.
FMT_ROWS=(
  "outline-plan|outline|intent|UP_Q_LINE|clarify_intent"
  "security-plan|raw|outline|UP_Q_OUTLINE|outline"
  "test-review|test|detail|UP_Q_DETAIL|detail"
  "detail-plan|detail|outline|UP_Q_OUTLINE|outline"
)
for row in "${FMT_ROWS[@]}"; do
  IFS='|' read -r fm shp src qvar step <<< "$row"
  sid="fm-$fm"; up_write_plans "$sid"
  up_report "$shp" "$UP_ROOT/$sid.md" "1|HIGH|$(up_tag upstream-gap B "$src" "${!qvar}" "the reviewed artifact drops this requirement")"
  up list --session "$sid" --format "$fm" --round 1 --from-report "$UP_ROOT/$sid.md"
  ck "format $fm: list exits 0 with one 14-column row" "0 1 14" "$UP_RC $(up_rows "$UP_OUT") $(printf '%s\n' "$UP_OUT" | awk -F'\t' 'NF{print NF; exit}')"
  ck "format $fm: a $src quote keeps B with no downgrade reason" "B|" "$(up_col 6 "$UP_OUT")|$(up_col 8 "$UP_OUT")"
  ck "format $fm: b_return_step for source $src is $step" "$step" "$(up_col 7 "$UP_OUT")"
  other=detail-plan; [ "$fm" = detail-plan ] && other=outline-plan
  ck "format $fm: seen.tsv is the format's own file, not $other's" "yes no" \
    "$(test -s "$(up_ctl "$sid")/$fm-upstream-seen.tsv" && printf yes || printf no) $(test -e "$(up_ctl "$sid")/$other-upstream-seen.tsv" && printf yes || printf no)"
done
case_end

case_begin "list-no-candidates-empty" "bin/review-loop-upstream"
up_write_plans nc
up_report raw "$UP_ROOT/nc.md" "1|MEDIUM|$PLAIN"
ls_run nc 1 "$UP_ROOT/nc.md"
ck "no candidates: list exits 0 and prints nothing" "0|" "$UP_RC|$UP_OUT"
case_end

# col_of <tsv> <id> <n> — column n of the row for an id (C prefix ignored); "<no-row>" when absent.
col_of() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" -v n="$3" '{id=$2; sub(/^C/,"",id)} id==k {print $n; f=1; exit} END{if(!f) printf "<no-row>"}'; }

case_begin "list-prior-choice-scope" "bin/review-loop-upstream"
# Key is cycle + id + text_hash: rows 1 and 2 share a body (two open IDs), row 3 differs.
up_write_plans pc
up_report raw "$UP_ROOT/pc1.md" "1|HIGH|$T1" "2|HIGH|$T1" "3|HIGH|$T2"
ls_run pc 1 "$UP_ROOT/pc1.md"
H1="$(up_hash_of "$UP_OUT" 1)"; ID1="$(col_of "$UP_OUT" 1 2)"
ck "prior: three rows are listed and rows 1 and 2 share a hash (precondition)" "3 yes" \
  "$(up_rows "$UP_OUT") $([ "$(up_is_hash "$H1")" = yes ] && [ "$H1" = "$(up_hash_of "$UP_OUT" 2)" ] && printf yes || printf no)"
ck "prior: the first list has no prior choice" "" "$(col_of "$UP_OUT" 1 9)"
up decide --session pc --format "$FMT" --id "$ID1" --text-hash "$H1" --choice C --reason "keep the intent wording"
ck "prior: decide C on the listed pair exits 0 (precondition)" "0" "$UP_RC"
ls_run pc 1 "$UP_ROOT/pc1.md"
ck "prior: the chosen id with the same body carries prior_choice C" "C" "$(col_of "$UP_OUT" 1 9)"
ck "prior: the same body under another open id that was not chosen carries none" "" "$(col_of "$UP_OUT" 2 9)"
ck "prior: a different body carries no prior choice" "" "$(col_of "$UP_OUT" 3 9)"
up_report raw "$UP_ROOT/pc-other.md" "1|HIGH|$T3"
ls_run pc 1 "$UP_ROOT/pc-other.md"
ck "prior: the chosen id with a different body carries no prior choice" "" "$(col_of "$UP_OUT" 1 9)"
ck "prior: the different-body row is listed (precondition)" "1" "$(up_rows "$UP_OUT")"
mkdir -p "$(up_ctl pc)"
printf '2\n' > "$(up_ctl pc)/$FMT-review-cycle.txt"
ls_run pc 1 "$UP_ROOT/pc1.md"
ck "prior: a C from the previous cycle no longer counts" "" "$(col_of "$UP_OUT" 1 9)"
ck "prior: the cycle column shows the new cycle" "2" "$(up_col 1 "$UP_OUT")"
case_end

case_begin "list-prior-choice-fallback-id-remap" "bin/review-loop-upstream"
# Fallback ids are report serials: round 2 renumbers, so C is matched via seen.tsv to the round 1 id.
up_write_plans pr
up_report test "$UP_ROOT/pr1.md" "1|HIGH|$T2" "2|HIGH|$T1"
ls_run pr 1 "$UP_ROOT/pr1.md"
HA="$(col_of "$UP_OUT" 2 3)"; IA="$(col_of "$UP_OUT" 2 2)"
up decide --session pr --format "$FMT" --id "$IA" --text-hash "$HA" --choice C --reason "keep the intent wording"
ck "remap: decide C on the round 1 pair exits 0 (precondition)" "0" "$UP_RC"
up_report test "$UP_ROOT/pr2.md" "1|HIGH|$T1" "2|HIGH|$T2"
ls_run pr 2 "$UP_ROOT/pr2.md"
ck "remap: round 2 lists both bodies seen in round 1" "0 2" "$UP_RC $(up_rows "$UP_OUT")"
ck "remap: the chosen body, renumbered to 1, carries prior_choice C" "C" \
  "$(printf '%s\n' "$UP_OUT" | awk -F'\t' -v h="$HA" '$3==h {print $9; f=1; exit} END{if(!f) printf "<no-row>"}')"
ck "remap: the unchosen body, renumbered to 2, carries none" "" \
  "$(printf '%s\n' "$UP_OUT" | awk -F'\t' -v h="$HA" 'NF && $3!=h {print $9; f=1; exit} END{if(!f) printf "<no-row>"}')"
case_end

case_begin "list-codex-path-ledger-binding" "bin/review-loop-upstream"
up_write_plans cb
up_ledger_r1 cb "$FMT" "1|HIGH|$T1" "2|HIGH|$T2" "3|HIGH|$T3" "4|HIGH|$T4"
up_ledger_r2 cb "$FMT" "C1: unresolved — still" "C3: unresolved — still" "C4: unresolved — still"
L="$(up_ledger cb "$FMT")"
awk -F'|' 'BEGIN{OFS="|"} $1=="C3"{$3="rejected"} {print}' "$L" > "$L.new"
mv "$L.new" "$L"
ck "binding: ledger states C1..C4 (precondition)" "open resolved rejected open" \
  "$(up_state cb "$FMT" C1) $(up_state cb "$FMT" C2) $(up_state cb "$FMT" C3) $(up_state cb "$FMT" C4)"
up_report detail "$UP_ROOT/cb.md" "1|HIGH|$T1" "2|HIGH|$T2" "3|HIGH|$T3" "99|HIGH|$T99"
ls_run cb 2 "$UP_ROOT/cb.md"
ck "binding: list exits 0" "0" "$UP_RC"
ck "binding: only the open C1 is listed (resolved C2, rejected C3, new C99 are not)" "1" "$(up_ids "$UP_OUT")"
# Coordinator security case: a foreign body bound to a known open ID never pauses the loop.
up_report detail "$UP_ROOT/cb-foreign.md" "4|HIGH|$T1"
ls_run cb 2 "$UP_ROOT/cb-foreign.md"
ck "binding: C4 carrying C1's body is not listed" "0|" "$UP_RC|$UP_OUT"
up_report detail "$UP_ROOT/cb-ws.md" "4|HIGH|${T4/section: Scope/section:  Scope}"
ls_run cb 2 "$UP_ROOT/cb-ws.md"
ck "binding: C4 with a whitespace variant of its body is not listed" "0|" "$UP_RC|$UP_OUT"
up_report detail "$UP_ROOT/cb-own.md" "4|HIGH|$T4"
ls_run cb 2 "$UP_ROOT/cb-own.md"
ck "binding: C4 with its own ledger body is listed (control)" "4" "$(up_ids "$UP_OUT")"
case_end

case_begin "list-fallback-round2-seen-only" "bin/review-loop-upstream"
up_write_plans fb
up_report test "$UP_ROOT/fb1.md" "1|HIGH|$T1"
ls_run fb 1 "$UP_ROOT/fb1.md"
ck "fallback: round 1 lists the candidate" "1" "$(up_rows "$UP_OUT")"
ck "fallback: round 1 records the hash in upstream-seen.tsv" "yes" \
  "$([ -s "$(up_ctl fb)/$FMT-upstream-seen.tsv" ] && printf yes || printf no)"
ck "fallback: the seen.tsv row is cycle, round, id, text_hash of the listed row" \
  "$(printf '1\t1\t%s\t%s' "$(up_col 2 "$UP_OUT")" "$(up_col 3 "$UP_OUT")")" \
  "$(awk 'NF{sub(/\r$/,""); print; exit}' "$(up_ctl fb)/$FMT-upstream-seen.tsv" 2>/dev/null)"
up_report test "$UP_ROOT/fb2.md" "1|HIGH|$T1" "2|HIGH|$T2"
ls_run fb 2 "$UP_ROOT/fb2.md"
ck "fallback: round 2 lists only the hash seen in round 1" "1" "$(up_ids "$UP_OUT")"
up_write_plans fp
up_report test "$UP_ROOT/fp1.md" "1|HIGH|$T1"
ls_run fp 1 "$UP_ROOT/fp1.md"
mkdir -p "$(up_ctl fp)"
printf '2\n' > "$(up_ctl fp)/$FMT-review-cycle.txt"
ls_run fp 2 "$UP_ROOT/fp1.md"
ck "fallback: a hash seen only in the previous cycle is not listed" "0|" "$UP_RC|$UP_OUT"
case_end

case_begin "list-unreadable-ledger-fails-closed" "bin/review-loop-upstream"
up_write_plans ur
mkdir -p "$(up_ledger ur "$FMT")"
up_report raw "$UP_ROOT/ur.md" "1|HIGH|$T1"
ls_run ur 1 "$UP_ROOT/ur.md"
ck "unreadable: a ledger that cannot be read exits 1" "1" "$UP_RC"
ck "unreadable: nothing is listed" "" "$UP_OUT"
case_end

case_begin "list-control-chars-keep-14-columns" "bin/review-loop-upstream"
# audit run-0014: section, downstream and reason are columns too, encoded by cl_upstream_tsv_field.
up_write_plans tq
TTAB="$(printf '[upstream-inconsistency cause=upstream-gap recommend=C source=intent] section: Sco\tpe ; quote: «The loop\tstops» ; downstream: «step\t3» ; defect: a defect with a\\backslash ; reason: first\rsecond')"
up_report raw "$UP_ROOT/tq.md" "1|HIGH|$TTAB"
ls_run tq 1 "$UP_ROOT/tq.md"
ck "tab: the tab-carrying concern is listed once" "1" "$(up_rows "$UP_OUT")"
ck "tab: the row still has 14 columns" "14" "$(printf '%s\n' "$UP_OUT" | awk -F'\t' 'NF{print NF; exit}')"
ck "tab: the output is a single line" "1" "$(printf '%s\n' "$UP_OUT" | awk 'NF{n++} END{print n+0}')"
ck "tab: the section column carries the tab as \\t" 'Sco\tpe' "$(up_col 10 "$UP_OUT")"
ck "tab: the quote column carries the tab as the two characters \\t" 'The loop\tstops' "$(up_col 11 "$UP_OUT")"
ck "tab: the downstream column carries the tab as \\t" 'step\t3' "$(up_col 12 "$UP_OUT")"
ck "tab: the backslash in the defect is doubled" 'a defect with a\\backslash' "$(up_col 13 "$UP_OUT")"
ck "tab: the CR in the reason becomes \\r" 'first\rsecond' "$(up_col 14 "$UP_OUT")"
ck "tab: upstream-seen.tsv keeps one line per listed concern" "1" \
  "$(awk 'NF{n++} END{print n+0}' "$(up_ctl tq)/$FMT-upstream-seen.tsv" 2>/dev/null)"
case_end

case_begin "decide-control-chars-write-nothing" "bin/review-loop-upstream"
up_write_plans dc
up_report raw "$UP_ROOT/dc.md" "1|HIGH|$T1"
ls_run dc 1 "$UP_ROOT/dc.md"
HD="$(up_hash_of "$UP_OUT" 1)"
up decide --session dc --format "$FMT" --id C1 --text-hash "$HD" --choice A --reason "revise upstream"
DEC="$(up_ctl dc)/$FMT-upstream-decisions.tsv"
ck "control: a clean decide writes decisions.tsv (precondition)" "0 yes" "$UP_RC $([ -s "$DEC" ] && printf yes || printf no)"
BEFORE="$(sum_of "$DEC")"
NL=$'\n'
for bad in reason id hash choice; do
  r="ok"; i="C1"; h="$HD"; c="C"
  case "$bad" in
    reason) r="fine${NL}2	C1	${HD}	C	forged" ;;
    id) i=$'C1\tC2' ;;
    hash) h="${HD}${NL}x" ;;
    choice) c=$'C\r' ;;
  esac
  up decide --session dc --format "$FMT" --id "$i" --text-hash "$h" --choice "$c" --reason "$r"
  ck "control: a control character in --$bad exits 2" "2" "$UP_RC"
  ck "control: decisions.tsv is byte-identical after the bad --$bad" "$BEFORE" "$(sum_of "$DEC")"
done
ck "control: no forged C row was written" "0" "$(if [ -f "$DEC" ]; then awk '/forged/{n++} END{print n+0}' "$DEC"; else printf 0; fi)"
case_end

# --- decide / pick-upstream / return / accepted -----------------------------------------
yn() { if "$@"; then printf yes; else printf no; fi; }
# hash_for <sid> <fmt> <round> <text> — the list text_hash of a one-line RAW report.
hash_for() {
  up_report raw "$UP_ROOT/h-$1-$2.md" "1|HIGH|$4"
  up list --session "$1" --format "$2" --round "$3" --from-report "$UP_ROOT/h-$1-$2.md"
  up_hash_of "$UP_OUT" 1
}
# dec_match <sid> <fmt> <value>... — decisions.tsv lines carrying every value as a whole field.
dec_match() {
  local f; f="$(dec_file "$1" "$2")"; shift 2
  [ -f "$f" ] || { printf 0; return; }
  awk -F'\t' -v want="$(printf '%s\034' "$@")" 'BEGIN{n=split(want, w, "\034")-1}
    {sub(/\r$/,""); for (i=1; i<=n; i++) {hit=0; for (j=1; j<=NF; j++) if ($j==w[i]) hit=1; if (!hit) next} c++}
    END{print c+0}' "$f"
}

case_begin "decide-fallback-and-ledger" "bin/review-loop-upstream"
up_write_plans d1
H="$(hash_for d1 detail-plan 1 "$DT2")"
up decide --session d1 --format detail-plan --id C1 --text-hash "$H" --choice C --reason "follow the intent"
ck "decide fallback: exits 0" "0" "$UP_RC"
ck_has "decide fallback: the row records ledger=absent" "ledger=absent" "$(cat "$(dec_file d1 detail-plan)" 2>/dev/null)"
ck "decide fallback: the row carries a real text_hash (precondition)" "yes" "$(up_is_hash "$H")"
ck_has "decide fallback: the row carries the text_hash" "${H:-<no-hash-listed>}" "$(cat "$(dec_file d1 detail-plan)" 2>/dev/null)"
up_write_plans d2
up_ledger_r1 d2 detail-plan "1|HIGH|$DT2"
H="$(hash_for d2 detail-plan 1 "$DT2")"
up decide --session d2 --format detail-plan --id C1 --text-hash "$H" --choice C --reason "follow the intent"
ck "decide ledger: exits 0" "0" "$UP_RC"
ck_has "decide ledger: the row records ledger=present" "ledger=present" "$(cat "$(dec_file d2 detail-plan)" 2>/dev/null)"
ck "decide ledger: C closes the ledger row through accept" "rejected" "$(up_state d2 detail-plan C1)"
ck_has "decide ledger: the closed row carries the accept label" "accepted(upstream-inconsistency)" "$(up_row d2 detail-plan C1)"
N0="$(dec_lines d2 detail-plan)"
up decide --session d2 --format detail-plan --id C1 --text-hash "$H" --choice X --reason "bogus"
ck_nz "decide: an unknown choice is refused" "$UP_RC"
ck "decide: the refused choice writes no row" "$N0" "$(dec_lines d2 detail-plan)"
case_end

case_begin "decide-a-b-d-record-and-next-step" "bin/review-loop-upstream"
# codex review C2: A, B and D each record one decisions.tsv row (cycle, id, hash, choice, reason
# verbatim, ledger=present) and leave the ledger row open — only C accepts. A and D keep the cycle
# and the loop's work data, and the next round asks again; only B leads to pick-upstream + return.
DEC_ROWS=(
  "A|da|revise the detail plan to match the intent"
  "D|dd|Rewrite step 3 so the loop stops before re-delegation; keep step 4 as is."
  "B|db|the intent needs the stop"
)
for row in "${DEC_ROWS[@]}"; do
  IFS='|' read -r ch sid why <<< "$row"
  up_write_plans "$sid"
  up_ledger_r1 "$sid" detail-plan "1|HIGH|$DT1"
  up_report raw "$UP_ROOT/$sid.md" "1|HIGH|$DT1"
  up list --session "$sid" --format detail-plan --round 1 --from-report "$UP_ROOT/$sid.md"
  id="$(up_col 2 "$UP_OUT")"; h="$(up_col 3 "$UP_OUT")"; ret="$(up_col 7 "$UP_OUT")"
  ck "decide $ch: the open concern is listed with a real hash (precondition)" "0 1 yes" "$UP_RC $(up_rows "$UP_OUT") $(up_is_hash "$h")"
  up decide --session "$sid" --format detail-plan --id "$id" --text-hash "$h" --choice "$ch" --reason "$why"
  ck "decide $ch: exits 0" "0" "$UP_RC"
  ck "decide $ch: decisions.tsv has exactly one line" "1" "$(dec_lines "$sid" detail-plan)"
  ck "decide $ch: the line carries cycle 1, id, hash, $ch, the reason verbatim and ledger=present" "1" \
    "$(dec_match "$sid" detail-plan 1 "$id" "$h" "$ch" "$why" ledger=present)"
  ck "decide $ch: the ledger row stays open" "open" "$(up_state "$sid" detail-plan C1)"
  ck_lacks "decide $ch: the ledger row carries no accept label" "accepted(upstream-inconsistency)" "$(up_row "$sid" detail-plan C1)"
  up accepted --session "$sid" --format detail-plan
  ck "decide $ch: accepted exits 0 (precondition)" "0" "$UP_RC"
  ck_lacks "decide $ch: accepted does not list a non-C choice" "$why" "$UP_OUT"
  if [ "$ch" = B ]; then
    up pick-upstream "$ret"
    ck "decide B: pick-upstream of the row's b_return_step gives clarify_intent" "0 clarify_intent" "$UP_RC $UP_OUT"
    up_mark "$sid" clarify_intent pending
    up return --session "$sid" --to clarify_intent --from-format detail-plan
    ck "decide B: return to clarify_intent exits 0" "0" "$UP_RC"
    ck "decide B: return bumps the cycle and clears the ledger" "2 yes" \
      "$(f="$(up_ctl "$sid")/detail-plan-review-cycle.txt"; if [ -f "$f" ]; then tr -d '\r\n ' < "$f"; else printf 1; fi) $(yn test ! -e "$(up_ledger "$sid" detail-plan)")"
  else
    up list --session "$sid" --format detail-plan --round 2 --from-report "$UP_ROOT/$sid.md"
    ck "decide $ch: the next round lists the concern again with no prior choice" "0 1 " "$UP_RC $(up_rows "$UP_OUT") $(up_col 9 "$UP_OUT")"
    ck "decide $ch: no return happened (cycle 1, ledger kept)" "no yes" \
      "$(yn test -e "$(up_ctl "$sid")/detail-plan-review-cycle.txt") $(yn test -f "$(up_ledger "$sid" detail-plan)")"
  fi
done
case_end

case_begin "decide-c-rolls-back-on-failed-accept" "bin/review-loop-upstream"
# A ledger C whose accept fails (the listed C1 row is gone from the ledger, so cl_accept gives 4)
# exits 1 and leaves decisions.tsv as it was: restored when it existed, absent when it did not.
for pre in absent present; do
  sid="rb-$pre"; up_write_plans "$sid"
  up_ledger_r1 "$sid" detail-plan "1|HIGH|$DT2"
  h="$(hash_for "$sid" detail-plan 1 "$DT2")"
  ck "rollback ($pre): C1 is listed with a real hash (precondition)" "yes" "$(up_is_hash "$h")"
  [ "$pre" = absent ] || up decide --session "$sid" --format detail-plan --id C1 --text-hash "$h" --choice A --reason "revise upstream first"
  D0="$(sum_of "$(dec_file "$sid" detail-plan)")"
  ck "rollback ($pre): decisions.tsv is $pre before the C (precondition)" "$pre" "$([ "$D0" = absent ] && printf absent || printf present)"
  L="$(up_ledger "$sid" detail-plan)"
  awk -F'|' 'BEGIN{OFS="|"} $1=="C1"{$1="C7"} {print}' "$L" > "$L.new"; mv "$L.new" "$L"
  up decide --session "$sid" --format detail-plan --id C1 --text-hash "$h" --choice C --reason "follow the intent"
  ck "rollback ($pre): a failed accept exits 1" "1" "$UP_RC"
  ck_has "rollback ($pre): stderr says no C is recorded" "no C is recorded" "$UP_ERR"
  ck "rollback ($pre): decisions.tsv is byte-identical to before (or still absent)" "$D0" "$(sum_of "$(dec_file "$sid" detail-plan)")"
  ck "rollback ($pre): no backup or temp copy is left" "" "$(ls -A "$(up_ctl "$sid")" | grep -E 'decisions\.tsv\.(bak|tmp)\.' || true)"
done
case_end

case_begin "list-same-round-replaces-seen" "bin/review-loop-upstream"
# codex test review C2: a re-list of the same cycle and round replaces that round's seen.tsv rows.
up_write_plans sr
SEEN_SR="$(up_ctl sr)/$FMT-upstream-seen.tsv"
up_report raw "$UP_ROOT/sr1.md" "1|HIGH|$T1" "2|HIGH|$T2"
ls_run sr 1 "$UP_ROOT/sr1.md"
OI="$(col_of "$UP_OUT" 1 2)"; OH="$(up_hash_of "$UP_OUT" 1)"; O2I="$(col_of "$UP_OUT" 2 2)"; O2H="$(up_hash_of "$UP_OUT" 2)"
up_report raw "$UP_ROOT/sr2.md" "1|HIGH|$T3"
ls_run sr 1 "$UP_ROOT/sr2.md"
NI="$(col_of "$UP_OUT" 1 2)"; NH="$(up_hash_of "$UP_OUT" 1)"
ck "same round: both lists give real, distinct hashes (precondition)" "0 yes yes yes" "$UP_RC $(up_is_hash "$OH") $(up_is_hash "$NH") $([ "$OH" != "$NH" ] && printf yes || printf no)"
ck "same round: seen.tsv holds only the second list's row" "1 1 $NI $NH" "$(awk -F'\t' '{sub(/\r$/,"")} NF{print $1, $2, $3, $4}' "$SEEN_SR" 2>/dev/null)"
ck "same round: every seen.tsv row has 4 columns" "4" "$(awk -F'\t' '{sub(/\r$/,"")} NF{print NF}' "$SEEN_SR" 2>/dev/null | sort -u)"
ck "same round: the old hashes are gone from seen.tsv" "0" "$(awk -v a="$OH" -v b="$O2H" 'index($0,a)||index($0,b){n++} END{print n+0}' "$SEEN_SR" 2>/dev/null)"
SR_D="$(sum_of "$(dec_file sr "$FMT")")"; SR_S="$(sum_of "$SEEN_SR")"
for pair in "$OI|$OH" "$O2I|$O2H"; do
  up decide --session sr --format "$FMT" --id "${pair%%|*}" --text-hash "${pair#*|}" --choice C --reason "stale pair" </dev/null
  ck "same round: decide with the stale pair ${pair%%|*} exits 2" "2" "$UP_RC"
  ck "same round: the stale decide leaves decisions.tsv and seen.tsv unchanged" "$SR_D $SR_S" "$(sum_of "$(dec_file sr "$FMT")") $(sum_of "$SEEN_SR")"
done
up decide --session sr --format "$FMT" --id "$NI" --text-hash "$NH" --choice C --reason "fresh pair"
ck "same round: decide with the new pair exits 0 and appends one line" "0 1" "$UP_RC $(dec_lines sr "$FMT")"
ls_run sr 2 "$UP_ROOT/sr2.md"
ls_run sr 1 "$UP_ROOT/sr1.md"
ck "same round: re-listing round 1 drops the later round-2 rows" "0" "$(awk -F'\t' '$2=="2"{n++} END{print n+0}' "$SEEN_SR" 2>/dev/null)"
up decide --session sr --format "$FMT" --id "$NI" --text-hash "$NH" --choice A --reason "dropped pair"
ck "same round: a pair only the dropped rounds listed exits 2" "2 1" "$UP_RC $(dec_lines sr "$FMT")"
case_end

case_begin "pick-upstream-table" "bin/review-loop-upstream"
STEPS="$(node -e 'process.stdout.write(require(process.argv[1]).VALID_STEPS.join(" "))' "$(np "$SCRIPT_CHECKOUT_ROOT")/hooks/workflow-state/state-io.js" 2>/dev/null)"
ck "pick-upstream: VALID_STEPS is readable (precondition)" "yes" "$([ -n "$STEPS" ] && printf yes || printf no)"
idx() { printf '%s\n' $STEPS | awk -v s="$1" '$0==s{print NR; exit}'; }
# lowest <steps...> — the VALID_STEPS-earliest step, computed independently of the CLI.
lowest() { local s best="" bi=9999 i; for s in "$@"; do i="$(idx "$s")"; if [ -n "$i" ] && [ "$i" -lt "$bi" ]; then bi="$i"; best="$s"; fi; done; printf '%s' "$best"; }
while IFS='|' read -r input want; do
  [ -n "$input" ] || continue
  # shellcheck disable=SC2086
  up pick-upstream $input </dev/null
  ck "pick-upstream '$input': prints $want" "0 $want" "$UP_RC $UP_OUT"
  # shellcheck disable=SC2086
  ck "pick-upstream '$input': $want is the VALID_STEPS-earliest input" "$want" "$(lowest $input)"
done <<'TABLE'
detail outline|outline
write_tests detail|detail
write_tests clarify_intent outline|clarify_intent
write_tests|write_tests
TABLE
up pick-upstream bogus_step
ck "pick-upstream 'bogus_step': exit 2" "2" "$UP_RC"
case_end

# rt_seed <sid> <fmt> — a mid-loop format: ledger, round counter, built marker, list + decide B.
rt_seed() {
  local c; c="$(up_ctl "$1")"
  up_ledger_r1 "$1" "$2" "1|HIGH|$DT1"
  printf '2\n' > "$c/$2-round-number.txt"
  : > "$c/codex-context.$2.built"
  H="$(hash_for "$1" "$2" 1 "$DT1")"
  up decide --session "$1" --format "$2" --id C1 --text-hash "$H" --choice B --reason "the intent needs the stop"
}
sums() { local f; for f in "$@"; do if [ -f "$f" ]; then cksum "$f" | cut -d' ' -f1,2; else printf 'absent\n'; fi; done; }
cleared() { local c; c="$(up_ctl "$1")"; printf '%s %s %s' "$(yn test ! -e "$(up_ledger "$1" "$2")")" "$(yn test ! -e "$c/$2-round-number.txt")" "$(yn test ! -e "$c/codex-context.$2.built")"; }
cycle_of() { local f; f="$(up_ctl "$1")/$2-review-cycle.txt"; if [ -f "$f" ]; then tr -d '\r\n ' < "$f"; else printf 1; fi; }

case_begin "return-to-detail-clears-work-data" "bin/review-loop-upstream"
up_write_plans rt
mkdir -p "$UP_ROOT/proj/tests"
printf '#!/usr/bin/env bash\necho fixture test\n' > "$UP_ROOT/proj/tests/fixture-test.sh"
KEEP=("$(up_plan_path intent rt)" "$(up_plan_path outline rt)" "$(up_plan_path detail rt)" "$UP_ROOT/proj/tests/fixture-test.sh" "$UP_TD_CTX")
for f in outline-plan detail-plan test-review; do rt_seed rt "$f"; done
SUM0="$(sums "${KEEP[@]}")"
C="$(up_ctl rt)"
up_mark rt detail pending
up return --session rt --to detail --from-format detail-plan
ck "return detail: exits 0" "0" "$UP_RC"
for f in detail-plan test-review; do
  ck "return detail: $f ledger, round counter and built marker are removed" "yes yes yes" "$(cleared rt "$f")"
  ck "return detail: $f keeps the escalate artifact" "yes" "$(yn test -f "$C/$f-unresolved-concerns.json")"
  ck "return detail: $f records the last round" "yes" "$(yn test -s "$C/$f-last-round.txt")"
  ck "return detail: $f keeps decisions.tsv and upstream-seen.tsv" "yes yes" "$(yn test -s "$C/$f-upstream-decisions.tsv") $(yn test -s "$C/$f-upstream-seen.tsv")"
  ck "return detail: $f cycle goes 1 -> 2" "2" "$(cycle_of rt "$f")"
done
ck "return detail: security-plan cycle goes 1 -> 2" "2" "$(cycle_of rt security-plan)"
ck "return detail: outline-plan (upstream of detail) keeps its ledger" "open" "$(up_state rt outline-plan C1)"
ck "return detail: outline-plan cycle is unchanged" "1" "$(cycle_of rt outline-plan)"
ck "return detail: plans, test files and test design are byte-identical" "$SUM0" "$(sums "${KEEP[@]}")"
ck "return detail: the kept-file sums are real (precondition)" "0" "$(printf '%s\n' "$SUM0" | grep -c absent || true)"
up return --session rt --to detail --from-format detail-plan
ck "return detail again: a second return still exits 0" "0" "$UP_RC"
ck "return detail again: the cycle advances once more (one bump per return)" "3" "$(cycle_of rt detail-plan)"
ck "return detail again: plans stay byte-identical" "$SUM0" "$(sums "${KEEP[@]}")"
case_end

case_begin "return-to-write-tests-only-test-review" "bin/review-loop-upstream"
up_write_plans rw
for f in detail-plan test-review; do rt_seed rw "$f"; done
up_mark rw write_tests pending
up return --session rw --to write_tests --from-format test-review
ck "return write_tests: exits 0" "0" "$UP_RC"
ck "return write_tests: test-review is cleared" "yes yes yes" "$(cleared rw test-review)"
ck "return write_tests: test-review cycle goes to 2" "2" "$(cycle_of rw test-review)"
ck "return write_tests: detail-plan keeps its ledger" "open" "$(up_state rw detail-plan C1)"
ck "return write_tests: detail-plan keeps its built marker" "yes" "$(yn test -e "$(up_ctl rw)/codex-context.detail-plan.built")"
ck "return write_tests: detail-plan cycle is unchanged" "1" "$(cycle_of rw detail-plan)"
case_end

case_begin "return-refused-unless-step-pending" "bin/review-loop-upstream"
# Until WORKFLOW_RESET_FROM_ sets --to back to pending (bin/workflow/read-step-status), return
# exits 3 before any change: ledgers, round counters, built markers and cycles stay as they are.
up_write_plans rn
for f in detail-plan test-review; do rt_seed rn "$f"; done
C="$(up_ctl rn)"
WORK=()
for f in detail-plan test-review; do
  WORK+=("$(up_ledger rn "$f")" "$C/$f-round-number.txt" "$C/codex-context.$f.built" "$C/$f-review-cycle.txt" "$C/$f-upstream-decisions.tsv")
done
W0="$(sums "${WORK[@]}")"
ck "refused: the work data exists (precondition)" "8" "$(printf '%s\n' "$W0" | grep -vc absent)"
while IFS='|' read -r label to ff st; do
  [ -n "$label" ] || continue
  [ "$st" = NONE ] || up_mark rn "$to" "$st"
  up return --session rn --to "$to" --from-format "$ff" </dev/null
  ck "refused ($label): return exits 3" "3" "$UP_RC"
  ck_has "refused ($label): stderr asks for the reset first" "WORKFLOW_RESET_FROM_$to" "$UP_ERR"
  ck "refused ($label): work data byte-identical, no return journal" "$W0|no" "$(sums "${WORK[@]}")|$(yn test -e "$C/$ff-upstream-return.tsv")"
done <<'TABLE'
no recorded status (NONE)|detail|detail-plan|NONE
complete|write_tests|test-review|complete
in progress|detail|detail-plan|in_progress
TABLE
case_end

case_begin "accepted-current-cycle-only" "bin/review-loop-upstream"
up_write_plans ac
H="$(hash_for ac detail-plan 1 "$DT2")"
up decide --session ac --format detail-plan --id C1 --text-hash "$H" --choice C --reason "reason-cycle-one"
mkdir -p "$(up_ctl ac)"
printf '2\n' > "$(up_ctl ac)/detail-plan-review-cycle.txt"
H="$(hash_for ac detail-plan 1 "$DT1")"
up decide --session ac --format detail-plan --id C1 --text-hash "$H" --choice C --reason "reason-cycle-two"
up accepted --session ac --format detail-plan
ck "accepted: exits 0" "0" "$UP_RC"
ck_has "accepted: the current cycle's C is listed" "reason-cycle-two" "$UP_OUT"
ck_lacks "accepted: the previous cycle's C is not listed by default" "reason-cycle-one" "$UP_OUT"
ck_has "accepted: the ledger presence is shown" "absent" "$UP_OUT"
up accepted --session ac --format detail-plan --all-cycles
ck_has "accepted --all-cycles: the previous cycle's C is listed" "reason-cycle-one" "$UP_OUT"
ck_has "accepted --all-cycles: the current cycle's C is listed" "reason-cycle-two" "$UP_OUT"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
