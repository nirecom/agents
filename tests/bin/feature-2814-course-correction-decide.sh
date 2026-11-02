#!/usr/bin/env bash
# tests/bin/feature-2814-course-correction-decide.sh
# Tests: bin/review-loop-upstream, bin/lib/review-loop-upstream/course-correction.sh, bin/lib/concern-ledger/upstream-tag.sh
# Tags: TL2, review-loop, upstream-inconsistency, concern-ledger, course-correction, security, issue-2814, scope:issue-specific, pwsh-not-required
# #2814 reopen R6 (T7): decide --choice course-correction --transcript P --uuid U writes the record <fmt>-course-correction-c<cycle>-<id>.md and a decisions.tsv row with 7th column record=<path>,
# closes the ledger concern like C, and the next list carries prior_choice=course-correction; argument errors exit 2, an unknown uuid 3, a failed accept 1 (decisions.tsv restored, no record);
# a transcript not the session's own (locate) is refused (F2); a spoof of the own path (trailing space, symlink `..`) exits 2 or records only the own body; a leading-dash --transcript (`--require=`, `-v`) is compared as data, never parsed as a node option.
# TL3 gap (what this test does NOT catch):
# - the supervisor-audit lookup mode finding the right uuid in a live transcript.
# - symlink `..`: runs only on hosts that can create real symlinks (Linux/macOS CI); skips elsewhere.
# - the MSYS `/c/...` drive-form path difference: not isolable in the temp dir, so untested.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
UP_ROOT="$(make_tmp)"
readonly UP_ROOT
trap 'cd / 2>/dev/null; rm -rf "$UP_ROOT"' EXIT
harness_isolate "$UP_ROOT/iso"
unset CLAUDE_CODE_SESSION_ID
CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$UP_ROOT/transcripts")"
export CLAUDE_TRANSCRIPT_BASE_DIR
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/proj"
cd "$UP_ROOT" || exit 1
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2814-upstream/common.sh"

FMT=detail-plan
yn() { if "$@"; then printf yes; else printf no; fi; }
col_of() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" -v n="$3" '{id=$2; sub(/^C/,"",id)} id==k {print $n; f=1; exit} END{if(!f) printf "<no-row>"}'; }
rec_path() { printf '%s/%s-course-correction-c%s-%s.md' "$(up_ctl "$1")" "$FMT" "$2" "$3"; }
rec_count() { if [ -d "$(up_ctl "$1")" ]; then find "$(up_ctl "$1")" -name "$FMT-course-correction-*" | awk 'END{print NR}'; else printf 0; fi; }
# dec_col7 <sid> — the 7th tab column of the last decisions.tsv line.
dec_col7() { awk -F'\t' 'NF{sub(/\r$/,""); v=$7} END{printf "%s", v}' "$(dec_file "$1" "$FMT")" 2>/dev/null; }

# The fixture transcript: two real user prompts with uuids, an assistant reply between them.
TR="$UP_ROOT/transcript.jsonl"
UUID_OK="11111111-2222-4333-8444-555555555555"
UUID_NONE="99999999-2222-4333-8444-555555555555"
CC_TEXT="Drop the stop from the loop; the planner is re-delegated right away."
printf '%s\n' \
  '{"type":"user","uuid":"aaaaaaaa-2222-4333-8444-555555555555","timestamp":"2026-10-01T00:00:00Z","message":{"role":"user","content":"Plan the loop change."}}' \
  '{"type":"assistant","uuid":"bbbbbbbb-2222-4333-8444-555555555555","timestamp":"2026-10-01T00:00:05Z","message":{"role":"assistant","content":[{"type":"text","text":"The outline keeps the stop."}]}}' \
  "{\"type\":\"user\",\"uuid\":\"$UUID_OK\",\"timestamp\":\"2026-10-01T00:01:00Z\",\"message\":{\"role\":\"user\",\"content\":\"$CC_TEXT\"}}" > "$TR"

# listed <sid> <round> <report> — list, then LID/LH = the first row's id and hash.
LID=""; LH=""
listed() {
  up list --session "$1" --format "$FMT" --round "$2" --from-report "$3"
  LID="$(up_col 2 "$UP_OUT")"; LH="$(up_col 3 "$UP_OUT")"
}
# own_tr <sid> — copies the fixture to the session's own transcript (where `locate --session` finds
# it under CLAUDE_TRANSCRIPT_BASE_DIR) and prints that path; decide accepts only this one (F2).
own_tr() {
  local p="$CLAUDE_TRANSCRIPT_BASE_DIR/proj/$1.jsonl"
  [[ -f "$p" ]] || cp "$TR" "$p"
  printf '%s' "$p"
}
cc_decide() { up decide --session "$1" --format "$FMT" --id "$2" --text-hash "$3" --choice course-correction --transcript "$(own_tr "$1")" --uuid "$4" --reason "the user changed the stop"; }

case_begin "cc-ledger-record-row-and-accept" "bin/review-loop-upstream"
up_write_plans cl1
up_ledger_r1 cl1 "$FMT" "1|HIGH|$DT1"
up_report raw "$UP_ROOT/cl1.md" "1|HIGH|$DT1"
listed cl1 1 "$UP_ROOT/cl1.md"
ck "ledger: the open concern is listed with a real hash (precondition)" "0 1 yes" "$UP_RC $(up_rows "$UP_OUT") $(up_is_hash "$LH")"
cc_decide cl1 "$LID" "$LH" "$UUID_OK"
REC="$(rec_path cl1 1 "$LID")"
ck "ledger: decide course-correction exits 0" "0" "$UP_RC"
ck "ledger: the record file is written" "yes" "$(yn test -s "$REC")"
ck "ledger: the record starts with its header" "# Course correction record" "$(head -n 1 "$REC" 2>/dev/null | tr -d '\r')"
ck "ledger: the record quotes the user's correction verbatim" "yes" "$(yn grep -q -x -F -- "$CC_TEXT" "$REC")"
ck "ledger: decisions.tsv has one line" "1" "$(dec_lines cl1 "$FMT")"
ck "ledger: the 7th column is record=<path>" "record=$REC" "$(dec_col7 cl1)"
ck "ledger: the concern is closed through accept" "rejected" "$(up_state cl1 "$FMT" C1)"
ck_has "ledger: the closed row carries the accept label" "accepted(upstream-inconsistency)" "$(up_row cl1 "$FMT" C1)"
case_end

case_begin "cc-next-list-not-paused" "bin/lib/concern-ledger/upstream-tag.sh"
# A concern closed through the ledger is not listed again; prior_choice is checked on the fallback path (seen_prior).
up_write_plans fb
up_report test "$UP_ROOT/fb1.md" "1|HIGH|$DT1"
listed fb 1 "$UP_ROOT/fb1.md"
ck "fallback: listed with a real hash (precondition)" "yes" "$(up_is_hash "$LH")"
cc_decide fb "$LID" "$LH" "$UUID_OK"
ck "fallback: decide exits 0" "0" "$UP_RC"
up_ck_rec="$(dec_col7 fb)"
ck "fallback: the 7th column names the record file" "yes" "$(yn test -s "${up_ck_rec#record=}")"
up_report test "$UP_ROOT/fb2.md" "1|HIGH|$DT1"
listed fb 2 "$UP_ROOT/fb2.md"
ck "fallback round 2: the row carries prior_choice=course-correction" "0 course-correction" "$UP_RC $(up_col 9 "$UP_OUT")"
case_end

case_begin "accepted-lists-c-and-cc-not-a" "bin/review-loop-upstream"
up_write_plans ac
up_report test "$UP_ROOT/ac1.md" "1|HIGH|$DT1" "2|HIGH|$DT2" "3|HIGH|$(up_tag upstream-gap A intent "$UP_Q_LINE" "third defect")"
listed ac 1 "$UP_ROOT/ac1.md"
ck "accepted: three rows listed (precondition)" "3" "$(up_rows "$UP_OUT")"
AC_OUT="$UP_OUT"
up decide --session ac --format "$FMT" --id "$(col_of "$AC_OUT" 1 2)" --text-hash "$(col_of "$AC_OUT" 1 3)" --choice C --reason "reason-of-c"
up decide --session ac --format "$FMT" --id "$(col_of "$AC_OUT" 2 2)" --text-hash "$(col_of "$AC_OUT" 2 3)" --choice course-correction --transcript "$(own_tr ac)" --uuid "$UUID_OK" --reason "reason-of-cc"
ck "accepted: the course-correction decide exits 0 (precondition)" "0" "$UP_RC"
up decide --session ac --format "$FMT" --id "$(col_of "$AC_OUT" 3 2)" --text-hash "$(col_of "$AC_OUT" 3 3)" --choice A --reason "reason-of-a"
up accepted --session ac --format "$FMT"
ck "accepted: exits 0" "0" "$UP_RC"
ck_has "accepted: the C row is listed" "reason-of-c" "$UP_OUT"
ck_has "accepted: the course-correction row is listed" "reason-of-cc" "$UP_OUT"
ck_lacks "accepted: the A row is not listed" "reason-of-a" "$UP_OUT"
case_end

case_begin "cc-argument-errors-exit-2" "bin/review-loop-upstream"
up_write_plans ae
up_report test "$UP_ROOT/ae1.md" "1|HIGH|$DT1"
listed ae 1 "$UP_ROOT/ae1.md"
ck "args: listed with a real hash (precondition)" "yes" "$(up_is_hash "$LH")"
up decide --session ae --format "$FMT" --id "$LID" --text-hash "$LH" --choice course-correction --uuid "$UUID_OK" --reason "r"
ck "args: course-correction without --transcript exits 2" "2" "$UP_RC"
up decide --session ae --format "$FMT" --id "$LID" --text-hash "$LH" --choice course-correction --transcript "$TR" --reason "r"
ck "args: course-correction without --uuid exits 2" "2" "$UP_RC"
up decide --session ae --format "$FMT" --id "$LID" --text-hash "$LH" --choice C --transcript "$TR" --reason "r"
ck "args: --transcript with choice C exits 2" "2" "$UP_RC"
up decide --session ae --format "$FMT" --id "$LID" --text-hash "$LH" --choice A --uuid "$UUID_OK" --reason "r"
ck "args: --uuid with choice A exits 2" "2" "$UP_RC"
up decide --session ae --format "$FMT" --id "$LID" --text-hash "$LH" --choice B --transcript "$TR" --reason "r"
ck "args: --transcript with choice B exits 2" "2" "$UP_RC"
up decide --session ae --format "$FMT" --id "$LID" --text-hash "$LH" --choice course-correction --transcript "$TR" --uuid "${UUID_OK}"$'\n'"x" --reason "r"
ck "args: an LF in --uuid exits 2" "2" "$UP_RC"
up decide --session ae --format "$FMT" --id "$LID" --text-hash "$LH" --choice course-correction --transcript "$TR"$'\t'"x" --uuid "$UUID_OK" --reason "r"
ck "args: a tab in --transcript exits 2" "2" "$UP_RC"
ck "args: no decisions.tsv line is written" "0" "$(dec_lines ae "$FMT")"
ck "args: no record file is written" "0" "$(rec_count ae)"
case_end

case_begin "cc-unknown-uuid-exit-3" "bin/review-loop-upstream"
up_write_plans uu
up_report test "$UP_ROOT/uu1.md" "1|HIGH|$DT1"
listed uu 1 "$UP_ROOT/uu1.md"
ck "uuid: listed with a real hash (precondition)" "yes" "$(up_is_hash "$LH")"
cc_decide uu "$LID" "$LH" "$UUID_NONE"
ck "uuid: an unknown uuid exits 3" "3" "$UP_RC"
ck "uuid: no decisions.tsv line is written" "0" "$(dec_lines uu "$FMT")"
ck "uuid: no record file is left" "0" "$(rec_count uu)"
cc_decide uu "$LID" "$LH" "$UUID_OK"
ck "uuid: the same decide with a known uuid exits 0 (control)" "0" "$UP_RC"
case_end

case_begin "cc-extract-io-failure-exit-1" "bin/lib/review-loop-upstream/course-correction.sh"
# A directory squatting on the record path makes extract's rename fail (an IO error, not exit 3).
up_write_plans io
up_report test "$UP_ROOT/io1.md" "1|HIGH|$DT1"
listed io 1 "$UP_ROOT/io1.md"
ck "io: listed with a real hash (precondition)" "yes" "$(up_is_hash "$LH")"
IO_REC="$(rec_path io 1 "$LID")"
mkdir -p "$IO_REC"
cc_decide io "$LID" "$LH" "$UUID_OK"
ck "io: an extract IO failure makes decide exit 1" "1" "$UP_RC"
ck "io: no decisions.tsv line is written" "0" "$(dec_lines io "$FMT")"
ck "io: no record file (or tmp) is left" "0" "$(find "$(up_ctl io)" -type f -name "$FMT-course-correction-*" | awk 'END{print NR}')"
ck "io: the squatting directory stays empty" "" "$(ls -A "$IO_REC" 2>&1)"
case_end

case_begin "cc-failed-accept-rolls-back" "bin/review-loop-upstream"
for pre in absent present; do
  sid="rb-$pre"
  up_write_plans "$sid"
  up_ledger_r1 "$sid" "$FMT" "1|HIGH|$DT2"
  up_report raw "$UP_ROOT/$sid.md" "1|HIGH|$DT2"
  listed "$sid" 1 "$UP_ROOT/$sid.md"
  ck "rollback ($pre): C1 listed with a real hash (precondition)" "C1 yes" "$LID $(up_is_hash "$LH")"
  [ "$pre" = absent ] || up decide --session "$sid" --format "$FMT" --id C1 --text-hash "$LH" --choice A --reason "revise upstream first"
  D0="$(sum_of "$(dec_file "$sid" "$FMT")")"
  L="$(up_ledger "$sid" "$FMT")"
  awk -F'|' 'BEGIN{OFS="|"} $1=="C1"{$1="C7"} {print}' "$L" > "$L.new"
  mv "$L.new" "$L"
  cc_decide "$sid" C1 "$LH" "$UUID_OK"
  ck "rollback ($pre): a failed accept exits 1" "1" "$UP_RC"
  ck "rollback ($pre): decisions.tsv is byte-identical to before (or still absent)" "$D0" "$(sum_of "$(dec_file "$sid" "$FMT")")"
  ck "rollback ($pre): no record file is left" "0" "$(rec_count "$sid")"
done
case_end

case_begin "cc-then-a-clears-prior" "bin/lib/concern-ledger/upstream-tag.sh"
up_write_plans ca
up_report test "$UP_ROOT/ca1.md" "1|HIGH|$DT1"
listed ca 1 "$UP_ROOT/ca1.md"
cc_decide ca "$LID" "$LH" "$UUID_OK"
ck "then A: the course-correction decide exits 0 (precondition)" "0" "$UP_RC"
up decide --session ca --format "$FMT" --id "$LID" --text-hash "$LH" --choice A --reason "revise after all"
ck "then A: the A decide exits 0" "0" "$UP_RC"
listed ca 1 "$UP_ROOT/ca1.md"
ck "then A: the latest decision A leaves prior_choice empty" "0 1 " "$UP_RC $(up_rows "$UP_OUT") $(up_col 9 "$UP_OUT")"
case_end

case_begin "cc-foreign-transcript-refused" "bin/review-loop-upstream"
# security-scanner F2: a well-formed transcript holding the uuid is still refused unless it is the
# one `locate --session <sid>` resolves; the located one (locate's own stdout) is accepted.
up_write_plans ft
up_report test "$UP_ROOT/ft1.md" "1|HIGH|$DT1"
listed ft 1 "$UP_ROOT/ft1.md"
ck "foreign: listed with a real hash (precondition)" "yes" "$(up_is_hash "$LH")"
ck "foreign: the session has its own locatable transcript (precondition)" "yes" "$(yn test -s "$(own_tr ft)")"
OTHER_SID_TR="$(own_tr ft-other)"
# Same basename as the session's own transcript, another directory: a basename-only check passes it.
DECOY_TR="$UP_ROOT/decoy/ft.jsonl"
mkdir -p "$UP_ROOT/decoy"
cp "$(own_tr ft)" "$DECOY_TR"
for foreign in "$TR" "$OTHER_SID_TR" "$DECOY_TR"; do
  up decide --session ft --format "$FMT" --id "$LID" --text-hash "$LH" --choice course-correction --transcript "$foreign" --uuid "$UUID_OK" --reason "r"
  ck_nz "foreign: a transcript other than the session's ($(basename "$foreign")) is refused" "$UP_RC"
  ck "foreign: no decisions.tsv line is written ($(basename "$foreign"))" "0" "$(dec_lines ft "$FMT")"
  ck "foreign: no record file is written ($(basename "$foreign"))" "0" "$(rec_count ft)"
done
up_write_plans fn
up_report test "$UP_ROOT/fn1.md" "1|HIGH|$DT1"
listed fn 1 "$UP_ROOT/fn1.md"
FN_RC=0
node "$(np "$SCRIPT_CHECKOUT_ROOT")/bin/course-correction-record" locate --session fn >/dev/null 2>&1 || FN_RC=$?
ck "no own: locate finds no transcript for the session (precondition)" "3" "$FN_RC"
up decide --session fn --format "$FMT" --id "$LID" --text-hash "$LH" --choice course-correction --transcript "$TR" --uuid "$UUID_OK" --reason "r"
ck_nz "no own: with no locatable transcript, any --transcript is refused (fail-closed)" "$UP_RC"
ck "no own: no decisions.tsv line and no record file" "0 0" "$(dec_lines fn "$FMT") $(rec_count fn)"
up_write_plans fo
up_report test "$UP_ROOT/fo1.md" "1|HIGH|$DT1"
listed fo 1 "$UP_ROOT/fo1.md"
FO_OWN="$(own_tr fo)"
FO_LOC="$(node "$(np "$SCRIPT_CHECKOUT_ROOT")/bin/course-correction-record" locate --session fo)"
ck "own: locate resolves the session's own transcript (precondition)" "$(np "$FO_OWN")" "$(np "${FO_LOC//\\//}")"
up decide --session fo --format "$FMT" --id "$LID" --text-hash "$LH" --choice course-correction --transcript "$FO_LOC" --uuid "$UUID_OK" --reason "r"
ck "own: the session's located transcript is accepted (counterpart)" "0 1 1" "$UP_RC $(dec_lines fo "$FMT") $(rec_count fo)"
case_end

# security-scanner round 2: the --transcript string passes the own-transcript check by string
# normalization, but extract must not read the different file the string physically names.
FOREIGN_MARK="FOREIGN-MARKER-2814"
foreign_tr() { local c; c="$(cat "$TR")"; printf '%s\n' "${c//"$CC_TEXT"/"$FOREIGN_MARK not the own body"}" > "$1"; }
# node_names_foreign <path> — yes when node, reading the string as given, gets the foreign body.
node_names_foreign() { yn grep -q -F -- "$FOREIGN_MARK" <(node -e 'process.stdout.write(require("fs").readFileSync(process.argv[1],"utf8"))' "$1" 2>/dev/null); }
# cc_spoof_ck <sid> <label> <spoof> — refusal (no row, no record) or a record of the own body only.
cc_spoof_ck() {
  up_write_plans "$1"
  up_report test "$UP_ROOT/$1.md" "1|HIGH|$DT1"
  listed "$1" 1 "$UP_ROOT/$1.md"
  ck "$2: listed with a real hash (precondition)" "yes" "$(up_is_hash "$LH")"
  up decide --session "$1" --format "$FMT" --id "$LID" --text-hash "$LH" --choice course-correction --transcript "$3" --uuid "$UUID_OK" --reason "r"
  if [[ "$UP_RC" -ne 0 ]]; then
    ck "$2: refused as not the session's transcript (exit 2)" "2" "$UP_RC"
    ck_has "$2: refused with the own-transcript message" "is not the transcript of session" "$UP_ERR"
    ck "$2: refused, so no decisions.tsv line and no record file" "0 0" "$(dec_lines "$1" "$FMT") $(rec_count "$1")"
    return
  fi
  local rec; rec="$(rec_path "$1" 1 "$LID")"
  ck "$2: accepted, so one decisions.tsv line and one record file" "1 1" "$(dec_lines "$1" "$FMT") $(rec_count "$1")"
  ck "$2: accepted, so the 7th column is record=<path>" "record=$rec" "$(dec_col7 "$1")"
  ck "$2: accepted, so the record quotes the session's own correction" "yes" "$(yn grep -q -x -F -- "$CC_TEXT" "$rec")"
  ck "$2: accepted, so the record holds nothing of the physically named file" "no" "$(yn grep -q -F -- "$FOREIGN_MARK" "$rec")"
}

case_begin "cc-trailing-space-transcript-reads-own" "bin/lib/review-loop-upstream/course-correction.sh"
WS_OWN="$(own_tr ws)"
foreign_tr "$WS_OWN "
if [[ "$(node_names_foreign "$WS_OWN ")" == yes && "$(node_names_foreign "$WS_OWN")" == no ]]; then
  cc_spoof_ck ws "trailing space" "$WS_OWN "
else
  skip "trailing space: this host cannot make '<own> ' a file node reads apart from the own transcript"
fi
case_end

case_begin "cc-symlink-dotdot-transcript-reads-own" "bin/lib/review-loop-upstream/course-correction.sh"
SL_OWN="$(own_tr sl)"
SL_LNK="$(dirname "$SL_OWN")/lnk-sl"
mkdir -p "$UP_ROOT/other/sub"
foreign_tr "$UP_ROOT/other/sl.jsonl"
ln -s "$UP_ROOT/other/sub" "$SL_LNK" 2>/dev/null || true
SL_SPOOF="$SL_LNK/../$(basename "$SL_OWN")"
if [[ -L "$SL_LNK" && "$(node_names_foreign "$SL_SPOOF")" == yes ]]; then
  cc_spoof_ck sl "symlink .." "$SL_SPOOF"
else
  skip "symlink ..: no real symlink here, or this host resolves '..' lexically before the link"
fi
case_end

# security-scanner round 3: a --transcript value starting with `-` must reach the own-transcript
# check as data, never as a node option (--require preloads code, -v ends node with rc 0).
# cc_dash_ck <sid> <label> <value> — the session has its own transcript; decide is refused with rc 2.
cc_dash_ck() {
  own_tr "$1" >/dev/null
  up_write_plans "$1"
  up_report test "$UP_ROOT/$1.md" "1|HIGH|$DT1"
  listed "$1" 1 "$UP_ROOT/$1.md"
  ck "$2: listed with a real hash (precondition)" "yes" "$(up_is_hash "$LH")"
  up decide --session "$1" --format "$FMT" --id "$LID" --text-hash "$LH" --choice course-correction --transcript "$3" --uuid "$UUID_OK" --reason "r"
  ck "$2: refused as not the session's transcript (exit 2)" "2" "$UP_RC"
  ck_has "$2: refused with the own-transcript message" "is not the transcript of session" "$UP_ERR"
  ck "$2: no decisions.tsv line and no record file" "0 0" "$(dec_lines "$1" "$FMT") $(rec_count "$1")"
}

case_begin "cc-dash-require-transcript-not-executed" "bin/lib/review-loop-upstream/course-correction.sh"
EVIL_DIR="$UP_ROOT/evil"
mkdir -p "$EVIL_DIR"
printf '%s\n' 'require("fs").writeFileSync(require("path").join(__dirname, "marker"), "ran");' > "$EVIL_DIR/evil.js"
EVIL_JS="$(np "$EVIL_DIR/evil.js")"
node --require="$EVIL_JS" -e '' >/dev/null 2>&1
ck "dash --require: the evil.js probe is live (precondition)" "yes" "$(yn test -e "$EVIL_DIR/marker")"
rm -f "$EVIL_DIR/marker"
cc_dash_ck dr "dash --require" "--require=$EVIL_JS"
ck "dash --require: the --transcript value is not preloaded by node (no marker)" "no" "$(yn test -e "$EVIL_DIR/marker")"
case_end

case_begin "cc-dash-v-transcript-refused" "bin/lib/review-loop-upstream/course-correction.sh"
# The regression check is cc_dash_ck: without `--`, node -v exits 0 and decide does not exit 2 with the refusal.
cc_dash_ck dv "dash -v" "-v"
ck_lacks "dash -v: no node version string in output (auxiliary; rc 2 above is the real check)" "$(node -v)" "$UP_OUT$UP_ERR"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
