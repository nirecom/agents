# Part of tests/bin-vscode-cc-repair-prune.sh (sourced, not standalone).
# Tests: bin/lib/vscode-cc-repair/prune/execute.js, bin/lib/vscode-cc-repair/prune.js
# Tags: bin, vscode, prune, execute, security, containment, tally, session-files, scope:common, pwsh-not-required, TL2
#
# L — what a forged plan may claim about WHERE its files live, and what a forged plan may
# claim about the STATE its entries are in. Both are module-boundary properties:
# executePrunePlan is a public export and the CLI cannot express either input, so every row
# here requires the module directly.
#
# L1 (via.root). `path.relative(decision.via.root, decision.via.file)` runs BEFORE the I2
# verification and outside any try/catch. A plan with a perfectly good via.file and a
# missing or non-string via.root therefore THROWS out of executePrunePlan — after the
# earlier entries in the same batch have already been renamed. The caller gets no tally at
# all, so the report cannot say what was displaced, and the user is left with a partially
# executed batch and no record of it. The type check belongs with the other four conditions
# inside isCounterpartPath: before any syscall, reported as `failed:not-a-counterpart`,
# never thrown.
#
# L2 (containment). isCounterpartPath compares BASENAMES and nothing else. Neither
# decision.file nor decision.via.file is required to live under the root the plan states
# for it, so a forged plan can point `root` at a harmless directory while `file` names any
# title-only uuid-shaped .jsonl anywhere on disk, and authorise it with a same-basename
# record from anywhere else. Containment must be decided on canonicalized paths at a
# SEGMENT boundary: `/a/rootlike` is not inside `/a/root`, however the strings compare.
#
# L3 (TALLY_KEY). The tally bucket is looked up as `TALLY_KEY[state]` on an object literal,
# so `constructor`, `__proto__` and `toString` all inherit truthy values from
# Object.prototype and address a bucket that is not a bucket. verify.js already uses a Map
# for CONTENT_PAYLOAD for exactly this reason; this is the same fix at the same layer.

# ---- drivers ---------------------------------------------------------------

# isCounterpartPath called directly with a fully-specified decision. Prints `C=<bool>`.
# Distinct from plan-identity.sh's counterpart_call: the roots are the subject here, so
# they are always passed explicitly and never defaulted.
containment_call() { # <file> <root> <via-file> <via-root>
  L_F="$1" L_R="$2" L_VF="$3" L_VR="$4" node_m "
const x=require('$EXECUTE_REQUIRE');
console.log('C='+String(x.isCounterpartPath({
  file: process.env.L_F, root: process.env.L_R,
  via: { file: process.env.L_VF, root: process.env.L_VR },
})));"
}

# Plans for real, applies <js> to the candidate, executes for real, and reports BOTH the
# entry outcome and whether the call returned at all. A throw is the failure mode under
# test, so it is caught here and rendered rather than being allowed to abort the driver.
containment_case() { # <projects-root> <js-mutating-cand>
  A_ROOT="$(native_path "$1")" node_m "
const m=require('$REQUIRE_PATH');
const path=require('path');
const root=process.env.A_ROOT;
const planned=m.planPruneRoots({roots:[root]});
const cand=planned.plan.filter(function(d){return d.action==='prune-candidate';})[0];
if (!cand) { console.log('E=no-candidate:-'); } else {
  $2
  const seen=[];
  let ret='returned';
  try {
    m.executePrunePlan({plan:[cand], dryRun:false, onEntry:function(e){seen.push(e);}});
  } catch (err) { ret='threw:'+(err && err.code ? err.code : (err && err.name) || 'Error'); }
  const e=seen[0]||{};
  console.log('E='+(e.state||'-')+':'+(e.reason||'-')+' R='+ret);
}"
}

# ---- L1: via.root must be a string, and a bad one must not abort the batch ---

run_l_via_root_type() {
  local proj h spelling
  # Each spelling is a separate fixture: the first one that reaches the syscall would
  # otherwise change what the next row is even looking at.
  for spelling in "undefined" "null" "42" "({})"; do
    proj="$(guard_fixture)"; h="$(hash_of "$(session_path "$proj/stub" "$SID_A")")"
    containment_case "$proj" \
      "cand.via={root:$spelling,file:path.join(root,'real','$SID_A.jsonl')};"
    check "L01[$spelling]a: a non-string via.root is a caller error, not a crash" \
      "E=failed:not-a-counterpart R=returned" "$NODE_OUT"
    guard_survives "L01[$spelling]b" "$proj" "$h"
  done
}

# L02 — the row that proves the partial-batch failure is gone. Three entries, the MIDDLE
# one malformed. Today the throw escapes on entry 2, entry 1 has already been renamed, and
# executePrunePlan returns nothing at all — so the caller cannot report the displacement it
# just performed. After the fix the batch completes, the tally accounts for every entry, and
# the two well-formed stubs are displaced normally.
run_l_batch_survives_bad_entry() {
  local proj s1 s3
  proj="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$proj/stub-a" "$SID_A"
  { content_line "$SID_A"; } | mk_session "$proj/real-a" "$SID_A"
  { title_line "$SID_B" "Bravo"; } | mk_session "$proj/stub-b" "$SID_B"
  { content_line "$SID_B"; } | mk_session "$proj/real-b" "$SID_B"
  { title_line "$SID_C" "Charlie"; } | mk_session "$proj/stub-c" "$SID_C"
  { content_line "$SID_C"; } | mk_session "$proj/real-c" "$SID_C"

  A_ROOT="$(native_path "$proj")" node_m "
const m=require('$REQUIRE_PATH');
const planned=m.planPruneRoots({roots:[process.env.A_ROOT]});
// Deterministic order: the middle entry is the one that gets the malformed via.root.
const cands=planned.plan.filter(function(d){return d.action==='prune-candidate';})
  .sort(function(a,b){return a.file<b.file?-1:1;});
if (cands.length!==3) { console.log('N='+cands.length); } else {
  delete cands[1].via.root;
  const seen=[]; let ret='returned', tally=null;
  try {
    tally=m.executePrunePlan({plan:cands, dryRun:false, onEntry:function(e){seen.push(e);}});
  } catch (err) { ret='threw:'+((err&&err.name)||'Error'); }
  const sum=tally?Object.keys(tally).reduce(function(a,k){return a+tally[k];},0):-1;
  console.log('R='+ret+' ENTRIES='+seen.length+' SUM='+sum+
              ' PRUNED='+(tally?tally.pruned:-1)+' FAILED='+(tally?tally.failed:-1));
}"
  check "L02a: the batch completes and the tally accounts for every plan entry" \
    "R=returned ENTRIES=3 SUM=3 PRUNED=2 FAILED=1" "$NODE_OUT"
  s1="$(session_path "$proj/stub-a" "$SID_A")"
  s3="$(session_path "$proj/stub-c" "$SID_C")"
  check_no_file "L02b: the first well-formed entry was displaced" "$s1"
  check_file "L02c: and its rescue copy exists, so the report can be trusted" "$s1.bak"
  check_no_file "L02d: the third well-formed entry was displaced too" "$s3"
  check_file "L02e: with its own rescue copy" "$s3.bak"
  check_file "L02f: the malformed entry's stub is untouched" \
    "$(session_path "$proj/stub-b" "$SID_B")"
  check_no_file "L02g: and nothing was written beside it" \
    "$(session_path "$proj/stub-b" "$SID_B").bak"
}

# ---- L2: both files must live under the roots the plan states for them -------

run_l_containment() {
  local proj h stub real out_dir

  # L03 — decision.file outside decision.root. The plan points `root` at a directory the
  # user would recognise while `file` names a stub somewhere else entirely; today only the
  # basenames are looked at, so the mismatch is invisible.
  proj="$(guard_fixture)"; h="$(hash_of "$(session_path "$proj/stub" "$SID_A")")"
  containment_case "$proj" "cand.root=path.join(root,'other');"
  check "L03a: a decision.file outside its stated root is refused" \
    "E=failed:not-a-counterpart R=returned" "$NODE_OUT"
  guard_survives "L03b" "$proj" "$h"

  # L04 — the same rule on the evidence side: via.file outside via.root.
  proj="$(guard_fixture)"; h="$(hash_of "$(session_path "$proj/stub" "$SID_A")")"
  containment_case "$proj" "cand.via={root:path.join(root,'other'),file:cand.via.file};"
  check "L04a: a via.file outside its stated root is refused" \
    "E=failed:not-a-counterpart R=returned" "$NODE_OUT"
  guard_survives "L04b" "$proj" "$h"

  # L05 — the sibling-prefix trap. `<x>/rootlike` starts with `<x>/root` as a STRING and is
  # not inside it as a PATH. A containment check written with startsWith accepts it, which
  # is how this class of guard is usually got wrong; the segment boundary is the whole
  # point. Driven at the module boundary in both separator spellings, because the Windows
  # spelling is a different string and the same directory.
  out_dir="$(new_dir)"
  mkdir -p "$out_dir/root" "$out_dir/rootlike"
  { title_line "$SID_A" "Alpha"; } | mk_session "$out_dir/rootlike" "$SID_A"
  { content_line "$SID_A"; } | mk_session "$out_dir/root" "$SID_A"
  stub="$(native_file "$(session_path "$out_dir/rootlike" "$SID_A")")"
  real="$(native_file "$(session_path "$out_dir/root" "$SID_A")")"
  containment_call "$stub" "$(native_path "$out_dir/root")" \
    "$real" "$(native_path "$out_dir/root")"
  check "L05a: a sibling directory sharing the root's name prefix is not contained" \
    "C=false" "$NODE_OUT"
  containment_call "$(printf '%s' "$stub" | tr '/' '\\')" \
    "$(printf '%s' "$(native_path "$out_dir/root")" | tr '/' '\\')" \
    "$real" "$(native_path "$out_dir/root")"
  check "L05b: and the backslash spelling of the same pair is not contained either" \
    "C=false" "$NODE_OUT"

  # L06 — Pattern 4, direction one: a properly contained pair still prunes. A containment
  # check that rejects everything would satisfy L03-L05 and disable the feature.
  proj="$(guard_fixture)"
  containment_case "$proj" "void 0;"
  check "L06a: a properly contained pair still prunes" \
    "E=pruned:- R=returned" "$NODE_OUT"
  check_no_file "L06b: the stub was displaced" "$(session_path "$proj/stub" "$SID_A")"

  # L07 — Pattern 4, direction two: containment is decided after CANONICALIZATION, not by
  # string matching. A root and a file spelled with redundant `.` and `..` segments that
  # still resolve inside the root are legitimate, and a startsWith-on-raw-strings check
  # would reject them.
  # Built by concatenation, not by path.join: join normalizes the segments away, and a
  # pre-normalized string would leave the canonicalization untested.
  proj="$(guard_fixture)"
  containment_case "$proj" \
    "const S=path.sep;
     cand.root=root+S+'stub'+S+'..'+S+'.'+S+'stub';
     cand.file=root+S+'other'+S+'..'+S+'stub'+S+'.'+S+'$SID_A.jsonl';
     cand.via={root:root+S+'.'+S+'real',
               file:root+S+'real'+S+'..'+S+'real'+S+'$SID_A.jsonl'};"
  check "L07a: redundant . and .. segments that still resolve inside the root are accepted" \
    "E=pruned:- R=returned" "$NODE_OUT"
  check_no_file "L07b: the stub was displaced" "$(session_path "$proj/stub" "$SID_A")"
  check_file "L07c: the counterpart survives" "$(session_path "$proj/real" "$SID_A")"
}

# ---- L3: the tally is a fixed set of seven numeric counters -----------------

run_l_tally_prototype() {
  local proj key

  # L08 — a plan entry whose `action` is an Object.prototype member name. executePrunePlan
  # copies a non-candidate action straight into the outcome state, so the state string is
  # caller-controlled, and `TALLY_KEY[state]` then resolves to an inherited function or
  # object. `tally[thatKey] += 1` writes a bogus own property (NaN) onto the returned
  # object, which every consumer of the tally — the report line, the exit code — then reads
  # as a real counter. `unknown-state` is the ordinary case and is asserted alongside each
  # forged one, so the two must land in the same place.
  for key in "constructor" "__proto__" "toString" "hasOwnProperty" "unknown-state"; do
    proj="$(guard_fixture)"
    A_ROOT="$(native_path "$proj")" A_KEY="$key" node_m "
const m=require('$REQUIRE_PATH');
const planned=m.planPruneRoots({roots:[process.env.A_ROOT]});
const cand=planned.plan.filter(function(d){return d.action==='prune-candidate';})[0];
cand.action=process.env.A_KEY;
const tally=m.executePrunePlan({plan:[cand], dryRun:false, onEntry:function(){}});
const WANT=['pruned','wouldPrune','kept','changed','unreadable','unclassified','failed'];
const keys=Object.keys(tally).sort();
const nonNumeric=keys.filter(function(k){return typeof tally[k]!=='number'||!isFinite(tally[k]);});
const sum=WANT.reduce(function(a,k){return a+(tally[k]||0);},0);
console.log('KEYS='+keys.join(',')+' BAD='+(nonNumeric.join(',')||'-')+' SUM='+sum);"
    check "L08[$key]: an unknown state corrupts no tally slot" \
      "KEYS=changed,failed,kept,pruned,unclassified,unreadable,wouldPrune BAD=- SUM=0" \
      "$NODE_OUT"
    check_file "L08[$key]-safe: and the stub is left alone" \
      "$(session_path "$proj/stub" "$SID_A")"
  done

  # L09 — Pattern 4. All seven known states still tally, so the lookup was hardened rather
  # than disabled. Driven straight through executePrunePlan with a synthetic plan: these are
  # the seven action values the planner can emit, and the tally is the only place they are
  # ever counted.
  node_m "
const x=require('$EXECUTE_REQUIRE');
const plan=['keep','would-prune','changed','unreadable','unclassified','failed']
  .map(function(a){return {action:a, file:'/nowhere/x.jsonl', root:'/nowhere'};});
const tally=x.executePrunePlan({plan:plan, dryRun:false, onEntry:function(){}});
console.log('K='+tally.kept+' W='+tally.wouldPrune+' C='+tally.changed+
            ' U='+tally.unreadable+' N='+tally.unclassified+' F='+tally.failed+
            ' P='+tally.pruned);"
  check "L09: every known state still increments its own counter and no other" \
    "K=1 W=1 C=1 U=1 N=1 F=1 P=0" "$NODE_OUT"
}

# SKIPPED: a plan whose `root` or `via.root` points at a path the process cannot stat
#          (EACCES on an intermediate directory), where canonicalization itself fails.
# Because: chmod is advisory on this host — the suite's deny_read() probe already returns
#          non-zero here, and the containment check is specified to fall back to the
#          uncanonicalized comparison rather than throw, which cannot be distinguished
#          without a genuinely unreadable directory.
# L3 gap:  a POSIX host with a real permission boundary between the root and the file,
#          which is the only place the fallback branch is reachable.

run_l_via_root_type
run_l_batch_survives_bad_entry
run_l_containment
run_l_tally_prototype
