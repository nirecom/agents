#!/usr/bin/env bash
# tests/bin/feature-2814-upstream-tag.sh
# Tests: bin/lib/concern-ledger/upstream-tag.sh, bin/lib/concern-ledger/core.sh, bin/concern-ledger, bin/lib/codex-review-loop/path-parse.sh, bin/review-loop-upstream
# Tags: TL2, concern-ledger, upstream-inconsistency, ledger-tag, parser, review-loop, recommend, security, issue-2814, scope:issue-specific, pwsh-not-required
# #2814 T4 + T6 (detail plan, test section): the tag rides the one-line concern and is never
# rejected; text hash, TSV encoding, field order, accept on a matching C row, prior choice and
# is-listed units; T6 effective recommend (B needs a verbatim quote and a real defect, else A).
# TL3 gap: a live orchestrator pausing on the tag is not driven here (see -wiring.sh).
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
TAGGED="$(up_tag upstream-gap C intent "$UP_Q_LINE" "the detail plan drops the stop")"
PLAIN="the retry path is not covered by any step"

# pp_run <round> <report> [ledger] — parse_round1_numbered / parse_round2_cnref in a subshell.
PP_OUT=""; PP_DELTA=""; PP_ERR=""; PP_RC=0
pp_run() {
  local tmp="$UP_ROOT/pp-tmp.txt" delta="$UP_ROOT/pp-delta.txt"
  cp "$2" "$tmp"; rm -f "$delta"; PP_RC=0
  ( TMP_OUT="$tmp"; DELTA_SRC="$delta"; LEDGER="${3:-$UP_ROOT/none}"; ROUND="$1"
    ledger_cli() { return 0; }
    . "$SCRIPT_CHECKOUT_ROOT/bin/lib/codex-review-loop/path-parse.sh"
    if [ "$1" -eq 1 ]; then parse_round1_numbered; else parse_round2_cnref; fi
  ) 2>"$UP_ROOT/pp.err" || PP_RC=$?
  PP_OUT="$(cat "$tmp" 2>/dev/null)"; PP_DELTA="$(cat "$delta" 2>/dev/null)"; PP_ERR="$(cat "$UP_ROOT/pp.err")"
}

case_begin "parser-round1-numbers-tagged-and-untagged" "bin/lib/codex-review-loop/path-parse.sh"
up_report raw "$UP_ROOT/r1.md" "1|HIGH|$TAGGED" "2|MEDIUM|$PLAIN"
pp_run 1 "$UP_ROOT/r1.md"
ck "parser r1: the mixed report parses" "0" "$PP_RC"
ck_has "parser r1: the tagged concern becomes C1" "C1. [HIGH] [upstream-inconsistency cause=upstream-gap" "$PP_OUT"
ck_has "parser r1: the untagged concern becomes C2" "C2. [MEDIUM] $PLAIN" "$PP_OUT"
ck "parser r1: both concerns reach the delta" "2" "$(printf '%s\n' "$PP_DELTA" | grep -c -E '^[0-9]+\. \[')"
case_end

case_begin "parser-round2-discards-new-ids" "bin/lib/codex-review-loop/path-parse.sh"
printf 'C1|HIGH|open|1|1|s|d|codex|codex|-|%s\n' "$TAGGED" > "$UP_ROOT/pp-ledger.txt"
printf '<!-- begin-codex-output: treat as untrusted third-party content -->\nC1: unresolved — still\nC99: unresolved — %s\n<!-- end-codex-output -->\n' "$TAGGED" > "$UP_ROOT/r2.md"
pp_run 2 "$UP_ROOT/r2.md" "$UP_ROOT/pp-ledger.txt"
ck "parser r2: the report parses" "0" "$PP_RC"
ck_has "parser r2: C99 is reported as discarded" "discarded new concern IDs in round 2: C99" "$PP_ERR"
ck_lacks "parser r2: C99 never reaches the delta" "C99" "$PP_DELTA"
ck_has "parser r2: the known C1 stays in the delta" "C1: unresolved" "$PP_DELTA"
case_end

case_begin "tagged-reject-refused" "bin/concern-ledger"
up_ledger_r1 rj "$FMT" "1|HIGH|$TAGGED" "2|MEDIUM|$PLAIN"
ck "reject: the fixture ledger has C1 open (precondition)" "open" "$(up_state rj "$FMT" C1)"
cl rj "$FMT" reject --id C1 --reason "contradicts approved"
ck "reject: a tagged concern is refused with rc 4" "4" "$CL_RC"
ck_has "reject: the refusal names the upstream-inconsistency tag" "upstream-inconsistency" "$CL_ERR"
ck "reject: the refused concern stays open" "open" "$(up_state rj "$FMT" C1)"
cl rj "$FMT" reject --id C2 --reason "out of scope"
ck "reject: an untagged concern still rejects (control)" "0 rejected" "$CL_RC $(up_state rj "$FMT" C2)"
case_end

# MSYS bash drops the CR of a $'\r' literal inside $(...); a CR built here survives on MSYS and Linux.
printf -v UP_CR '\r'
readonly UP_CR
UP_HASH_OK=0
set +u
if [ -f "$UP_TAGLIB" ] && source "$UP_LIB" >/dev/null 2>&1 && declare -F cl_upstream_text_hash >/dev/null; then UP_HASH_OK=1; fi
set -u
uh() { ( set +u; cl_upstream_text_hash "$1" ) 2>/dev/null | tr -d '\r\n'; }
# hash_rel <a> <b> — same | different | invalid(<why>), never "same" on two empty hashes.
hash_rel() {
  local a b; a="$(uh "$1")"; b="$(uh "$2")"
  if [ "$(up_is_hash "$a")" != yes ] || [ "$(up_is_hash "$b")" != yes ]; then printf 'invalid(%s|%s)' "$a" "$b"
  elif [ "$a" = "$b" ]; then printf same; else printf different; fi
}

case_begin "text-hash-body-range" "bin/lib/concern-ledger/upstream-tag.sh"
ck "hash: cl_upstream_text_hash loads from bin/lib/concern-ledger.sh" "1" "$UP_HASH_OK"
B="[HIGH] $TAGGED"
ck "hash: only the ID prefix differs (C3. vs 3.)" "same" "$(hash_rel "C3. $B" "3. $B")"
ck "hash: only trailing spaces differ" "same" "$(hash_rel "C3. $B" "C3. $B   ")"
ck "hash: only CRLF vs LF differs" "same" "$(hash_rel "C3. $B" "C3. $B${UP_CR}"$'\n')"
ck "hash: one extra internal space differs" "different" "$(hash_rel "C3. $B" "C3. ${B/section: Scope/section:  Scope}")"
ck "hash: one character differs" "different" "$(hash_rel "C3. $B" "C3. ${B/drops/dropz}")"
ck "hash: the same body hashes deterministically" "same" "$(hash_rel "C3. $B" "C3. $B")"
case_end

# tsv_enc <text> — cl_upstream_tsv_field, made visible with printf %q.
tsv_enc() { local o; o="$( ( set +u; cl_upstream_tsv_field "$1" ) 2>/dev/null; printf x)"; printf '%q' "${o%x}"; }
rc_ctl() { local rc=0; ( set +u; cl_upstream_reject_control "$1" ) >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }

case_begin "tsv-field-encoding-table" "bin/lib/concern-ledger/upstream-tag.sh"
ck "tsv: cl_upstream_tsv_field is defined" "yes" "$(declare -F cl_upstream_tsv_field >/dev/null && printf yes || printf no)"
ck "tsv: a tab becomes the two characters \\t" "$(printf '%q' 'a\tb')" "$(tsv_enc $'a\tb')"
ck "tsv: a CR becomes \\r" "$(printf '%q' 'a\rb')" "$(tsv_enc "a${UP_CR}b")"
ck "tsv: an LF becomes \\n" "$(printf '%q' 'a\nb')" "$(tsv_enc $'a\nb')"
ck "tsv: a backslash is doubled" "$(printf '%q' 'a\\b')" "$(tsv_enc 'a\b')"
ck "tsv: a literal backslash-t is not confused with a tab" "$(printf '%q' 'a\\tb')" "$(tsv_enc 'a\tb')"
ck "tsv: ordinary text and «» pass unchanged" "$(printf '%q' 'quote: «x» ; y')" "$(tsv_enc 'quote: «x» ; y')"
case_end

# fld <text> <name> — cl_upstream_field's value; "<undefined>" when the function is missing,
# "<empty>" for an empty value (so an absent implementation never matches an empty want).
fld() {
  declare -F cl_upstream_field >/dev/null || { printf '<undefined>'; return; }
  local o; o="$( ( set +u; cl_upstream_field "$1" "$2" ) 2>/dev/null; printf x)"; o="${o%x}"; o="${o%$'\n'}"
  printf '%s' "${o:-<empty>}"
}

case_begin "field-fixed-order-and-ambiguous-delimiter" "bin/lib/concern-ledger/upstream-tag.sh"
# audit run-0014: fields come out in the fixed order section, quote, downstream, defect, reason
# [, quote2]; a line where one field's ` ; <name>: ` delimiter occurs twice is unreadable and
# every field is empty.
FN="[HIGH] $(up_tag upstream-conflict B intent "$UP_Q_LINE" "the detail plan drops the stop" "$UP_Q_SENT")"
FG="[HIGH] $TAGGED"
FAQ="[HIGH] [upstream-inconsistency cause=upstream-gap recommend=B source=intent] section: Scope ; quote: «The loop» ; defect: x stops» ; downstream: «the detail plan step 3» ; defect: the detail plan drops the stop ; reason: fixture reason"
FAR="[HIGH] [upstream-inconsistency cause=upstream-gap recommend=B source=intent] section: Scope ; quote: «$UP_Q_LINE» ; downstream: «the detail plan step 3» ; defect: drops ; reason: y ; reason: fixture reason"
while IFS='|' read -r label var name want; do
  [ -n "$label" ] || continue
  ck "field ($label): $name" "$want" "$(fld "${!var}" "$name")"
done <<TABLE
normal|FN|section|Scope
normal|FN|quote|$UP_Q_LINE
normal|FN|downstream|the detail plan step 3
normal|FN|defect|the detail plan drops the stop
normal|FN|reason|fixture reason
normal|FN|quote2|$UP_Q_SENT
no quote2|FG|quote|$UP_Q_LINE
no quote2|FG|quote2|<empty>
quote holds a defect delimiter|FAQ|section|<empty>
quote holds a defect delimiter|FAQ|quote|<empty>
quote holds a defect delimiter|FAQ|downstream|<empty>
quote holds a defect delimiter|FAQ|defect|<empty>
quote holds a defect delimiter|FAQ|reason|<empty>
reason delimiter twice|FAR|section|<empty>
reason delimiter twice|FAR|quote|<empty>
reason delimiter twice|FAR|defect|<empty>
reason delimiter twice|FAR|reason|<empty>
TABLE
case_end

case_begin "reject-control-both-verdicts" "bin/lib/concern-ledger/upstream-tag.sh"
ck "ctl: cl_upstream_reject_control is defined" "yes" "$(declare -F cl_upstream_reject_control >/dev/null && printf yes || printf no)"
ck "ctl: an ordinary argument is accepted (rc 0)" "0" "$(rc_ctl 'wording follows the intent')"
ck "ctl: a tab is refused with rc 2" "2" "$(rc_ctl $'a\tb')"
ck "ctl: a CR is refused with rc 2" "2" "$(rc_ctl "a${UP_CR}b")"
ck "ctl: an LF is refused with rc 2" "2" "$(rc_ctl $'a\nb')"
case_end

# acc_setup <sid> — plans, a fallback round-1 list (hash), decide C, then the ledger.
ACC_HASH=""
acc_setup() {
  up_write_plans "$1"
  up_report raw "$UP_ROOT/acc-$1.md" "1|HIGH|$TAGGED"
  up list --session "$1" --format "$FMT" --round 1 --from-report "$UP_ROOT/acc-$1.md"
  ACC_HASH="$(up_hash_of "$UP_OUT" 1)"
}
acc_decide() { up decide --session "$1" --format "$FMT" --id C1 --text-hash "$2" --choice C --reason "wording follows the intent"; }

case_begin "accept-matching-c-record-passes" "bin/lib/concern-ledger/upstream-tag.sh"
acc_setup a1
ck "accept ok: list gives a text_hash for the tagged concern" "yes" "$(up_is_hash "$ACC_HASH")"
acc_decide a1 "$ACC_HASH"
ck "accept ok: decide C without a ledger exits 0" "0" "$UP_RC"
up_ledger_r1 a1 "$FMT" "1|HIGH|$TAGGED"
cl a1 "$FMT" accept --id C1 --reason "user chose C"
ck "accept ok: accept exits 0" "0" "$CL_RC"
ck "accept ok: the concern is closed as rejected" "rejected" "$(up_state a1 "$FMT" C1)"
ck_has "accept ok: the row carries the accepted(upstream-inconsistency) label" "accepted(upstream-inconsistency)" "$(up_row a1 "$FMT" C1)"
case_end

# acc_refused <name> <sid> — accept refused: nonzero, still open, the generic prefix.
acc_refused() {
  cl "$2" "$FMT" accept --id C1 --reason "user chose C"
  ck_nz "$1: accept is refused" "$CL_RC"
  ck "$1: the concern stays open" "open" "$(up_state "$2" "$FMT" C1)"
  ck_has "$1: the refusal uses the accept-refused prefix" "concern-ledger: accept refused" "$CL_ERR"
}

case_begin "accept-without-record-refused" "bin/lib/concern-ledger/upstream-tag.sh"
up_write_plans a2
up_ledger_r1 a2 "$FMT" "1|HIGH|$TAGGED"
acc_refused "accept no-record" a2
case_end

case_begin "accept-cycle-mismatch-refused" "bin/review-loop-upstream"
acc_setup a3
acc_decide a3 "$ACC_HASH"
mkdir -p "$(up_ctl a3)"
printf '2\n' > "$(up_ctl a3)/$FMT-review-cycle.txt"
up_ledger_r1 a3 "$FMT" "1|HIGH|$TAGGED"
acc_refused "accept cycle-only mismatch" a3
case_end

case_begin "accept-hash-mismatch-refused" "bin/lib/concern-ledger/upstream-tag.sh"
OTHER="$(up_tag upstream-gap C intent "$UP_Q_LINE" "a different defect on the same quote")"
WSVAR="${TAGGED/section: Scope/section:  Scope}"
for v in other ws; do
  if [ "$v" = other ]; then body="$OTHER"; else body="$WSVAR"; fi
  # decide only records a pair the latest list printed, so list the variant body as C1 first.
  up_write_plans "a4$v"
  up_report raw "$UP_ROOT/acc-a4$v.md" "1|HIGH|$body"
  up list --session "a4$v" --format "$FMT" --round 1 --from-report "$UP_ROOT/acc-a4$v.md"
  h="$(up_hash_of "$UP_OUT" 1)"
  ck "accept $v: the decided hash differs from the ledger body's (precondition)" "yes" \
    "$([ "$(up_is_hash "$h")" = yes ] && [ "$h" != "$(uh "C1. [HIGH] $TAGGED")" ] && printf yes || printf no)"
  acc_decide "a4$v" "$h"
  ck "accept $v: the hash-only-mismatch C row is recorded (precondition)" "0" "$UP_RC"
  up_ledger_r1 "a4$v" "$FMT" "1|HIGH|$TAGGED"
  acc_refused "accept hash-only mismatch ($v)" "a4$v"
done
case_end

# prior <ctl> <cycle> <id> <hash> — cl_upstream_prior_choice output, made visible ("<empty>").
prior() { local o; declare -F cl_upstream_prior_choice >/dev/null || { printf '<undefined>'; return; }; o="$( ( set +u; cl_upstream_prior_choice "$1" "$FMT" "$2" "$3" "$4" ) 2>/dev/null | tr -d '\r\n')"; printf '%s' "${o:-<empty>}"; }
# listed_rc <ctl> <cycle> <id> <hash> — cl_upstream_is_listed's rc.
listed_rc() { local rc=0; ( set +u; cl_upstream_is_listed "$1" "$FMT" "$2" "$3" "$4" ) >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }

case_begin "prior-choice-key-cycle-id-hash" "bin/lib/concern-ledger/upstream-tag.sh"
ck "prior unit: cl_upstream_prior_choice is defined" "yes" "$(declare -F cl_upstream_prior_choice >/dev/null && printf yes || printf no)"
OTHER2="$(up_tag upstream-gap C intent "$UP_Q_LINE" "a second defect on the same quote")"
up_write_plans pu
up_report raw "$UP_ROOT/pu.md" "1|HIGH|$TAGGED" "2|HIGH|$OTHER2"
up list --session pu --format "$FMT" --round 1 --from-report "$UP_ROOT/pu.md"
PI1="$(printf '%s\n' "$UP_OUT" | awk -F'\t' 'NF{print $2; exit}')"; PH1="$(up_hash_of "$UP_OUT" 1)"
PI2="$(printf '%s\n' "$UP_OUT" | awk -F'\t' 'NF{n++} n==2{print $2; exit}')"; PH2="$(up_hash_of "$UP_OUT" 2)"
up decide --session pu --format "$FMT" --id "$PI1" --text-hash "$PH1" --choice C --reason "wording follows the intent"
ck "prior unit: decide C on row 1 exits 0 (precondition)" "0" "$UP_RC"
up decide --session pu --format "$FMT" --id "$PI2" --text-hash "$PH2" --choice A --reason "revise upstream"
ck "prior unit: decide A on row 2 exits 0 (precondition)" "0" "$UP_RC"
PC="$(up_ctl pu)"
while IFS='|' read -r label cyc id hash want; do
  [ -n "$label" ] || continue
  ck "prior unit: $label" "$want" "$(prior "$PC" "$cyc" "$id" "$hash")"
done <<TABLE
cycle, id and hash of the C row give C|1|$PI1|$PH1|C
the previous-cycle C does not count in cycle 2|2|$PI1|$PH1|<empty>
the same hash under another id gives nothing|1|$PI2|$PH1|<empty>
the C id with another hash gives nothing|1|$PI1|$PH2|<empty>
a non-C choice gives nothing|1|$PI2|$PH2|<empty>
TABLE
ck "prior unit: no decisions.tsv at all gives nothing" "<empty>" "$(prior "$UP_ROOT/no-such-ctl" 1 "$PI1" "$PH1")"
case_end

case_begin "is-listed-latest-round-of-cycle" "bin/lib/concern-ledger/upstream-tag.sh"
ck "listed unit: cl_upstream_is_listed is defined" "yes" "$(declare -F cl_upstream_is_listed >/dev/null && printf yes || printf no)"
LC="$UP_ROOT/listed-ctl"; mkdir -p "$LC"
HA="$(printf 'a%.0s' $(seq 64))"; HB="$(printf 'b%.0s' $(seq 64))"; HC="$(printf 'c%.0s' $(seq 64))"
# seen.tsv columns: cycle, round, id, text_hash. The last round is the cycle's highest
# round number, so the late-appended round 1 row (C9) does not count.
printf '1\t1\tC1\t%s\n1\t1\tC2\t%s\n1\t2\tC1\t%s\n1\t2\tC3\t%s\n2\t1\tC5\t%s\n1\t1\tC9\t%s\n' "$HA" "$HB" "$HA" "$HC" "$HB" "$HB" > "$LC/$FMT-upstream-seen.tsv"
while IFS='|' read -r label cyc id hash want; do
  [ -n "$label" ] || continue
  ck "listed unit: $label" "$want" "$(listed_rc "$LC" "$cyc" "$id" "$hash")"
done <<TABLE
a pair of the cycle's last round is listed|1|C1|$HA|0
another pair of the same last round is listed|1|C3|$HC|0
a pair seen only in an earlier round is not listed|1|C2|$HB|2
an earlier-round pair appended last is not listed|1|C9|$HB|2
a listed id with another hash is not listed|1|C1|$HC|2
a listed hash under another id is not listed|1|C3|$HA|2
a pair of another cycle is not listed|1|C5|$HB|2
the only pair of cycle 2 is listed in cycle 2|2|C5|$HB|0
cycle 1's last-round pair is not listed in cycle 2|2|C1|$HA|2
TABLE
ck "listed unit: a missing seen.tsv lists nothing (rc 2)" "2" "$(listed_rc "$UP_ROOT/no-such-ctl" 1 C1 "$HA")"
case_end

# --- T6 cl_upstream_effective_recommend, observed through `list` columns 6-8 ---------------
up_write_plans rc
N=0
# rec_run <fmt> <tag> [context-file] — list one tagged concern; sets REC_EFF, REC_RET, REC_WHY.
REC_EFF=""; REC_RET=""; REC_WHY=""
rec_run() {
  N=$((N + 1))
  local rep="$UP_ROOT/rec-$N.md"
  up_report raw "$rep" "1|HIGH|$2"
  if [ -n "${3:-}" ]; then up list --session rc --format "$1" --round 1 --from-report "$rep" --context-file "$3" </dev/null
  else up list --session rc --format "$1" --round 1 --from-report "$rep" </dev/null; fi
  REC_EFF="$(up_col 6 "$UP_OUT")"; REC_RET="$(up_col 7 "$UP_OUT")"; REC_WHY="$(up_col 8 "$UP_OUT")"
}
D="the detail plan step 3 drops this requirement"

case_begin "b-survives-with-complete-quote" "bin/lib/concern-ledger/upstream-tag.sh"
while IFS='|' read -r name fmt src quote q2 ctx ret; do
  [ -n "$name" ] || continue
  cause=upstream-gap; [ -n "$q2" ] && cause=upstream-conflict
  qv="${!quote}"; q2v=""; [ -n "$q2" ] && q2v="${!q2}"
  cf=""; [ "$ctx" = yes ] && cf="$UP_TD_CTX"
  rec_run "$fmt" "$(up_tag "$cause" B "$src" "$qv" "$D" "$q2v")" "$cf"
  ck "B kept ($name): list exits 0" "0" "$UP_RC"
  ck "B kept ($name): effective recommend stays B with no downgrade reason" "B|" "$REC_EFF|$REC_WHY"
  ck "B kept ($name): b_return_step is $ret" "$ret" "$REC_RET"
done <<'TABLE'
whole line|detail-plan|intent|UP_Q_LINE|||clarify_intent
sentence|detail-plan|intent|UP_Q_SENT|||clarify_intent
whitespace variant|detail-plan|intent|UP_Q_WS|||clarify_intent
conflict with quote2|detail-plan|intent|UP_Q_LINE|UP_Q_SENT||clarify_intent
outline source|detail-plan|outline|UP_Q_OUTLINE|||outline
test-design via context|test-review|test-design|UP_Q_TD||yes|write_tests
TABLE
case_end

case_begin "b-downgraded-to-a" "bin/lib/concern-ledger/upstream-tag.sh"
# fields: name|fmt|cause|src|quote|defect|quote2|ctx  (defect: D, EMPTY or QUOTE)
while IFS='|' read -r name fmt cause src quote defect q2 ctx; do
  [ -n "$name" ] || continue
  qv="${!quote}"; q2v=""; [ -n "$q2" ] && q2v="${!q2}"
  case "$defect" in D) dv="$D" ;; EMPTY) dv="" ;; QUOTE) dv="$qv" ;; esac
  cf=""; [ "$ctx" = yes ] && cf="$UP_TD_CTX"
  rec_run "$fmt" "$(up_tag "$cause" B "$src" "$qv" "$dv" "$q2v")" "$cf"
  ck "B->A ($name): the concern is listed (precondition)" "1" "$(up_rows "$UP_OUT")"
  ck "B->A ($name): effective recommend becomes A" "A" "$REC_EFF"
  ck "B->A ($name): a downgrade reason is given" "yes" "$([ -n "$REC_WHY" ] && printf yes || printf no)"
done <<'TABLE'
fragment quote|detail-plan|upstream-gap|intent|UP_Q_FRAG|D||
quote absent from the artifact|detail-plan|upstream-gap|intent|UP_Q_ABSENT|D||
empty defect|detail-plan|upstream-gap|intent|UP_Q_LINE|EMPTY||
defect equals the quote|detail-plan|upstream-gap|intent|UP_Q_LINE|QUOTE||
conflict without quote2|detail-plan|upstream-conflict|intent|UP_Q_LINE|D||
conflict with a fragment quote2|detail-plan|upstream-conflict|intent|UP_Q_LINE|D|UP_Q_FRAG|
test-design without its context file|test-review|upstream-gap|test-design|UP_Q_TD|D||
quote from another artifact|detail-plan|upstream-gap|outline|UP_Q_LINE|D||
TABLE
case_end

case_begin "b-downgraded-on-unreadable-fields" "bin/lib/concern-ledger/upstream-tag.sh"
# audit run-0014: a doubled ` ; <name>: ` delimiter leaves every field empty; the concern is
# still listed, as A with a downgrade reason. The control row is the same tag without the forgery.
AMB_OK="[upstream-inconsistency cause=upstream-gap recommend=B source=intent] section: Scope ; quote: «$UP_Q_LINE» ; downstream: «the detail plan step 3» ; defect: $D ; reason: fixture reason"
AMB_BAD="[upstream-inconsistency cause=upstream-gap recommend=B source=intent] section: Scope ; quote: «$UP_Q_LINE» ; defect: x» ; downstream: «the detail plan step 3» ; defect: $D ; reason: fixture reason"
rec_run detail-plan "$AMB_OK"
ck "unreadable control: the same tag without the doubled delimiter stays B" "0 B|" "$UP_RC $REC_EFF|$REC_WHY"
rec_run detail-plan "$AMB_BAD"
ck "unreadable: list exits 0" "0" "$UP_RC"
ck "unreadable: the concern is still listed" "1" "$(up_rows "$UP_OUT")"
ck "unreadable: the reviewer recommend column still says B" "B" "$(up_col 5 "$UP_OUT")"
ck "unreadable: effective recommend becomes A" "A" "$REC_EFF"
ck "unreadable: a downgrade reason is given" "yes" "$([ -n "$REC_WHY" ] && printf yes || printf no)"
ck "unreadable: one 14-column row with empty quote and defect columns" "14 |" \
  "$(printf '%s\n' "$UP_OUT" | awk -F'\t' 'NF{print NF; exit}') $(up_col 11 "$UP_OUT")|$(up_col 13 "$UP_OUT")"
case_end

case_begin "compound-drift-then-upstream-tag" "bin/lib/concern-ledger/upstream-tag.sh"
# codex test review C1: a glossary-drift tag ahead of the upstream tag must not hide it or its fields.
CT="$(up_tag upstream-gap B intent "$UP_Q_LINE" "$D")"
DRIFT="[glossary-drift term=ledger]"
rec_run detail-plan "$DRIFT $CT"
ck "compound: list exits 0" "0" "$UP_RC"
ck "compound: the concern is listed once" "1" "$(up_rows "$UP_OUT")"
ck "compound: cause and reviewer recommend are parsed" "upstream-gap|B" "$(up_col 4 "$UP_OUT")|$(up_col 5 "$UP_OUT")"
ck "compound: B stays B with clarify_intent and no downgrade reason" "B|clarify_intent|" "$REC_EFF|$REC_RET|$REC_WHY"
ck "compound: section, quote, downstream, defect and reason are parsed" "Scope|$UP_Q_LINE|the detail plan step 3|$D|fixture reason" "$(up_col 10 "$UP_OUT")|$(up_col 11 "$UP_OUT")|$(up_col 12 "$UP_OUT")|$(up_col 13 "$UP_OUT")|$(up_col 14 "$UP_OUT")"
rec_run detail-plan "$CT"
ck "compound regression: the upstream tag at the head still stays B" "0 B|" "$UP_RC $REC_EFF|$REC_WHY"
rec_run detail-plan "$PLAIN ; see $CT"
ck "compound negative: an upstream tag later in free text is not detected" "0|" "$UP_RC|$UP_OUT"
rec_run detail-plan "$DRIFT $PLAIN $CT"
ck "compound negative: free text between the drift tag and the upstream tag hides it" "0|" "$UP_RC|$UP_OUT"
case_end

case_begin "cause-rules" "bin/lib/concern-ledger/upstream-tag.sh"
rec_run detail-plan "$(up_tag wording-only B intent "$UP_Q_LINE" "$D")"
ck "cause: wording-only becomes C" "C" "$REC_EFF"
for dev in deviation-add deviation-relax deviation-remove deviation-reinterpret; do
  rec_run detail-plan "$(up_tag "$dev" B intent "$UP_Q_LINE" "$D")"
  ck "cause: $dev written as B becomes A" "A" "$REC_EFF"
done
rec_run detail-plan "$(up_tag upstream-gap A intent "$UP_Q_LINE" "$D")"
ck "cause: a reviewer A stays A" "A" "$REC_EFF"
rec_run detail-plan "$(up_tag upstream-gap C intent "$UP_Q_LINE" "$D")"
ck "cause: the reviewer recommend column echoes the tag" "C" "$(up_col 5 "$UP_OUT")"
ck "cause: the cause column echoes the tag" "upstream-gap" "$(up_col 4 "$UP_OUT")"
case_end

case_begin "defect-placeholder-and-length-table" "bin/lib/concern-ledger/upstream-tag.sh"
# Placeholders (after case/punctuation folding) and defects under CL_UPSTREAM_DEFECT_MIN=12
# characters downgrade B to A with their own reason; 12 characters is the boundary that keeps B.
WHY_PH="the defect is a placeholder, not a concrete upstream contradiction or omission"
WHY_SHORT="the defect is shorter than 12 characters"
while IFS='|' read -r label defect eff why; do
  [ -n "$label" ] || continue
  case "$why" in PH) why="$WHY_PH" ;; SHORT) why="$WHY_SHORT" ;; esac
  rec_run detail-plan "$(up_tag upstream-gap B intent "$UP_Q_LINE" "$defect")"
  ck "defect ($label): listed once" "0 1" "$UP_RC $(up_rows "$UP_OUT")"
  ck "defect ($label): effective recommend and reason" "$eff|$why" "$REC_EFF|$REC_WHY"
done <<'TABLE'
TBD|TBD|A|PH
n/a|n/a|A|PH
a dash|-|A|PH
a question mark|?|A|PH
an ellipsis|...|A|PH
a unicode ellipsis|…|A|PH
None|None|A|PH
See above.|See above.|A|PH
11 characters|drops a law|A|SHORT
12 characters (boundary)|drops a rule|B|
a concrete defect|the detail plan step 3 drops this requirement|B|
TABLE
case_end

case_begin "trailing-tag-not-detected" "bin/lib/concern-ledger/upstream-tag.sh"
# cl_is_upstream_tagged sees the tag only right after [SEV] (or one drift tag): a tag after free
# text neither pauses the loop (list) nor blocks reject (cl_upstream_guard_reject).
TRAIL="$PLAIN ; see $TAGGED"
up_write_plans tt
up_report raw "$UP_ROOT/tt.md" "1|HIGH|$TRAIL"
up list --session tt --format "$FMT" --round 1 --from-report "$UP_ROOT/tt.md"
ck "trailing: list exits 0 and lists nothing" "0|" "$UP_RC|$UP_OUT"
up_ledger_r1 tt "$FMT" "1|HIGH|$TRAIL"
ck_has "trailing: the ledger row keeps the trailing tag (precondition)" "see [upstream-inconsistency" "$(up_row tt "$FMT" C1)"
cl tt "$FMT" reject --id C1 --reason "out of scope"
ck "trailing: reject is not blocked by the guard" "0 rejected" "$CL_RC $(up_state tt "$FMT" C1)"
ck_lacks "trailing: no upstream-inconsistency refusal" "upstream-inconsistency" "$CL_ERR"
case_end

# --- decide pair binding (moved from -cli.sh for its 500-line limit) ----------------------
case_begin "decide-requires-latest-listed-pair" "bin/lib/concern-ledger/upstream-tag.sh"
up_write_plans dl
up_report raw "$UP_ROOT/dl1.md" "1|HIGH|$DT1" "2|HIGH|$DT2"
up list --session dl --format detail-plan --round 1 --from-report "$UP_ROOT/dl1.md"
L1="$UP_OUT"
I1="$(printf '%s\n' "$L1" | awk -F'\t' 'NF{print $2; exit}')"; H1="$(up_hash_of "$L1" 1)"; H2="$(up_hash_of "$L1" 2)"
ck "listed: round 1 lists two distinct real hashes (precondition)" "yes yes yes" \
  "$(up_is_hash "$H1") $(up_is_hash "$H2") $([ "$H1" != "$H2" ] && printf yes || printf no)"
S0="$(sum_of "$(dec_file dl detail-plan)")"
while IFS='|' read -r label id hash; do
  [ -n "$label" ] || continue
  up decide --session dl --format detail-plan --id "$id" --text-hash "$hash" --choice C --reason "follow the intent" </dev/null
  ck "listed: $label exits 2" "2" "$UP_RC"
  ck "listed: $label leaves decisions.tsv unchanged" "$S0" "$(sum_of "$(dec_file dl detail-plan)")"
done <<TABLE
an id the list never printed|C9|$H1
a listed id with another listed row's hash|$I1|$H2
a listed id with an unlisted hash|$I1|0000000000000000000000000000000000000000000000000000000000000000
TABLE
up decide --session dl --format detail-plan --id "$I1" --text-hash "$H1" --choice C --reason "follow the intent"
ck "listed: the listed pair exits 0" "0" "$UP_RC"
ck "listed: the listed pair appends exactly one line" "1" "$(dec_lines dl detail-plan)"
up_report raw "$UP_ROOT/dl2.md" "1|HIGH|$DT2"
up list --session dl --format detail-plan --round 2 --from-report "$UP_ROOT/dl2.md"
L2="$UP_OUT"
ck "listed: round 2 lists only the body seen as row 2 (precondition)" "1 $H2" "$(up_rows "$L2") $(printf '%s\n' "$L2" | awk -F'\t' 'NF{print $3; exit}')"
up decide --session dl --format detail-plan --id "$I1" --text-hash "$H1" --choice A --reason "revise upstream"
ck "listed: a pair printed only by an earlier list exits 2" "2" "$UP_RC"
ck "listed: the stale pair appends nothing" "1" "$(dec_lines dl detail-plan)"
I2="$(printf '%s\n' "$L2" | awk -F'\t' 'NF{print $2; exit}')"
up decide --session dl --format detail-plan --id "$I2" --text-hash "$H2" --choice A --reason "revise upstream"
ck "listed: the pair of the latest list exits 0" "0" "$UP_RC"
ck "listed: the latest pair appends exactly one more line" "2" "$(dec_lines dl detail-plan)"
case_end

case_begin "decide-refused-after-empty-round" "bin/lib/concern-ledger/upstream-tag.sh"
# audit run-0013: an empty round still writes its marker row (cycle, round, -, -), so the
# latest round has no candidate and a pair from round 1 is refused.
up_write_plans dz
up_report test "$UP_ROOT/dz1.md" "1|HIGH|$DT1"
up list --session dz --format detail-plan --round 1 --from-report "$UP_ROOT/dz1.md"
ZI="$(printf '%s\n' "$UP_OUT" | awk -F'\t' 'NF{print $2; exit}')"; ZH="$(up_hash_of "$UP_OUT" 1)"
ck "empty round: round 1 lists candidate X with a real hash (precondition)" "0 1 yes" "$UP_RC $(up_rows "$UP_OUT") $(up_is_hash "$ZH")"
up_report test "$UP_ROOT/dz2.md" "1|MEDIUM|the retry path is not covered by any step"
up list --session dz --format detail-plan --round 2 --from-report "$UP_ROOT/dz2.md"
ck "empty round: round 2 lists nothing and exits 0" "0|" "$UP_RC|$UP_OUT"
ck "empty round: seen.tsv has the round 2 marker row (cycle 1, round 2, -, -)" "1" \
  "$(awk -F'\t' '{sub(/\r$/,"")} $1=="1" && $2=="2" && $3=="-" && $4=="-" {n++} END{print n+0}' "$(up_ctl dz)/detail-plan-upstream-seen.tsv" 2>/dev/null)"
Z0="$(sum_of "$(dec_file dz detail-plan)")"
up decide --session dz --format detail-plan --id "$ZI" --text-hash "$ZH" --choice C --reason "follow the intent"
ck "empty round: decide with X's id and hash exits 2" "2" "$UP_RC"
ck "empty round: decisions.tsv is unchanged" "$Z0" "$(sum_of "$(dec_file dz detail-plan)")"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
