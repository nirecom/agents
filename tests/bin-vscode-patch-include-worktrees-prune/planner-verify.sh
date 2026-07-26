# Part of tests/bin-vscode-patch-include-worktrees-prune.sh (sourced, not standalone).
# B + C — the two halves of the deletion decision.
#
# B: planPrune is a pure function over an already-classified group, so it is driven
#    table-style with constructed verdict objects. No fixtures, no I/O: the whole
#    point is that the decision is separable from the reading.
# C: verifyCounterpart is the I3 (superset) proof and the single reason the "no
#    backup" tradeoff in intent.md is admissible — a stub may only be deleted once the
#    counterpart is shown to already carry every one of its titles. It is fixture-based
#    because "read the counterpart to the very end" is itself part of the contract.
#    verifyCounterpart only ever sees ONE counterpart, so the rule for a stub with
#    several real copies — try them in turn, prune on the first that verifies, and
#    when they all fail report the HEAVIEST state (observation failure outranks a
#    decision reached) — belongs to the caller and is exercised through the real
#    two-phase path (C09-C12).
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

# stubTitleKeys is taken from a real classifySessionFile run rather than hand-built,
# so the two functions are pinned against the SAME key normalization; a drift in the
# key format would break this call rather than silently pass a mismatched set.
verify_call() { # <counterpart-file> <stub-file> <sessionId> ; sets NODE_OUT
  V_CP="$(native_file "$1")" V_STUB="$(native_file "$2")" V_SID="$3" \
    node_m 'const m=require("'"$REQUIRE_PATH"'");
const stub=m.classifySessionFile(process.env.V_STUB);
const r=m.verifyCounterpart(process.env.V_CP, stub.titleKeys, process.env.V_SID);
console.log("OK="+(r.ok===true)+" R="+(r.reason||"-"));'
}

run_c_verify_counterpart() {
  local sd cd stub cp

  # C01 — the sanctioned direction: the counterpart carries a content record for this
  # session AND every one of the stub's titles.
  sd="$(new_dir)"; cd="$(new_dir)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$sd" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$cd" "$SID_A"
  stub="$(session_path "$sd" "$SID_A")"; cp="$(session_path "$cd" "$SID_A")"
  verify_call "$cp" "$stub" "$SID_A"
  check "C01: counterpart covering every stub title verifies" "OK=true R=-" "$NODE_OUT"

  # C02 — the case the whole superset rule exists for: deleting here would destroy a
  # title that survives nowhere else.
  sd="$(new_dir)"; cd="$(new_dir)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$sd" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Bravo"; } | mk_session "$cd" "$SID_A"
  verify_call "$(session_path "$cd" "$SID_A")" "$(session_path "$sd" "$SID_A")" "$SID_A"
  check "C02: a counterpart without the stub's title is refused" \
    "OK=false R=title-not-covered" "$NODE_OUT"

  # C03 — partial coverage is not coverage.
  sd="$(new_dir)"; cd="$(new_dir)"
  { title_line "$SID_A" "Alpha"; title_line "$SID_A" "Bravo"; } | mk_session "$sd" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$cd" "$SID_A"
  verify_call "$(session_path "$cd" "$SID_A")" "$(session_path "$sd" "$SID_A")" "$SID_A"
  check "C03: covering one of two stub titles is refused" \
    "OK=false R=title-not-covered" "$NODE_OUT"

  # C04 — proof that verification reads the counterpart to EOF. classifySessionFile is
  # allowed to stop early on positive evidence; verifyCounterpart is not, because a
  # title can legitimately be the last record written.
  sd="$(new_dir)"; cd="$(new_dir)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$sd" "$SID_A"
  { content_line "$SID_A"; content_line "$SID_A" assistant; content_line "$SID_A" summary
    content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$cd" "$SID_A"
  verify_call "$(session_path "$cd" "$SID_A")" "$(session_path "$sd" "$SID_A")" "$SID_A"
  check "C04: a matching title on the counterpart's LAST line still verifies" \
    "OK=true R=-" "$NODE_OUT"

  # C05 — I2 re-confirmed at verification time: titles alone are not a transcript.
  sd="$(new_dir)"; cd="$(new_dir)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$sd" "$SID_A"
  { title_line "$SID_A" "Alpha"; content_line "$SID_B"; } | mk_session "$cd" "$SID_A"
  verify_call "$(session_path "$cd" "$SID_A")" "$(session_path "$sd" "$SID_A")" "$SID_A"
  check "C05: a counterpart with no matching content record is refused" \
    "OK=false R=no-content" "$NODE_OUT"
}

# C06 — VERIFY_MAX_SCAN. The counterpart is deliberately larger than the 64 MiB cap,
# so full coverage cannot be established: this is an OBSERVATION FAILURE
# (`unclassified`, exit 1), not a decision to keep. One 64 MiB fixture is written; the
# cheaper 1 MiB classify cap carries the CLI-level exit-code row (cli-exit-codes.sh).
run_c_verify_truncated() {
  local sd cd stub cp
  sd="$(new_dir)"; cd="$(new_dir)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$sd" "$SID_A"
  mkdir -p "$cd"
  cp="$(session_path "$cd" "$SID_A")"
  gen_big "$cp" "$SID_A" $((VERIFY_MAX_SCAN + 128)) title content none
  stub="$(session_path "$sd" "$SID_A")"
  verify_call "$cp" "$stub" "$SID_A"
  check "C06: a counterpart past VERIFY_MAX_SCAN reports verify-truncated" \
    "OK=false R=verify-truncated" "$NODE_OUT"
  rm -f "$cp"
}

# C07 — an unreadable counterpart. Same probe-first discipline as classifier.sh A20.
run_c_verify_unreadable() {
  local sd cd stub cp
  sd="$(new_dir)"; cd="$(new_dir)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$sd" "$SID_A"
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
  verify_call "$cp" "$(session_path "$sd" "$SID_A")" "$SID_A"
  check "C07: an unreadable counterpart reports unreadable" \
    "OK=false R=unreadable" "$NODE_OUT"
}

# C08 — two real copies, only one of which is a superset. The prune must still happen,
# and `via=` must name the copy that actually justified it: without that field the
# report cannot be audited after the fact. Driven end to end so the `via=` formatting
# (a cli.js responsibility) is covered too. The two counterparts share a basename by
# definition, so only the directory name distinguishes them in the report.
run_c_via_selection() {
  local home ext proj line
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$proj/stub" "$SID_A"
  # viano: a genuine transcript for this session, but it never carried this title.
  { content_line "$SID_A"; title_line "$SID_A" "Bravo"; } | mk_session "$proj/viano" "$SID_A"
  # viayes: the only copy that covers the stub's title.
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$proj/viayes" "$SID_A"

  run_cli_prune "$home" "$ext" "$proj" --dry-run
  check "C08a: exit 0" "0" "$CLI_RC"
  check_token "C08b: the stub is reported as a would-prune" "would-prune" "$CLI_OUT"
  line="$(prune_line "would-prune" "$CLI_OUT")"
  check_contains "C08c: the report names the covering counterpart in via=" "viayes" "$line"
  check_absent "C08d: the non-covering counterpart is not credited" "viano" "$line"
  check_file "C08e: --dry-run left the stub in place" "$(session_path "$proj/stub" "$SID_A")"
}

# ---- C2: aggregation across several counterparts ---------------------------

# C08 shows the happy half of the multi-counterpart rule (one copy covers, so the prune
# happens). C09-C12 cover the half that decides whether a failure is visible at all: if
# the state reported for the stub were taken from the LAST candidate tried, or from the
# first decision-reached one, an observation failure would be silently downgraded to
# `kept` and the run would exit 0 while a file's fate was never actually established.

# Renders the entry describing the stub as `E=<state>:<scope|->`. The two-phase path is
# driven directly (as in lifecycle-race.sh) because a counterpart that classifies as
# `real` but cannot be READ at verification time is only reachable by mutating the tree
# between the two phases — a file that was already unreadable during the scan never
# becomes a candidate in the first place (planPrune row B06).
# The reason field is deliberately NOT asserted: the errno for reading a directory is
# host-dependent (EISDIR / EPERM), while the state and scope are the contract.
agg_entry() { # <projects-root> [counterpart-file-to-make-unreadable] ; sets NODE_OUT
  local hostile=""
  [ -n "${2:-}" ] && hostile="$(native_file "$2")"
  A_ROOT="$(native_path "$1")" A_HOSTILE="$hostile" \
    node_m "
const m=require('$REQUIRE_PATH');
const fs=require('fs');
const planned=m.planPruneRoots({roots:[process.env.A_ROOT]});
const h=process.env.A_HOSTILE;
if (h) { fs.unlinkSync(h); fs.mkdirSync(h); fs.writeFileSync(h+'/placeholder',''); }
const seen=[];
m.executePrunePlan({plan:planned.plan, dryRun:false, onEntry:function(e){seen.push(e);}});
const hit=seen.filter(function(e){
  return String(e.file).replace(/\\\\/g,'/').indexOf('/stub/')>=0;
})[0]||{};
console.log('E='+(hit.state||'-')+':'+(hit.scope||'-'));"
}

# Same probe-first discipline as C07: the swap trick above only produces an unreadable
# counterpart on hosts where reading a directory faults.
dir_read_faults() {
  local d
  d="$(new_dir)/asdir"
  mkdir -p "$d"
  : > "$d/placeholder"
  FIXFILE="$(native_file "$d")" node_m 'const fs=require("fs");
try { fs.readFileSync(process.env.FIXFILE); console.log("P=readable"); }
catch (e) { console.log("P=faulted"); }'
  [ "$NODE_OUT" = "P=faulted" ]
}

# C09 — two real counterparts, BOTH failing, with different severities: one is merely
# not a superset (`kept`, decision reached, exit 0) and one cannot be read at all
# (`unreadable`, observation failed, exit 1). The stub must be reported with the heavier
# of the two. Reporting `kept` here would claim the file was examined and consciously
# retained, when in fact one of its two copies was never observed.
# Control property: without the swap this fixture prunes (cphostile covers the title),
# so a run that reports `kept` cannot be explained by the fixture being unprunable.
run_c_all_counterparts_fail() {
  local root stub
  if ! dir_read_faults; then
    skip_case "C09 mixed-severity aggregation (host does not fault on reading a directory)"
    return 0
  fi
  root="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$root/stub" "$SID_A"
  # cpkept: a genuine transcript that simply never carried this title -> title-not-covered.
  { content_line "$SID_A"; title_line "$SID_A" "Bravo"; } | mk_session "$root/cpkept" "$SID_A"
  # cphostile: covers the title at plan time, unreadable by verification time.
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$root/cphostile" "$SID_A"
  stub="$(session_path "$root/stub" "$SID_A")"

  agg_entry "$root" "$(session_path "$root/cphostile" "$SID_A")"
  check "C09a: when every counterpart fails, the observation failure outranks the kept" \
    "E=unreadable:counterpart" "$NODE_OUT"
  check_file "C09b: nothing is unlinked when no counterpart verifies" "$stub"
  allow_read "$root"
}

# C10 / C11 — the candidate search must not stop at the first failure. The two rows are
# the same situation with the directory names swapped, so whichever order the scan
# happens to enumerate them in, one of the two rows has the FAILING copy first; a
# candidate loop that gave up after one refusal fails at least one of them. Run for real
# (not --dry-run, unlike C08) so the deletion itself is the assertion.
run_c_candidate_search_continues() {
  local home ext proj line
  home="$(new_home)"; ext="$(new_ext_root)"

  # C10 — the non-covering copy sorts first.
  proj="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$proj/stub" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Bravo"; } | mk_session "$proj/cp-a-nocover" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$proj/cp-z-cover" "$SID_A"
  run_cli_prune "$home" "$ext" "$proj"
  check "C10a: exit 0" "0" "$CLI_RC"
  check_contains "C10b: the prune still happens past a failing first candidate" \
    "pruned=1" "$CLI_OUT"
  check_contains "C10c: the failed candidate is not also reported as a keep" \
    "kept=0" "$CLI_OUT"
  line="$(prune_line "pruned" "$CLI_OUT")"
  check_contains "C10d: via= names the covering copy" "cp-z-cover" "$line"
  check_absent "C10e: the non-covering copy is not credited" "cp-a-nocover" "$line"
  check_contains "C10f: the group counts both real copies" "real-copies=2" "$line"
  check_no_file "C10g: the stub is gone" "$(session_path "$proj/stub" "$SID_A")"
  check_file "C10h: the covering copy survives" "$(session_path "$proj/cp-z-cover" "$SID_A")"
  check_file "C10i: the non-covering copy survives" "$(session_path "$proj/cp-a-nocover" "$SID_A")"

  # C11 — the covering copy sorts first: the mirror image, so the pair is order-agnostic.
  proj="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$proj/stub" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$proj/cp-a-cover" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Bravo"; } | mk_session "$proj/cp-z-nocover" "$SID_A"
  run_cli_prune "$home" "$ext" "$proj"
  check "C11a: exit 0" "0" "$CLI_RC"
  check_contains "C11b: the prune happens with the covering copy first too" \
    "pruned=1" "$CLI_OUT"
  line="$(prune_line "pruned" "$CLI_OUT")"
  check_contains "C11c: via= names the covering copy" "cp-a-cover" "$line"
  check_absent "C11d: the non-covering copy is not credited" "cp-z-nocover" "$line"
  check_no_file "C11e: the stub is gone" "$(session_path "$proj/stub" "$SID_A")"
  check_file "C11f: the non-covering copy survives" "$(session_path "$proj/cp-z-nocover" "$SID_A")"
}

# C12 — both counterparts fail as OBSERVATION failures, of the two different kinds:
# one is past VERIFY_MAX_SCAN (`unclassified`, verify-truncated) and one is unreadable.
# Detail plan 3.8 ranks observation failure above decision reached but does NOT define
# an order BETWEEN the two observation-failed states, so the assertion is exactly what
# the plan promises: the reported state is one of them, never `kept`, and the stub is
# not deleted. Pinning a winner here would invent a contract the plan does not state.
run_c_two_observation_failures() {
  local root stub big got
  if ! dir_read_faults; then
    skip_case "C12 two observation failures (host does not fault on reading a directory)"
    return 0
  fi
  root="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$root/stub" "$SID_A"
  # cpbig: a leading content record makes it classify as `real` well inside
  # CLASSIFY_MAX_SCAN, while the body pushes verification past VERIFY_MAX_SCAN.
  mkdir -p "$root/cpbig"
  big="$(session_path "$root/cpbig" "$SID_A")"
  gen_big "$big" "$SID_A" $((VERIFY_MAX_SCAN + 128)) title content none
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$root/cphostile" "$SID_A"
  stub="$(session_path "$root/stub" "$SID_A")"

  agg_entry "$root" "$(session_path "$root/cphostile" "$SID_A")"
  case "$NODE_OUT" in
    E=unreadable:*|E=unclassified:*) got="observation-failed" ;;
    *) got="$NODE_OUT" ;;
  esac
  check "C12a: two observation failures never collapse into a kept" \
    "observation-failed" "$got"
  check_file "C12b: nothing is unlinked when both counterparts are unobservable" "$stub"
  rm -f "$big"
  allow_read "$root"
}

run_b_plan_prune
run_b_lone_stub_invariant
run_c_verify_counterpart
run_c_verify_truncated
run_c_verify_unreadable
run_c_via_selection
run_c_all_counterparts_fail
run_c_candidate_search_continues
run_c_two_observation_failures
