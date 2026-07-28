# Part of tests/bin-vscode-patch-include-worktrees-prune.sh (sourced, not standalone).
# Tests: bin/lib/vscode-patch-include-worktrees/prune/verify.js, bin/lib/vscode-patch-include-worktrees/prune.js
# Tags: bin, vscode, prune, record-grammar, security, session-files, scope:common, pwsh-not-required, TL2
#
# H — the RECORD GRAMMAR, and the two holes that opened when I3 was removed (#1655).
#
# I3 ("the counterpart carries every (sessionId, customTitle) pair the stub has") used to
# be a second, independent gate in front of every deletion. It refused nearly every
# genuine pair — users rename titles by hand and the rename lands on one side only — so it
# is gone. What the security review then found is that it had been silently compensating
# for two weaknesses that are now directly reachable:
#
#   F1  a content record needed no payload, so `{"type":"user","sessionId":"<uuid>"}` —
#       60 bytes, in any file — authorised an unrecoverable delete of a real user file.
#   HIGH a custom-title needed no ownership, so `A.jsonl` holding session B's only title
#       still classified as a `stub` of A and was deleted the moment another copy of
#       `A.jsonl` carried content for A.
#
# Sections A7/A8 of classifier.sh pin both rules on the CLASSIFIER. This part pins them on
# the VERIFIER — the side that authorises the deletion — plus the shared-grammar property
# that makes the pair safe (H02) and the end-to-end attack scenarios (H03-H06).

# verify_call() comes from planner-verify.sh, which the dispatcher sources first; it sets
# NODE_OUT to `OK=<bool> R=<reason>`.

# ---- H1: the payload rule at the counterpart -------------------------------

# The counterpart is the file whose contents authorise the delete, so the payload rule
# matters most here. Both directions in one function (Pattern 4): a shell record must be
# refused, and the same type carrying a real payload must still verify — a guard that
# refused both would simply have disabled the feature.
run_h_counterpart_payload() {
  local cd

  # H01 — the reproduced attack, at the unit that decides. Before the fix this returns
  # ok=true and is the whole justification for deleting someone's file.
  cd="$(new_dir)"
  { content_line_shell "$SID_A"; } | mk_session "$cd" "$SID_A"
  verify_call "$(session_path "$cd" "$SID_A")" "$SID_A"
  check "H01a: a user record with no message is not a transcript" \
    "OK=false R=no-content" "$NODE_OUT"

  cd="$(new_dir)"
  { content_line_shell "$SID_A" assistant; } | mk_session "$cd" "$SID_A"
  verify_call "$(session_path "$cd" "$SID_A")" "$SID_A"
  check "H01b: an assistant record with no message is not a transcript" \
    "OK=false R=no-content" "$NODE_OUT"

  cd="$(new_dir)"
  { content_line_shell "$SID_A" summary; } | mk_session "$cd" "$SID_A"
  verify_call "$(session_path "$cd" "$SID_A")" "$SID_A"
  check "H01c: a summary record with no summary text is not a transcript" \
    "OK=false R=no-content" "$NODE_OUT"

  # The fixture that USED to be emitted for every type: a `summary` carrying only
  # `message`. It names a content type and the right session and still proves nothing.
  cd="$(new_dir)"
  { printf '{"type":"summary","sessionId":"%s","message":{"role":"user"}}\n' "$SID_A"; } \
    | mk_session "$cd" "$SID_A"
  verify_call "$(session_path "$cd" "$SID_A")" "$SID_A"
  check "H01d: a summary carrying only a message field is not a transcript" \
    "OK=false R=no-content" "$NODE_OUT"

  # Pattern 4 — the sanctioned direction, one row per content type, so the rule cannot
  # ship as a blanket refusal.
  cd="$(new_dir)"
  { content_line "$SID_A" user; } | mk_session "$cd" "$SID_A"
  verify_call "$(session_path "$cd" "$SID_A")" "$SID_A"
  check "H01e: a user record with a message object still verifies" "OK=true R=-" "$NODE_OUT"

  cd="$(new_dir)"
  { content_line "$SID_A" assistant; } | mk_session "$cd" "$SID_A"
  verify_call "$(session_path "$cd" "$SID_A")" "$SID_A"
  check "H01f: an assistant record with a message object still verifies" \
    "OK=true R=-" "$NODE_OUT"

  cd="$(new_dir)"
  { content_line "$SID_A" summary; } | mk_session "$cd" "$SID_A"
  verify_call "$(session_path "$cd" "$SID_A")" "$SID_A"
  check "H01g: a summary record with non-empty text still verifies" "OK=true R=-" "$NODE_OUT"
}

# ---- H2: one grammar, two readers ------------------------------------------

# verify.js states in its own header that the record vocabulary lives there "because both
# the classifier and the verifier must read a line the exact same way; a drift between the
# two would mean a stub was judged by one grammar and its counterpart by another". That is
# an invariant, not a comment, so it is asserted: over the whole payload-shape alphabet,
# `classifySessionFile(...).verdict === 'real'` and `verifyCounterpart(...).ok` must agree
# on every single file. Both budgets are irrelevant at this size, so any disagreement is a
# grammar disagreement and nothing else.
#
# REAL/OK counts are asserted alongside DRIFT so the row cannot pass vacuously: a build
# where NOTHING classified real would report DRIFT=- too.
run_h_shared_grammar() {
  local base
  base="$(new_dir)"

  h_shape() { # <slot> <emitter> [args...]
    local slot="$1"; shift
    mkdir -p "$base/$slot"
    "$@" > "$base/$slot/$SID_A.jsonl"
  }

  h_shape s01 content_line "$SID_A" user
  h_shape s02 content_line "$SID_A" assistant
  h_shape s03 content_line "$SID_A" summary
  h_shape s04 content_line_shell "$SID_A" user
  h_shape s05 content_line_shell "$SID_A" summary
  h_shape s06 content_line_payload "$SID_A" user null
  h_shape s07 content_line_payload "$SID_A" summary '""'
  h_shape s08 content_line "$SID_B" user

  H_BASE="$(native_path "$base")" H_SID="$SID_A" node_m 'const m=require("'"$REQUIRE_PATH"'");
const fs=require("fs"), path=require("path");
const base=process.env.H_BASE, sid=process.env.H_SID;
const slots=fs.readdirSync(base).filter(function(n){return /^s\d+$/.test(n);}).sort();
const drift=[]; let nReal=0, nOk=0;
for (const slot of slots) {
  const f=path.join(base, slot, sid+".jsonl");
  const isReal=m.classifySessionFile(f).verdict==="real";
  const ok=m.verifyCounterpart(f, sid).ok===true;
  if (isReal) nReal+=1;
  if (ok) nOk+=1;
  if (isReal!==ok) drift.push(slot+":real="+isReal+",ok="+ok);
}
console.log("DRIFT="+(drift.join(",")||"-")+" N="+slots.length+" REAL="+nReal+" OK="+nOk);'
  check "H02: the classifier and the verifier read a record the same way" \
    "DRIFT=- N=8 REAL=3 OK=3" "$NODE_OUT"
}

# ---- H3: the attack scenarios, end to end ----------------------------------

# H03 — F1 as the user would experience it. `forged/` is a file this tool has no business
# trusting: one 60-byte line naming a content type and the stub's session id. Before the
# fix it classifies `real`, becomes the surviving copy, and the stub is destroyed.
#
# Pattern 1: exit code and report text are NOT the assertion — the stub's continued
# existence, byte for byte, is.
run_h_forged_counterpart() {
  local home ext proj stub forged before
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$proj/stub" "$SID_A"
  { content_line_shell "$SID_A"; } | mk_session "$proj/forged" "$SID_A"
  stub="$(session_path "$proj/stub" "$SID_A")"
  forged="$(session_path "$proj/forged" "$SID_A")"
  check "H03a: precondition — the forgery is a single short line" "1" \
    "$(wc -l < "$forged" | tr -d '[:space:]')"
  before="$(hash_of "$stub")"

  run_cli_prune "$home" "$ext" "$proj"
  check "H03b: exit 0" "0" "$CLI_RC"
  check_contains "H03c: a payload-less record justifies nothing" "pruned=0" "$CLI_OUT"
  check_file "H03d: the stub still exists" "$stub"
  check "H03e: the stub is byte-identical" "$before" "$(hash_of "$stub")"
  check_no_file "H03f: nothing was displaced to a backup either" "$stub.bak"
  check_file "H03g: the forged file is left alone too" "$forged"
}

# H04 — Pattern 4 for H03: the identical tree with a real payload on the counterpart must
# still prune. Without this row the fix could ship as "refuse everything" and look green.
run_h_forged_counterpart_allowed() {
  local home ext proj stub
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$proj/stub" "$SID_A"
  { content_line "$SID_A"; } | mk_session "$proj/genuine" "$SID_A"
  stub="$(session_path "$proj/stub" "$SID_A")"

  run_cli_prune "$home" "$ext" "$proj"
  check "H04a: exit 0" "0" "$CLI_RC"
  check_contains "H04b: a counterpart with a real payload still justifies the prune" \
    "pruned=1" "$CLI_OUT"
  check_no_file "H04c: the stub is gone" "$stub"
  check_file "H04d: the counterpart survives" "$(session_path "$proj/genuine" "$SID_A")"
}

# H05 — the codex HIGH finding as the user would experience it. `p1/A.jsonl` carries a
# custom-title for session B and nothing else; that title exists NOWHERE else on disk.
# `p2/A.jsonl` is A's genuine transcript. Before the fix p1 classifies `stub`, p2 justifies
# the delete, and B's only title is destroyed by a run that was asked to prune A.
run_h_foreign_title_stub() {
  local home ext proj victim before
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  { title_line "$SID_B" "$SECRET_TITLE"; } | mk_session "$proj/p1" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$proj/p2" "$SID_A"
  victim="$(session_path "$proj/p1" "$SID_A")"
  before="$(hash_of "$victim")"

  run_cli_prune_split "$home" "$ext" "$proj"
  check "H05a: exit 0" "0" "$CLI_RC"
  check_contains "H05b: a file holding another session's title is never pruned" \
    "pruned=0" "$CLI_STDOUT"
  check_file "H05c: the foreign title's only home still exists" "$victim"
  check "H05d: it is byte-identical" "$before" "$(hash_of "$victim")"
  check_no_file "H05e: it was not displaced to a backup either" "$victim.bak"
  check_absent "H05f: the foreign title does not reach stdout" "$SECRET_TITLE" "$CLI_STDOUT"
  check_absent "H05g: the foreign title does not reach stderr" "$SECRET_TITLE" "$CLI_STDERR"
}

# H06 — Pattern 4 for H05: the same tree with the title naming its OWN session must still
# prune, so ownership does not quietly disable the feature for every stub.
run_h_own_title_stub_allowed() {
  local home ext proj victim
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$proj/p1" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Bravo"; } | mk_session "$proj/p2" "$SID_A"
  victim="$(session_path "$proj/p1" "$SID_A")"

  run_cli_prune "$home" "$ext" "$proj"
  check "H06a: exit 0" "0" "$CLI_RC"
  check_contains "H06b: a stub whose titles are its own is still prunable" \
    "pruned=1" "$CLI_OUT"
  check_no_file "H06c: the stub is gone" "$victim"
}

# ---- H4: the predicates themselves -----------------------------------------

# H07 — the RENAME is the guard. `isKnownTitleRecord(record)` could not check ownership
# because it never received the session id, and a call site that forgot to check was
# indistinguishable from one that did. `isOwnTitleRecord(record, sessionId)` cannot be
# called correctly without the id, so the arity is pinned: a stale one-argument call site
# would pass `undefined` and — with `===` comparison — refuse every title, turning every
# stub into an indeterminate. The old spelling must be GONE, not merely joined.
run_h_own_title_predicate() {
  node_m 'const e=require("'"$REQUIRE_PATH"'");
const p=require("'"$PRUNE_REQUIRE"'");
const v=require("'"$VERIFY_REQUIRE"'");
const own=v.isOwnTitleRecord;
console.log("V="+(typeof v.isOwnTitleRecord)+" P="+(typeof p.isOwnTitleRecord)+
            " E="+(typeof e.isOwnTitleRecord)+
            " N="+(typeof own==="function"?own.length:-1)+
            " OLD="+(v.isKnownTitleRecord===undefined));'
  check "H07a: isOwnTitleRecord is exported at all three layers and takes (record, sessionId)" \
    "V=function P=function E=function N=2 OLD=true" "$NODE_OUT"

  H_A="$SID_A" H_B="$SID_B" node_m 'const v=require("'"$VERIFY_REQUIRE"'");
const own=v.isOwnTitleRecord;
if (typeof own!=="function") { console.log("PREDICATE=missing"); process.exit(0); }
const A=process.env.H_A, B=process.env.H_B;
const rec=function(sid){return {type:"custom-title",sessionId:sid,customTitle:"Alpha"};};
console.log("OWN="+own(rec(A),A)+
            " FOREIGN="+own(rec(B),A)+
            " BARE="+own(rec(A))+
            " EXTRA="+own(Object.assign(rec(A),{pinnedAt:1}),A)+
            " AITITLE="+own({type:"ai-title",sessionId:A,aiTitle:"x"},A)+
            " NONSTRING="+own({type:"custom-title",sessionId:A,customTitle:5},A));'
  check "H07b: ownership is required on top of the existing shape rules" \
    "OWN=true FOREIGN=false BARE=false EXTRA=false AITITLE=false NONSTRING=false" "$NODE_OUT"
}

# H08 — isMatchingContentRecord is the SSOT of the payload rule; A7 and H01 observe it
# through two different readers, and this row states it directly so a future reader added
# to the module has something unambiguous to conform to. `summary` carrying only `message`
# is included deliberately: that was the shared fixture's old shape for every type.
run_h_content_predicate() {
  H_A="$SID_A" H_B="$SID_B" node_m 'const v=require("'"$VERIFY_REQUIRE"'");
const f=v.isMatchingContentRecord;
if (typeof f!=="function") { console.log("PREDICATE=missing"); process.exit(0); }
const A=process.env.H_A, B=process.env.H_B;
const rows=[
  ["user-message-object",      {type:"user",sessionId:A,message:{role:"user"}},      true],
  ["assistant-message-object", {type:"assistant",sessionId:A,message:{role:"a"}},    true],
  ["summary-text",             {type:"summary",sessionId:A,summary:"recap"},         true],
  ["user-no-message",          {type:"user",sessionId:A},                            false],
  ["user-message-null",        {type:"user",sessionId:A,message:null},               false],
  ["user-message-array",       {type:"user",sessionId:A,message:[]},                 false],
  ["user-message-string",      {type:"user",sessionId:A,message:"hi"},               false],
  ["summary-no-summary",       {type:"summary",sessionId:A},                         false],
  ["summary-empty-text",       {type:"summary",sessionId:A,summary:""},              false],
  ["summary-object-payload",   {type:"summary",sessionId:A,summary:{t:1}},           false],
  ["summary-only-message",     {type:"summary",sessionId:A,message:{role:"user"}},   false],
  ["other-session",            {type:"user",sessionId:B,message:{role:"user"}},      false],
  ["ai-title",                 {type:"ai-title",sessionId:A,message:{role:"user"}},  false],
  ["custom-title",             {type:"custom-title",sessionId:A,customTitle:"x"},    false]
];
const bad=[]; let nTrue=0;
for (const row of rows) {
  const got=f(row[1], A)===true;
  if (got) nTrue+=1;
  if (got!==row[2]) bad.push(row[0]+":got="+got);
}
console.log("BAD="+(bad.join(",")||"-")+" N="+rows.length+" TRUE="+nTrue);'
  check "H08: a content record proves a transcript only when it carries its own payload" \
    "BAD=- N=14 TRUE=3" "$NODE_OUT"
}

# SKIPPED: a record whose payload field is present but whose VALUE is a hostile deep
#          structure (a 100 MB nested message, a prototype-polluting key).
# Because: the predicate is a shape test on one already-parsed line, and JSON.parse has
#          already bounded the damage by the time it runs; constructing the pathological
#          input proves nothing about this module.
# L3 gap:  a real ~/.claude/projects written by a future Claude Code build whose record
#          shapes have moved on — only a read-only --dry-run against the live tree can
#          tell whether the grammar still matches what is actually on disk.

run_h_counterpart_payload
run_h_shared_grammar
run_h_forged_counterpart
run_h_forged_counterpart_allowed
run_h_foreign_title_stub
run_h_own_title_stub_allowed
run_h_own_title_predicate
run_h_content_predicate
