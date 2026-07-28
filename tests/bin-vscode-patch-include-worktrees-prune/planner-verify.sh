# Part of tests/bin-vscode-patch-include-worktrees-prune.sh (sourced, not standalone).
# Tests: bin/lib/vscode-patch-include-worktrees/prune.js, bin/lib/vscode-patch-include-worktrees/prune/verify.js
# Tags: bin, vscode, prune, planner, verify, session-files, scope:common, pwsh-not-required, TL2
#
# B + C — the two halves of the deletion decision.
#
# B: planPrune is a pure function over an already-classified group, so it is driven
#    table-style with constructed verdict objects. No fixtures, no I/O: the whole
#    point is that the decision is separable from the reading.
# C: verifyCounterpart is the I2 (content-record) proof and the single reason the "no
#    backup" tradeoff in intent.md is admissible — a stub may only be deleted once
#    ANOTHER file has been shown to carry a real user/assistant/summary record tagged
#    with the same sessionId. It is fixture-based because the read budget and the
#    early-stop point are themselves part of the contract.
#    verifyCounterpart only ever sees ONE counterpart, so the rule for a stub with
#    several real copies — try them in turn and prune on the first that verifies, and
#    never let an unobserved copy be reported as a decision reached — belongs to the
#    caller and is exercised through the real two-phase path in counterpart-aggregation.sh
#    (C08-C12), split out of this file at the 500-line hard limit.
#
# Serialization used below: each planPrune decision is rendered
# `<action>:<reason|->:<counterpart-count>` so one string compares the whole table row.

# ---- B: planPrune ----------------------------------------------------------

# Group members share a basename by construction (that is what a group IS); they are
# placed in distinct directories, exactly as duplicate session copies appear on disk.
run_b_plan_prune() {
  local name verdicts want
  while IFS='|' read -r name verdicts want; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    verdicts="${verdicts//[[:space:]]/}"
    want="$(printf '%s' "$want" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    VERDICTS="$verdicts" node_m 'const m=require("'"$REQUIRE_PATH"'");
const group=process.env.VERDICTS.split(",").map(function(v,i){
  return { file:"/copies/dir"+i+"/session.jsonl", root:"/copies", verdict:v,
           titleKeys: v==="stub" ? ["k"+i] : [], size:10, mtimeMs:1 };
});
console.log(m.planPrune(group).map(function(d){
  return d.action+":"+(d.reason||"-")+":"+((d.counterparts||[]).length);
}).join(" "));'
    check "$name: planPrune decisions" "$want" "$NODE_OUT"
  done <<'TABLE'
B01-stub-plus-real       | stub,real            | prune-candidate:-:1 none:-:0
B02-two-stubs-one-real   | stub,stub,real       | prune-candidate:-:1 prune-candidate:-:1 none:-:0
B03-lone-stub            | stub                 | keep:no-real-copy:0
B04-two-stubs-no-real    | stub,stub            | keep:no-real-copy:0 keep:no-real-copy:0
B05-stub-plus-indet      | stub,indeterminate   | keep:no-real-copy:0 none:-:0
B06-stub-plus-unreadable | stub,unreadable      | keep:no-real-copy:0 unreadable:-:0
B07-stub-plus-unclass    | stub,unclassified    | keep:no-real-copy:0 unclassified:-:0
B08-real-only            | real,real            | none:-:0 none:-:0
TABLE
}

# B03 restated on its own, because it is intent.md's absolute invariant rather than
# just another table row: a stub with no surviving copy is never a deletion candidate,
# whatever else is true of the run. A regression here is unrecoverable data loss.
run_b_lone_stub_invariant() {
  node_m 'const m=require("'"$REQUIRE_PATH"'");
const d=m.planPrune([{file:"/copies/dir0/session.jsonl",root:"/copies",verdict:"stub",
                      titleKeys:["k0"],size:10,mtimeMs:1}])[0];
console.log("A="+d.action+" R="+(d.reason||"-")+" C="+((d.counterparts||[]).length));'
  check "B09: a stub with no real copy is never a prune candidate" \
    "A=keep R=no-real-copy C=0" "$NODE_OUT"

  # Symmetric statement of the same invariant: `indeterminate` and `unreadable` must
  # not be counted as the surviving copy either.
  node_m 'const m=require("'"$REQUIRE_PATH"'");
const mk=function(v,i){return {file:"/copies/dir"+i+"/session.jsonl",root:"/copies",verdict:v,
                               titleKeys:v==="stub"?["k"+i]:[],size:10,mtimeMs:1};};
const acts=m.planPrune([mk("stub",0),mk("indeterminate",1),mk("unreadable",2),mk("unclassified",3)])
  .map(function(d){return d.action;});
console.log("A="+acts[0]);'
  check "B10: indeterminate/unreadable/unclassified together still do not enable a prune" \
    "A=keep" "$NODE_OUT"
}

# ---- C: verifyCounterpart --------------------------------------------------

# C is the I2 CONTENT-RECORD proof and nothing else: the counterpart must carry a real
# `user` / `assistant` / `summary` record tagged with the same sessionId. Title TEXT is
# deliberately NOT a matching key (#1655). Renaming a session is an everyday act, and
# the rename is written into whichever project directory the extension considered
# current at that moment — so two copies of the same transcript routinely disagree about
# the title while describing the identical session. The old rule (the counterpart must
# already carry every one of the stub's titles) therefore refused almost every prune a
# real user could ever want. Nothing here migrates a title and nothing here writes to the
# counterpart: once the stub is gone the surviving copy simply keeps the title it already
# had, which is precisely the title the user last set on the copy they were using.
#
# What is NOT relaxed: the stub side still re-proves its own titleKeys between plan and
# unlink (I4, lifecycle-race.sh R-8), and an observation that failed still outranks any
# decision reached.

# The counterpart file and the sessionId are the WHOLE input. No stub is passed, because
# the stub's title set is not part of the question any more; C13 pins the arity so a
# stale three-argument call site cannot quietly slide a sessionId into a removed slot.
verify_call() { # <counterpart-file> <sessionId> ; sets NODE_OUT
  V_CP="$(native_file "$1")" V_SID="$2" \
    node_m 'const m=require("'"$REQUIRE_PATH"'");
const r=m.verifyCounterpart(process.env.V_CP, process.env.V_SID);
console.log("OK="+(r.ok===true)+" R="+(r.reason||"-"));'
}

run_c_verify_counterpart() {
  local sd cd cp

  # C01 — the ordinary shape: the counterpart holds a content record for this session
  # and happens to carry the same title too. The title is incidental; the content
  # record is the proof.
  cd="$(new_dir)"
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$cd" "$SID_A"
  cp="$(session_path "$cd" "$SID_A")"
  verify_call "$cp" "$SID_A"
  check "C01: a counterpart with a content record for this session verifies" \
    "OK=true R=-" "$NODE_OUT"

  # C02 — THE case #1655 is about: the user renamed the session on one side, so the two
  # copies disagree about the title while describing the same transcript. That is a
  # rename, not a loss, and it must not block the prune.
  sd="$(new_dir)"; cd="$(new_dir)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$sd" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Bravo"; } | mk_session "$cd" "$SID_A"
  verify_call "$(session_path "$cd" "$SID_A")" "$SID_A"
  check "C02: a counterpart carrying a DIFFERENT title still verifies" \
    "OK=true R=-" "$NODE_OUT"

  # C03 — the old rule's other refusal shape: the stub accumulated two titles over its
  # life and the counterpart only ever saw one of them. The stub is still written to disk
  # here (it is what the situation looks like) but it is deliberately not an input —
  # that removal IS the change.
  sd="$(new_dir)"; cd="$(new_dir)"
  { title_line "$SID_A" "Alpha"; title_line "$SID_A" "Bravo"; } | mk_session "$sd" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$cd" "$SID_A"
  verify_call "$(session_path "$cd" "$SID_A")" "$SID_A"
  check "C03: a counterpart carrying only one of the stub's two titles still verifies" \
    "OK=true R=-" "$NODE_OUT"

  # C03b — the counterpart carries no custom-title record at all. Still fine: after the
  # stub is deleted the counterpart keeps its own system-assigned default title. The
  # stub's title is discarded, never migrated — that is the accepted, documented cost.
  cd="$(new_dir)"
  { content_line "$SID_A"; content_line "$SID_A" assistant; } | mk_session "$cd" "$SID_A"
  verify_call "$(session_path "$cd" "$SID_A")" "$SID_A"
  check "C03b: a counterpart with no custom-title record at all still verifies" \
    "OK=true R=-" "$NODE_OUT"

  # C05 — I2 itself, unchanged and now carrying the whole weight of the proof: titles
  # are not a transcript, and a transcript belonging to ANOTHER session is not this
  # session's transcript.
  cd="$(new_dir)"
  { title_line "$SID_A" "Alpha"; content_line "$SID_B"; } | mk_session "$cd" "$SID_A"
  verify_call "$(session_path "$cd" "$SID_A")" "$SID_A"
  check "C05: a counterpart with no matching content record is refused" \
    "OK=false R=no-content" "$NODE_OUT"
}

# C04 — the early-stop proof, and the replacement for the old "reads to EOF" row. That
# property existed only because a title could be the last line of the file; with titles
# out of the question, positive evidence is COMPLETE the moment it is seen, so the read
# budget stops there. The fixture is deliberately larger than VERIFY_MAX_SCAN with its
# content record on the FIRST line: a verifier that still had to reach EOF would report
# verify-truncated here. This is what makes the pass affordable on the multi-megabyte
# transcripts that dominate a real ~/.claude/projects.
run_c_verify_early_stop() {
  local cd cp
  cd="$(new_dir)"
  mkdir -p "$cd"
  cp="$(session_path "$cd" "$SID_A")"
  gen_big "$cp" "$SID_A" $((VERIFY_MAX_SCAN + 128)) title content none
  verify_call "$cp" "$SID_A"
  check "C04: a content record on line 1 verifies even past VERIFY_MAX_SCAN" \
    "OK=true R=-" "$NODE_OUT"
  rm -f "$cp"
}

# C06 / C06b — VERIFY_MAX_SCAN, the fail-closed half of the early stop. A file that was
# not observed in full cannot support a claim about what it does or does not contain, so
# truncation is an OBSERVATION FAILURE (`unclassified`, exit 1), never a decision to
# keep. Both rows put the filler BEFORE any content record (`lead none`): a leading
# content record would trip the early stop and the cap would never be reached at all,
# which is exactly the trap the old `lead content` fixture would now fall into.
run_c_verify_truncated() {
  local cd cp
  cd="$(new_dir)"
  mkdir -p "$cd"
  cp="$(session_path "$cd" "$SID_A")"
  gen_big "$cp" "$SID_A" $((VERIFY_MAX_SCAN + 128)) title none none
  verify_call "$cp" "$SID_A"
  check "C06: a counterpart past VERIFY_MAX_SCAN reports verify-truncated" \
    "OK=false R=verify-truncated" "$NODE_OUT"
  rm -f "$cp"

  # C06b — the security row. The ONLY matching content record sits beyond the cap, so
  # the scanned prefix genuinely proves nothing. The early stop must never be able to
  # convert "not observed" into "observed": truncation is checked first and
  # unconditionally, before any content decision, so the answer is a refusal and never
  # `ok`. Getting this backwards deletes a file on the strength of a record nobody read.
  cd="$(new_dir)"
  mkdir -p "$cd"
  cp="$(session_path "$cd" "$SID_A")"
  gen_big "$cp" "$SID_A" $((VERIFY_MAX_SCAN + 128)) title none content
  verify_call "$cp" "$SID_A"
  check "C06b: a content record beyond the cap is refused, not credited" \
    "OK=false R=verify-truncated" "$NODE_OUT"
  rm -f "$cp"
}

# C07 — an unreadable counterpart. Same probe-first discipline as classifier.sh A20.
run_c_verify_unreadable() {
  local cd cp
  cd="$(new_dir)"
  mkdir -p "$cd"
  cp="$(session_path "$cd" "$SID_A")"
  mkdir -p "$cp"
  : > "$cp/placeholder"
  FIXFILE="$(native_file "$cp")" node_m 'const fs=require("fs");
try { fs.readFileSync(process.env.FIXFILE); console.log("P=readable"); }
catch (e) { console.log("P=faulted"); }'
  if [ "$NODE_OUT" != "P=faulted" ]; then
    skip_case "C07 unreadable counterpart (host does not fault on reading a directory)"
    return 0
  fi
  verify_call "$cp" "$SID_A"
  check "C07: an unreadable counterpart reports unreadable" \
    "OK=false R=unreadable" "$NODE_OUT"
}

# C13 — the call-path guard. The superset parameter is gone from the signature, so the
# arity is pinned here: a stale three-argument call site left behind in prune.js would
# otherwise keep working by accident, silently passing the sessionId into the removed
# slot and `undefined` into the sessionId slot — which reads as "this counterpart has no
# content record for the session", i.e. it would refuse every prune while looking fine.
run_c_verify_arity() {
  node_m 'const m=require("'"$REQUIRE_PATH"'");
console.log("N="+m.verifyCounterpart.length);'
  check "C13: verifyCounterpart takes exactly (counterpartFile, sessionId)" "N=2" "$NODE_OUT"
}


run_b_plan_prune
run_b_lone_stub_invariant
run_c_verify_counterpart
run_c_verify_early_stop
run_c_verify_truncated
run_c_verify_unreadable
run_c_verify_arity
