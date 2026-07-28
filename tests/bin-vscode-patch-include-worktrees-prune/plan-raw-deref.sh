# Part of tests/bin-vscode-patch-include-worktrees-prune.sh (sourced, not standalone).
# Tests: bin/lib/vscode-patch-include-worktrees/prune/execute.js, bin/lib/vscode-patch-include-worktrees/prune.js
# Tags: bin, vscode, prune, execute, security, type-safety, tally, session-files, scope:common, pwsh-not-required, TL2
#
# M — the remaining RAW dereferences of a caller-supplied plan: two of its FIELDS
# (M01-M05 below), and the plan's own ELEMENTS (M10-M12 at the foot of this file).
# The third field, `decision.titleKeys`, has its own part: plan-title-keys.sh (M06-M09).
#
# L1 (plan-containment.sh) closed `via.root`: it is typechecked as a string at the head of
# isCounterpartPath precisely because path.relative dereferences it afterwards. Two fields
# of the SAME class were left raw, and both reach a path API that throws on a non-string:
#
#   M1 — `decision.file`. prunable() hands it to classifySessionFile (which coerces with
#        String() for the session id but passes the value ITSELF to fs, and fs accepts a
#        Buffer path), and then to `path.basename(decision.file)` — unwrapped — for the
#        SESSION_FILE_PATTERN re-assertion. A Buffer therefore classifies as a `stub` and
#        blows up one line later.
#   M2 — `via.file`. isCounterpartPath coerces it with String() at every one of its own
#        comparisons, so an Array of one path string, or any object with a matching
#        toString, satisfies all five conditions and returns true. `path.relative(via.root,
#        via.file)` on the next line then receives the UNCOERCED value and throws.
#
# Neither throw is caught in prunable() or in executePrunePlan(), so the exception unwinds
# the whole batch: entries already renamed are never reported, the tally is never returned,
# and the user is left with displaced files and no record of them. That is the same failure
# L02 pins for `via.root`, reached through two other doors — the class, not the member
# (CPR-4/CPR-5).
#
# WHAT IS OWED. A malformed plan is a CALLER error, which this suite has already ruled
# belongs in `failed` rather than in an observation bucket that invites a re-run (J04, where
# a missing `via` reported `unreadable` and had to become `failed:not-a-counterpart`). The
# same ruling decides these rows: every non-string spelling of `decision.file` is
# `failed:not-a-session-file` (the boundary that site exists to assert) and every non-string
# spelling of `via.file` is `failed:not-a-counterpart`, on EVERY type — a `null` that is
# rejected while a Buffer crashes is not a boundary, it is a coincidence. Today six of the
# seven `decision.file` spellings report `unreadable:ERR_INVALID_ARG_TYPE`, which is fs's
# complaint about a caller error dressed as a disk fault.
#
# The type coverage is TABLE-DRIVEN (skills/_shared/test-design/parser-regex-tests.md): the
# same site, the same assertion, seven input types, the case name in every message.

# ---- drivers ---------------------------------------------------------------

# Plans for real, applies <js> to the candidate, executes for real, and renders BOTH the
# entry outcome and whether the call returned at all — a throw is the failure mode under
# test, so it is caught and rendered rather than allowed to abort the driver.
deref_case() { # <projects-root> <js-mutating-cand> ; sets NODE_OUT
  A_ROOT="$(native_path "$1")" node_m "
const m=require('$REQUIRE_PATH');
const path=require('path');
const root=process.env.A_ROOT;
const planned=m.planPruneRoots({roots:[root]});
const cand=planned.plan.filter(function(d){return d.action==='prune-candidate';})[0];
if (!cand) { console.log('E=no-candidate:- R=returned'); } else {
  $2
  const seen=[];
  let ret='returned';
  try {
    m.executePrunePlan({plan:[cand], dryRun:false, onEntry:function(e){seen.push(e);}});
  } catch (err) { ret='threw:'+((err && err.code) ? err.code : ((err && err.name) || 'Error')); }
  const e=seen[0]||{};
  console.log('E='+(e.state||'-')+':'+(e.reason||'-')+' R='+ret);
}"
}

# A three-entry batch whose MIDDLE entry is malformed, mutated by <js> applied to `bad`.
# The subject is not the malformed entry — it is the two well-formed ones around it and the
# tally that has to account for all three.
deref_batch() { # <projects-root> <js-mutating-bad> ; sets NODE_OUT
  A_ROOT="$(native_path "$1")" node_m "
const m=require('$REQUIRE_PATH');
const planned=m.planPruneRoots({roots:[process.env.A_ROOT]});
// Deterministic order: the middle entry is the one that gets the malformed field.
const cands=planned.plan.filter(function(d){return d.action==='prune-candidate';})
  .sort(function(a,b){return a.file<b.file?-1:1;});
if (cands.length!==3) { console.log('N='+cands.length); } else {
  const bad=cands[1];
  $2
  const seen=[]; let ret='returned', tally=null;
  try {
    tally=m.executePrunePlan({plan:cands, dryRun:false, onEntry:function(e){seen.push(e);}});
  } catch (err) { ret='threw:'+((err&&err.name)||'Error'); }
  const sum=tally?Object.keys(tally).reduce(function(a,k){return a+tally[k];},0):-1;
  console.log('R='+ret+' ENTRIES='+seen.length+' SUM='+sum+
              ' PRUNED='+(tally?tally.pruned:-1)+' FAILED='+(tally?tally.failed:-1));
}"
}

# The batch fixture: three independent stub/counterpart pairs, so two entries survive the
# malformed one on either side of it.
deref_batch_fixture() { # ; prints the projects root
  local proj
  proj="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; }   | mk_session "$proj/stub-a" "$SID_A"
  { content_line "$SID_A"; }         | mk_session "$proj/real-a" "$SID_A"
  { title_line "$SID_B" "Bravo"; }   | mk_session "$proj/stub-b" "$SID_B"
  { content_line "$SID_B"; }         | mk_session "$proj/real-b" "$SID_B"
  { title_line "$SID_C" "Charlie"; } | mk_session "$proj/stub-c" "$SID_C"
  { content_line "$SID_C"; }         | mk_session "$proj/real-c" "$SID_C"
  printf '%s' "$proj"
}

# ---- M1: decision.file must be a string at the basename boundary -------------

# Every spelling names the REAL stub — `String(value)` is the genuine path — so a fix that
# merely coerces would prune the file and this row would catch it: the assertion is
# `failed` plus survival, never "it did not crash".
run_m_decision_file_type() {
  local name expr want proj h
  while IFS='|' read -r name expr want; do
    if [ -z "$name" ]; then continue; fi
    case "$name" in \#*|*[[:space:]]\#*) continue ;; esac
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    proj="$(guard_fixture)"; h="$(hash_of "$(session_path "$proj/stub" "$SID_A")")"
    deref_case "$proj" "cand.file=$expr;"
    check "M01[$name]a: a non-string decision.file is a caller error, not a crash" \
      "E=$want R=returned" "$NODE_OUT"
    guard_survives "M01[$name]b" "$proj" "$h"
  done <<TABLE
array     | [path.join(root,'stub','$SID_A.jsonl')]                                       | failed:not-a-session-file
buffer    | Buffer.from(path.join(root,'stub','$SID_A.jsonl'))                            | failed:not-a-session-file
number    | 42                                                                            | failed:not-a-session-file
object    | ({})                                                                          | failed:not-a-session-file
tostring  | ({toString:function(){return path.join(root,'stub','$SID_A.jsonl');}})        | failed:not-a-session-file
null      | null                                                                          | failed:not-a-session-file
undefined | undefined                                                                     | failed:not-a-session-file
TABLE
}

# ---- M2: via.file must be a string at the path.relative dereference ----------

# `via.root` is left as the planner produced it, so containment and the basename compare are
# all satisfied by the coerced value: these rows isolate the TYPE of via.file and nothing
# else. Three of the seven currently reach path.relative and throw.
run_m_via_file_type() {
  local name expr want proj h
  while IFS='|' read -r name expr want; do
    if [ -z "$name" ]; then continue; fi
    case "$name" in \#*|*[[:space:]]\#*) continue ;; esac
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    proj="$(guard_fixture)"; h="$(hash_of "$(session_path "$proj/stub" "$SID_A")")"
    deref_case "$proj" "cand.via.file=$expr;"
    check "M02[$name]a: a non-string via.file is a caller error, not a crash" \
      "E=$want R=returned" "$NODE_OUT"
    guard_survives "M02[$name]b" "$proj" "$h"
  done <<TABLE
array     | [path.join(root,'real','$SID_A.jsonl')]                                       | failed:not-a-counterpart
buffer    | Buffer.from(path.join(root,'real','$SID_A.jsonl'))                            | failed:not-a-counterpart
number    | 42                                                                            | failed:not-a-counterpart
object    | ({})                                                                          | failed:not-a-counterpart
tostring  | ({toString:function(){return path.join(root,'real','$SID_A.jsonl');}})        | failed:not-a-counterpart
null      | null                                                                          | failed:not-a-counterpart
undefined | undefined                                                                     | failed:not-a-counterpart
TABLE
}

# ---- M3: the batch runs to completion, once per site ------------------------

# The load-bearing property. A refused entry costs that entry; a THROWN entry costs the
# report for every entry that was already displaced before it — the difference between a
# caller error and silent data loss the user cannot even enumerate.
run_m_batch_survives() {
  local proj sa sb sc

  # M03 — the decision.file door. Buffer is the spelling that actually reaches
  # path.basename today: fs accepts a Buffer path, so classifySessionFile reads the file
  # and returns `stub`, and the SESSION_FILE_PATTERN re-assertion then throws.
  proj="$(deref_batch_fixture)"
  deref_batch "$proj" "bad.file=Buffer.from(bad.file);"
  check "M03a: a Buffer decision.file mid-batch does not abort the batch" \
    "R=returned ENTRIES=3 SUM=3 PRUNED=2 FAILED=1" "$NODE_OUT"
  sa="$(session_path "$proj/stub-a" "$SID_A")"
  sb="$(session_path "$proj/stub-b" "$SID_B")"
  sc="$(session_path "$proj/stub-c" "$SID_C")"
  check_no_file "M03b: the entry before the malformed one was displaced" "$sa"
  check_file "M03c: and its rescue copy exists, so the report can be trusted" "$sa.bak"
  check_no_file "M03d: the entry after the malformed one was displaced too" "$sc"
  check_file "M03e: with its own rescue copy" "$sc.bak"
  check_file "M03f: the malformed entry's stub is untouched" "$sb"
  check_no_file "M03g: and nothing was written beside it" "$sb.bak"

  # M04 — the via.file door. A one-element Array whose element is the genuine counterpart
  # path: String() unwraps it, so every condition in isCounterpartPath is satisfied and
  # path.relative receives the Array.
  proj="$(deref_batch_fixture)"
  deref_batch "$proj" "bad.via.file=[bad.via.file];"
  check "M04a: an Array via.file mid-batch does not abort the batch" \
    "R=returned ENTRIES=3 SUM=3 PRUNED=2 FAILED=1" "$NODE_OUT"
  sa="$(session_path "$proj/stub-a" "$SID_A")"
  sb="$(session_path "$proj/stub-b" "$SID_B")"
  sc="$(session_path "$proj/stub-c" "$SID_C")"
  check_no_file "M04b: the entry before the malformed one was displaced" "$sa"
  check_file "M04c: and its rescue copy exists" "$sa.bak"
  check_no_file "M04d: the entry after the malformed one was displaced too" "$sc"
  check_file "M04e: with its own rescue copy" "$sc.bak"
  check_file "M04f: the malformed entry's stub is untouched" "$sb"
  check_no_file "M04g: and nothing was written beside it" "$sb.bak"

  # M05 — Pattern 4. The same three-entry batch with NOTHING malformed, through the
  # identical driver: a type guard that rejected a legitimate string would satisfy every
  # row above and disable the feature.
  proj="$(deref_batch_fixture)"
  deref_batch "$proj" "void bad;"
  check "M05a: an all-well-formed batch of the same shape prunes every entry" \
    "R=returned ENTRIES=3 SUM=3 PRUNED=3 FAILED=0" "$NODE_OUT"
  check_no_file "M05b: the middle entry is displaced when it is well-formed" \
    "$(session_path "$proj/stub-b" "$SID_B")"
  check_file "M05c: with its own rescue copy" \
    "$(session_path "$proj/stub-b" "$SID_B").bak"
}

# ---- M10-M12: the plan's ELEMENTS, not just its container -------------------
#
# `Array.isArray(opts.plan)` guards the container and nothing inside it. The very first
# thing done to each element is `decision.action`, so a `null` or `undefined` element throws
# `Cannot read properties of null (reading 'action')` before any outcome exists — the same
# batch-abandoning failure M03/M04 pin, reached through the outermost door of all. A
# primitive element does not throw there but is worse in a quieter way: `42..action` is
# undefined, so the state is undefined, TALLY_KEY.get(undefined) misses, and the entry is
# reported to onEntry while being counted NOWHERE. The tally then sums to less than the plan
# length and the report silently under-states what the run looked at.
#
# An Array element is included deliberately: it is an object, so it survives a `typeof`
# check, and it carries no `action` — which is the untallied hole above, not a crash. A plan
# entry is a plain object or it is not a plan entry.
#
# `not-a-plan-entry` is its own reason for the same grounds as the other two: the existing
# tokens accuse a path (`not-a-session-file`) or the evidence (`not-a-counterpart`), and here
# there is no path and no evidence to accuse — the element never had the shape to carry one.
#
# WHY PLAIN OBJECTS ARE IN THE TABLE TOO. `{}`, `{action:null}` and `{action:''}` are the
# spellings a shape-only guard misses: they pass `typeof x === 'object'`, they pass a
# not-null check, they pass a "not an Array" check — and they still land in the untallied
# hole, because `decision.action` is not a usable verdict and TALLY_KEY misses whatever
# `outcome.state` ends up being. A guard written as "is it a plain object?" leaves the
# original defect exactly where it was for these three while turning every other row green.
# What is owed is a guard on the FIELD the loop reads next: the element must be a plain
# object AND carry a non-empty string `action`.
#
# The boundary is drawn by M10c below: an action that is a non-empty string but not one this
# executor knows is NOT a caller error and must pass through untouched. The guard is about
# shape, not vocabulary — pinning the vocabulary here would silently break the next action
# name the planner learns to emit.

# A one-element plan whose single element IS the malformed value. No fixture: none of these
# spellings can name a file, so there is nothing on disk for them to touch. The onEntry
# callback renders the payload the way a real consumer does, because assembling that payload
# dereferences `decision.file` and is the SECOND place a null element can throw.
deref_element_case() { # <js-element-expr> ; sets NODE_OUT
  node_m "
const m=require('$EXECUTE_REQUIRE');
const seen=[];
let ret='returned', tally=null;
try {
  tally=m.executePrunePlan({plan:[$1], dryRun:false, onEntry:function(e){
    seen.push(String(e.state)+'|'+String(e.reason)+'|'+String(e.file));
  }});
} catch (err) { ret='threw:'+((err&&err.name)||'Error'); }
const parts=(seen[0]||'-|-|-').split('|');
console.log('E='+parts[0]+':'+parts[1]+' R='+ret+' FAILED='+(tally?tally.failed:-1));"
}

run_m_plan_element_type() {
  local name expr
  while IFS='|' read -r name expr; do
    if [ -z "$name" ]; then continue; fi
    case "$name" in \#*|*[[:space:]]\#*) continue ;; esac
    name="${name//[[:space:]]/}"
    deref_element_case "$expr"
    check "M10[$name]: a non-entry in the plan is a caller error, counted and not thrown" \
      "E=failed:not-a-plan-entry R=returned FAILED=1" "$NODE_OUT"
  done <<TABLE
null        | null
undefined   | undefined
number      | 42
string      | 'not-a-decision'
boolean     | true
array       | []
empty-obj   | ({})
action-null | ({action:null, file:'/nowhere/x.jsonl', root:'/nowhere'})
action-empty| ({action:'', file:'/nowhere/x.jsonl', root:'/nowhere'})
TABLE
}

# M10c — Pattern 4 for the shape/vocabulary boundary drawn above. An element that is a plain
# object carrying a non-empty string action the executor does not know is well-formed: the
# loop's own else-branch already answers it, and the new guard must not intercept it. This
# row is green today and must stay green — it is what stops the guard from being written as
# a whitelist of action names.
run_m_plan_element_unknown_action() {
  deref_element_case "({action:'something-else', reason:'unknown-verdict', file:'/nowhere/x.jsonl', root:'/nowhere'})"
  check "M10c: an unknown but well-formed action is passed through, not rejected" \
    "E=something-else:unknown-verdict R=returned FAILED=0" "$NODE_OUT"
}

# M11 — the load-bearing property, once more at this site: a malformed element costs that
# element, never the report for the entries already displaced beside it.
run_m_plan_element_batch_survives() {
  local proj sa sb sc
  proj="$(deref_batch_fixture)"
  deref_batch "$proj" "cands[1]=null;"
  check "M11a: a null plan element mid-batch does not abort the batch" \
    "R=returned ENTRIES=3 SUM=3 PRUNED=2 FAILED=1" "$NODE_OUT"
  sa="$(session_path "$proj/stub-a" "$SID_A")"
  sb="$(session_path "$proj/stub-b" "$SID_B")"
  sc="$(session_path "$proj/stub-c" "$SID_C")"
  check_no_file "M11b: the entry before the null element was displaced" "$sa"
  check_file "M11c: and its rescue copy exists, so the report can be trusted" "$sa.bak"
  check_no_file "M11d: the entry after the null element was displaced too" "$sc"
  check_file "M11e: with its own rescue copy" "$sc.bak"
  check_file "M11f: the stub the null element replaced is untouched" "$sb"
  check_no_file "M11g: and nothing was written beside it" "$sb.bak"
}

# M12 — Pattern 4 for the element guard. A well-formed plan of the SAME shape driven through
# the same one-element driver: a guard that rejected every entry would satisfy M10 and
# disable the executor outright, and M05 cannot see it because it never goes through here.
run_m_plan_element_control() {
  node_m "
const x=require('$EXECUTE_REQUIRE');
const seen=[];
let ret='returned', tally=null;
try {
  tally=x.executePrunePlan({plan:[{action:'keep', reason:'has-real-copy',
    file:'/nowhere/x.jsonl', root:'/nowhere'}], dryRun:false,
    onEntry:function(e){seen.push(String(e.state)+'|'+String(e.reason));}});
} catch (err) { ret='threw:'+((err&&err.name)||'Error'); }
const parts=(seen[0]||'-|-').split('|');
console.log('E='+parts[0]+':'+parts[1]+' R='+ret+' KEPT='+(tally?tally.kept:-1));"
  check "M12: a well-formed element through the same driver is still tallied normally" \
    "E=kept:has-real-copy R=returned KEPT=1" "$NODE_OUT"
}

# SKIPPED: a `decision.root` / `via.root` of a non-string type.
# Because: plan-containment.sh L01 already drives via.root through undefined/null/42/{},
#          and isWithinRoot's `typeof root !== 'string'` guard covers decision.root by the
#          same line. Repeating them here would duplicate a covered site.
# L3 gap:  a plan arriving from a genuinely foreign caller (a JSON round-trip, an IPC
#          boundary) where the field types are whatever the wire produced. Every row here
#          forges the value in-process, so the shapes are the ones a reviewer thought of.

run_m_decision_file_type
run_m_via_file_type
run_m_batch_survives
run_m_plan_element_type
run_m_plan_element_unknown_action
run_m_plan_element_batch_survives
run_m_plan_element_control
