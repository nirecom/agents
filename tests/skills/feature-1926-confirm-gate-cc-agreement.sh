#!/usr/bin/env bash
# feature-1926-confirm-gate-cc-agreement.sh — #1926/#2225: the confirm gate only feeds CC's agreement call.
# Tests: skills/issue-create/scripts/eval-confirm-gate.sh, skills/issue-create/scripts/record-confirm-decision.sh
# Tags: scope:issue-specific, skills, issue-create, confirm-gate, verdict-disputed, TL2, issue-1926, issue-2225, issue-2019, g0, finding-approval, proposal-sha256
# TL2: runs the real gate and recorder scripts against fixture final JSON files in a tmp dir.
# TL3 gap (not caught here; category skill-orchestration): whether the model, reading the gate
# output, really asks on disputed and records an auto decision through the recorder.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

CG_TMP="$(make_tmp)"
readonly CG_TMP
trap 'cd / || true; rm -rf "$CG_TMP"' EXIT
harness_isolate "$CG_TMP"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true; G0_SID="1926a0c0-2019-4e01-8a9b-0c1d2e3f4e01"
export CLAUDE_TRANSCRIPT_BASE_DIR="$CG_TMP/transcripts"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"
cd "$CG_TMP" || exit 1

GATE="$SCRIPT_CHECKOUT_ROOT/skills/issue-create/scripts/eval-confirm-gate.sh"
RECORD="$SCRIPT_CHECKOUT_ROOT/skills/issue-create/scripts/record-confirm-decision.sh"

check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=[$3] got=[$2]"; fi; }
# #2019: approve holds G0 at pass (a fresh typed-command approval record) so these cases isolate G1..G4.
approve() { node -e 'require("fs").writeFileSync(process.argv[1],JSON.stringify({version:1,session_id:process.argv[2],pending:[],records:[{type:"typed-command",at:new Date().toISOString()}]}))' "$(np "$WORKFLOW_STATE_DIR/$G0_SID.finding-filing-approval")" "$G0_SID"; }

# mkfinal <name> <verdict> <survey-verdict> <review-status> <worth-json> — writes a final JSON.
# A worth of "-" leaves worth_filing out of review; a status of "-" leaves review out entirely.
mkfinal() {
  local f="$CG_TMP/$1.json" review=""
  if [[ "$4" != "-" ]]; then
    review=", \"review\": {\"status\": \"$4\""
    [[ "$5" != "-" ]] && review+=", \"worth_filing\": $5"
    review+="}"
  fi
  printf '{"proposal": {"title": "t", "severity": "MEDIUM", "body": "b"}, "verdict": "%s", "survey": {"verdict": "%s"}%s}\n' "$2" "$3" "$review" > "$f"
  printf '%s' "$f"
}

# gate <final> — runs the one-argument gate; sets G_RC, G_OUT, G_L1, G_L2, G_WORTH.
gate() {
  approve; G_OUT="$(CLAUDE_CODE_SESSION_ID="$G0_SID" bash "$GATE" "$@" 2>"$CG_TMP/gate.err")"
  G_RC=$?
  G_L1="$(printf '%s\n' "$G_OUT" | sed -n 1p)"
  G_L2="$(printf '%s\n' "$G_OUT" | sed -n 2p)"
  G_WORTH="$(printf '%s\n' "$G_OUT" | grep -E '^worth_filing: ' | head -n 1)"
}

CLEAN="$(mkfinal clean none none upheld true)"

case_begin "arity-exactly-one-argument" "skills/issue-create/scripts/eval-confirm-gate.sh"
gate "$CLEAN"
check "one argument classifies (rc)" "$G_RC" "0"
check "one argument, clean artifact: confirm no" "$G_L1" "confirm: no"
gate
if [[ "$G_RC" -ne 0 ]]; then pass "zero arguments is an error"; else fail "zero arguments is an error" "rc=0 out=[$G_OUT]"; fi
gate "$CLEAN" "severity:high"
if [[ "$G_RC" -ne 0 ]]; then pass "two arguments is an error"; else fail "two arguments is an error" "rc=0 out=[$G_OUT]"; fi
if [[ "$G_OUT" != *"confirm:"* ]]; then pass "an arity error prints no verdict"; else fail "an arity error prints no verdict" "out=[$G_OUT]"; fi
case_end

case_begin "g5-retired-severity-has-no-axis" "skills/issue-create/scripts/eval-confirm-gate.sh"
gate "$CLEAN"
check "clean artifact needs no severity to pass" "$G_L1|$G_L2" "confirm: no|reasons: "
if [[ "$G_OUT" != *G5* ]]; then pass "G5 never appears"; else fail "G5 never appears" "out=[$G_OUT]"; fi
REOPEN="$(mkfinal reopen reopen reopen upheld true)"
gate "$REOPEN"
check "a G1 artifact lists G1 alone" "$G_L1|$G_L2" "confirm: yes|reasons: G1"
case_end

case_begin "g3-fires-only-on-missing-or-broken-json" "skills/issue-create/scripts/eval-confirm-gate.sh"
gate "$CG_TMP/does-not-exist.json"
check "missing final JSON: G3" "$G_L1|${G_L2/G0,/}" "confirm: yes|reasons: G3"
printf '{"verdict": "none", "survey": ' > "$CG_TMP/broken.json"
gate "$CG_TMP/broken.json"
check "unparseable final JSON: G3" "$G_L1|${G_L2/G0,/}" "confirm: yes|reasons: G3"
gate "$(mkfinal worth-false none none upheld false)"
check "worth_filing false does not gate" "$G_L1|$G_L2" "confirm: no|reasons: "
gate "$(mkfinal worth-absent none none upheld -)"
check "worth_filing absent does not gate" "$G_L1|$G_L2" "confirm: no|reasons: "
gate "$(mkfinal worth-string none none upheld '"true"')"
check "worth_filing as a string does not gate" "$G_L1|$G_L2" "confirm: no|reasons: "
case_end

case_begin "worth-filing-info-line" "skills/issue-create/scripts/eval-confirm-gate.sh"
gate "$CLEAN"
check "boolean true reports true" "$G_WORTH" "worth_filing: true"
gate "$(mkfinal info-false none none upheld false)"
check "boolean false reports false" "$G_WORTH" "worth_filing: false"
gate "$(mkfinal info-absent none none upheld -)"
check "absent reports unknown" "$G_WORTH" "worth_filing: unknown"
gate "$(mkfinal info-string none none upheld '"true"')"
check "the string true reports unknown" "$G_WORTH" "worth_filing: unknown"
gate "$(mkfinal info-no-review none none - -)"
check "no review block reports unknown" "$G_WORTH" "worth_filing: unknown"
check "the info line is not one of the first two lines" "${G_L1%%:*}|${G_L2%%:*}" "confirm|reasons"
case_end

case_begin "g2-disputed-or-survey-final-mismatch" "skills/issue-create/scripts/eval-confirm-gate.sh"
gate "$(mkfinal disputed sibling sibling disputed true)"
check "disputed with equal verdicts: G2 alone" "$G_L1|$G_L2" "confirm: yes|reasons: G2"
gate "$(mkfinal mismatch sibling none upheld true)"
check "survey differs from final: G2" "$G_L1|$G_L2" "confirm: yes|reasons: G2"
gate "$(mkfinal agree sibling sibling upheld true)"
check "upheld and equal verdicts: no G2" "$G_L1|$G_L2" "confirm: no|reasons: "
case_end

case_begin "g4-allowlist-upheld-disputed" "skills/issue-create/scripts/eval-confirm-gate.sh"
gate "$CLEAN"
if [[ "$G_L2" != *G4* ]]; then pass "upheld clears G4"; else fail "upheld clears G4" "out=[$G_OUT]"; fi
gate "$(mkfinal g4-disputed none none disputed true)"
if [[ "$G_L2" != *G4* ]]; then pass "disputed clears G4"; else fail "disputed clears G4" "out=[$G_OUT]"; fi
for st in replaced invalid skipped unavailable; do
  gate "$(mkfinal "g4-$st" none none "$st" true)"
  check "status $st fires G4" "$G_L1|$G_L2" "confirm: yes|reasons: G4"
done
gate "$(mkfinal g4-no-review none none - -)"
check "no review block fires G4" "$G_L1|$G_L2" "confirm: yes|reasons: G4"
case_end

case_begin "stdout-first-two-lines-shape" "skills/issue-create/scripts/eval-confirm-gate.sh"
gate "$(mkfinal shape-all make-parent none disputed false)"
check "every gate firing keeps the confirm line" "$G_L1" "confirm: yes"
check "reasons are comma-joined in G order" "$G_L2" "reasons: G1,G2"
if [[ "$G_L1" =~ ^confirm:\ (yes|no)$ && "$G_L2" =~ ^reasons:\ (G[0-4](,G[0-4])*)?$ ]]; then
  pass "lines 1-2 match the confirm/reasons grammar"
else
  fail "lines 1-2 match the confirm/reasons grammar" "l1=[$G_L1] l2=[$G_L2]"
fi
case_end

# ---- #2019 G0 wiring: eval-confirm-gate hands the survey artifact (review.artifact_path) to the gate ----
G0_APPROVAL="$WORKFLOW_STATE_DIR/$G0_SID.finding-filing-approval"
G0_HIGH_BODY=$'Crash on save.\n\n## Severity\nHIGH — data loss on every save of a CRLF file'
# g0_approval <records-json> — a fresh approval file whose records carry `at` = now.
g0_approval() {
  node -e 'const fs=require("fs");const at=new Date().toISOString();const r=JSON.parse(process.argv[2]).map(x=>Object.assign({at},x));fs.writeFileSync(process.argv[1],JSON.stringify({version:1,session_id:process.argv[3],pending:[],records:r}));' "$(np "$G0_APPROVAL")" "$1" "$G0_SID"
}
g0_has_record() { grep -qF "$1" "$G0_APPROVAL" 2>/dev/null; }
# g0_ev <args...> — runs the gate without approve(); sets RC and EOUT.
g0_ev() {
  RC=0
  EOUT="$(CLAUDE_CODE_SESSION_ID="$G0_SID" run_with_timeout 60 bash "$GATE" "$@" 2>/dev/null)" || RC=$?
}
g0_line_of() { printf '%s\n' "$EOUT" | sed -n "s/^$1: //p" | head -n 1; }
# g0_final <severity> <body> <status> <review severity|-> — the write_final shape: g0-survey.json holds
# `proposal`; g0-final.json carries no `proposal`, only review.artifact_path + review.proposal_sha256.
g0_final() {
  node -e 'const fs=require("fs"),path=require("path");const s=process.argv[1];fs.writeFileSync(s,JSON.stringify({verdict:"none",proposal:{title:"Slow save",severity:process.argv[3],body:process.argv[4]}},null,2)+"\n");const r={status:process.argv[5]};if(process.argv[6]!=="-")r.severity=process.argv[6];r.proposal_sha256=require("crypto").createHash("sha256").update(fs.readFileSync(s)).digest("hex");r.artifact_path=path.resolve(s);fs.writeFileSync(process.argv[2],JSON.stringify({verdict:"none",survey:{verdict:"none"},review:r}));' "$(np "$CG_TMP/g0-survey.json")" "$(np "$CG_TMP/g0-final.json")" "$1" "$2" "$3" "$4"
}

case_begin "eval-g0-confirm-and-pass" "skills/issue-create/scripts/eval-confirm-gate.sh"
g0_final MEDIUM "Save is slow." upheld MEDIUM
rm -f "$G0_APPROVAL"
g0_ev "$(np "$CG_TMP/g0-final.json")"
assert_eq "$RC" "0"
assert_eq "$(g0_line_of confirm)" "yes"
if g0_line_of reasons | grep -q 'G0'; then pass "reasons names G0"; else fail "reasons names G0" "$EOUT"; fi
g0_approval '[{"type":"typed-command"}]'
g0_ev "$(np "$CG_TMP/g0-final.json")"
assert_eq "$(g0_line_of confirm)" "no"
g0_approval '[{"type":"askuser-answer","dialog_id":"issue-create.confirm-gate","keys":["7c7c8d8d"]}]'
g0_ev "$(np "$CG_TMP/g0-final.json")" --finding-key 7c7c8d8d
assert_eq "$RC" "0"
assert_eq "$(g0_line_of confirm)" "no"
if g0_has_record 7c7c8d8d; then fail "the answer key is consumed"; else pass "the answer key is consumed"; fi
case_end

case_begin "eval-g0-defer" "skills/issue-create/scripts/eval-confirm-gate.sh"
rm -f "$G0_APPROVAL"
g0_final HIGH "$G0_HIGH_BODY" invalid -
if grep -q '"proposal"' "$CG_TMP/g0-final.json"; then fail "final carries no proposal"; else pass "final carries no proposal"; fi
g0_ev "$(np "$CG_TMP/g0-final.json")"
assert_eq "$RC" "0"
assert_eq "$(g0_line_of defer)" "yes"
case_end

case_begin "eval-g0-high-auto-via-artifact-path" "skills/issue-create/scripts/eval-confirm-gate.sh"
# The reviewed survey bytes match proposal_sha256 and the reviewer says HIGH: G0 passes, no approval needed.
rm -f "$G0_APPROVAL"
g0_final HIGH "$G0_HIGH_BODY" upheld HIGH
g0_ev "$(np "$CG_TMP/g0-final.json")"
assert_eq "$RC" "0"
assert_eq "$(g0_line_of confirm)" "no"
assert_eq "$(g0_line_of defer)" ""
case_end

case_begin "eval-g0-survey-changed-after-review" "skills/issue-create/scripts/eval-confirm-gate.sh"
# The survey file is edited after the review: its sha no longer matches, so the HIGH auto pass is lost.
rm -f "$G0_APPROVAL"
g0_final HIGH "$G0_HIGH_BODY" upheld HIGH
printf '\n' >>"$CG_TMP/g0-survey.json"
g0_ev "$(np "$CG_TMP/g0-final.json")"
assert_eq "$RC" "0"
assert_eq "$(g0_line_of confirm)" "yes"
if g0_line_of reasons | grep -q 'G0'; then pass "reasons names G0"; else fail "reasons names G0" "$EOUT"; fi
case_end

case_begin "eval-arity" "skills/issue-create/scripts/eval-confirm-gate.sh"
g0_final MEDIUM "Save is slow." upheld MEDIUM
G0_F="$(np "$CG_TMP/g0-final.json")"
g0_ev
assert_eq "$RC" "2"
g0_ev "$G0_F" extra
assert_eq "$RC" "2"
g0_ev "$G0_F" --other-flag k
assert_eq "$RC" "2"
g0_ev "$G0_F" --finding-key k extra
assert_eq "$RC" "2"
g0_ev "$G0_F" --finding-key
assert_eq "$RC" "2"
g0_ev "$G0_F" --finding-key 12345678
assert_eq "$RC" "0"
g0_ev "$G0_F"
assert_eq "$RC" "0"
case_end

LOGDIR="$CG_TMP/plans"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/sid-rec-issue-create-confirm.log"
TS_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$'
TAB=$'\t'

case_begin "record-appends-tab-separated-line" "skills/issue-create/scripts/record-confirm-decision.sh"
bash "$RECORD" "$LOGDIR" "sid-rec" auto "G2" "survey and reviewer agree after reading #10" 2>"$CG_TMP/rec.err"
check "first record exits 0" "$?" "0"
check "the log holds one line" "$(grep -c '' "$LOG" 2>/dev/null || echo 0)" "1"
line1="$(sed -n 1p "$LOG" 2>/dev/null)"
if [[ "${line1%%"$TAB"*}" =~ $TS_RE ]]; then pass "field 1 is a UTC timestamp"; else fail "field 1 is a UTC timestamp" "line=[$line1]"; fi
if [[ "$line1" == *"${TAB}auto${TAB}G2${TAB}survey and reviewer agree after reading #10" ]]; then
  pass "decision, reasons and rationale are the trailing tab fields"
else
  fail "decision, reasons and rationale are the trailing tab fields" "line=[$line1]"
fi
bash "$RECORD" "$LOGDIR" "sid-rec" asked "G1,G2" "disputed: reopen vs sibling" 2>>"$CG_TMP/rec.err"
check "second record exits 0" "$?" "0"
check "the second call appends" "$(grep -c '' "$LOG" 2>/dev/null || echo 0)" "2"
check "the first line survives the second call" "$(sed -n 1p "$LOG" 2>/dev/null)" "${line1:-<first call wrote nothing>}"
if [[ "$(sed -n 2p "$LOG" 2>/dev/null)" == *"${TAB}asked${TAB}G1,G2${TAB}disputed: reopen vs sibling" ]]; then
  pass "the second line carries its own fields"
else
  fail "the second line carries its own fields" "line=[$(sed -n 2p "$LOG" 2>/dev/null)]"
fi
case_end

case_begin "record-exit-contract-1-write-failure-2-bad-arguments" "skills/issue-create/scripts/record-confirm-decision.sh"
: > "$CG_TMP/not-a-dir"
bash "$RECORD" "$CG_TMP/not-a-dir/sub" "sid-x" auto "" "r" 2>/dev/null
check "an unwritable plans dir exits 1" "$?" "1"
bash "$RECORD" 2>/dev/null
check "no arguments exit 2" "$?" "2"
bash "$RECORD" "$LOGDIR" "sid-short" 2>/dev/null
check "a missing decision exits 2" "$?" "2"
bash "$RECORD" "$LOGDIR" "sid-maybe" maybe "G2" "r" 2>/dev/null
check "a decision other than auto/asked exits 2" "$?" "2"
bash "$RECORD" "$LOGDIR" "../evil" auto "G2" "r" 2>/dev/null
check "a traversal session id exits 2" "$?" "2"
if [[ ! -e "$CG_TMP/evil-issue-create-confirm.log" ]]; then pass "a traversal session id writes nothing outside the plans dir"; else fail "a traversal session id writes nothing outside the plans dir" "found $CG_TMP/evil-issue-create-confirm.log"; fi
bash "$RECORD" "$LOGDIR" "a/b" auto "G2" "r" 2>/dev/null
check "a session id with a slash exits 2" "$?" "2"
bash "$RECORD" "" "sid-x" auto "G2" "r" 2>/dev/null
check "an empty plans dir exits 2" "$?" "2"
bash "$RECORD" "$LOGDIR" "" auto "G2" "r" 2>/dev/null
check "an empty session id exits 2" "$?" "2"
# The recorder exists, so the codes above are its own exits, not a missing file's.
if [[ -f "$RECORD" ]]; then pass "the recorder script exists"; else fail "the recorder script exists" "missing $RECORD"; fi
case_end

case_begin "record-keeps-shell-metacharacters-literal" "skills/issue-create/scripts/record-confirm-decision.sh"
META='x $(touch cg-pwned-1) `touch cg-pwned-2` ; touch cg-pwned-3 | & > cg-pwned-4 *'
bash "$RECORD" "$LOGDIR" "sid-meta" auto "G2" "$META" 2>/dev/null
check "a metacharacter rationale exits 0" "$?" "0"
if [[ "$(sed -n 1p "$LOGDIR/sid-meta-issue-create-confirm.log" 2>/dev/null)" == *"${TAB}$META" ]]; then
  pass "the rationale is stored verbatim"
else
  fail "the rationale is stored verbatim" "line=[$(sed -n 1p "$LOGDIR/sid-meta-issue-create-confirm.log" 2>/dev/null)]"
fi
pwned="$(find "$CG_TMP" "$LOGDIR" -name 'cg-pwned-*' 2>/dev/null | head -n 1)"
check "no metacharacter was executed" "$pwned" ""
# The probe above only counts once the recorder ran and wrote the log.
if [[ -s "$LOGDIR/sid-meta-issue-create-confirm.log" ]]; then pass "the probe ran against a written log"; else fail "the probe ran against a written log" "no log at $LOGDIR"; fi
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
