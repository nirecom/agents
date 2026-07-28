# Part of tests/bin-vscode-cc-repair-prune.sh (sourced, not standalone).
# Tests: bin/vscode-cc-repair/prune.js, bin/vscode-cc-repair/prune/execute.js
# Tags: bin, vscode, prune, lifecycle, race, session-files, scope:common, pwsh-not-required, TL2
#
# E — the deletion lifecycle, and the I4 re-verification window.
#
# Sections A-D reason about files that hold still. This section is about the ones that
# do not: the plan is built by reading the tree, and the unlink happens afterwards, so
# every fact the decision rested on has an opportunity to stop being true in between.
# Claude Code writes to these very files while this tool runs, so the window is not
# hypothetical.
#
# The races are injected by driving the real two-phase path directly —
# planPruneRoots (read-only) -> mutate the filesystem -> executePrunePlan (the only
# unlink site). That is not a mock: it is the same plan object the CLI executes, just
# with the window held open deterministically instead of being raced for. Doing it in
# ONE node process matters, because the in-memory plan (titleKeys may be a Set) would
# not survive a round trip through JSON, and a timing-based test would be flaky.

# ---- E1: the ordinary lifecycle, through the CLI ---------------------------

race_fixture() { # sets RACE_ROOT / RACE_STUB / RACE_CP
  RACE_ROOT="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$RACE_ROOT/stub" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$RACE_ROOT/real" "$SID_A"
  RACE_STUB="$(session_path "$RACE_ROOT/stub" "$SID_A")"
  RACE_CP="$(session_path "$RACE_ROOT/real" "$SID_A")"
}

# E01 — --dry-run must be a genuine rehearsal, not an early return. The `via=` field is
# the tell: it can only be filled in if verifyCounterpart (I2) actually ran.
run_e_dry_run() {
  local home ext before line
  home="$(new_home)"; ext="$(new_ext_root)"
  race_fixture
  before="$(hash_of "$RACE_STUB")"
  run_cli_prune "$home" "$ext" "$RACE_ROOT" --dry-run
  check "E01a: exit 0" "0" "$CLI_RC"
  check_token "E01b: the stub is reported as would-prune" "would-prune" "$CLI_OUT"
  check "E01c: no report line claims an actual prune" "" "$(prune_line "pruned" "$CLI_OUT")"
  check_contains "E01d: the summary counts one would-prune" "would-prune=1" "$CLI_OUT"
  check_contains "E01e: the summary counts zero pruned" "pruned=0" "$CLI_OUT"
  check_file "E01f: the stub still exists" "$RACE_STUB"
  check "E01g: the stub is byte-identical" "$before" "$(hash_of "$RACE_STUB")"
  line="$(prune_line "would-prune" "$CLI_OUT")"
  check_contains "E01h: verification still ran during the rehearsal" "via=" "$line"
}

# E02 — the real thing. The counterpart hash is the load-bearing assertion: the point
# of the feature is that the surviving copy is untouched.
run_e_prune() {
  local home ext cp_before
  home="$(new_home)"; ext="$(new_ext_root)"
  race_fixture
  cp_before="$(hash_of "$RACE_CP")"
  run_cli_prune "$home" "$ext" "$RACE_ROOT"
  check "E02a: exit 0" "0" "$CLI_RC"
  check_token "E02b: the stub is reported as pruned" "pruned" "$CLI_OUT"
  check_contains "E02c: the summary counts one pruned" "pruned=1" "$CLI_OUT"
  check_no_file "E02d: the stub is gone" "$RACE_STUB"
  check_file "E02e: the counterpart survives" "$RACE_CP"
  check "E02f: the counterpart is byte-identical" "$cp_before" "$(hash_of "$RACE_CP")"
}

# E03 — a keep verdict is not a soft warning. Nothing that was kept may be unlinked,
# even on a non-dry-run.
run_e_keep_not_deleted() {
  local home ext root stub
  home="$(new_home)"; ext="$(new_ext_root)"; root="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$root/stub" "$SID_A"
  { broken_line; } | mk_session "$root/ind" "$SID_A"
  stub="$(session_path "$root/stub" "$SID_A")"
  run_cli_prune "$home" "$ext" "$root"
  check "E03a: a keep decision is still exit 0" "0" "$CLI_RC"
  check_token "E03b: the stub is reported as kept" "kept" "$CLI_OUT"
  check_contains "E03c: the reason is the lone-stub invariant" "reason=no-real-copy" "$CLI_OUT"
  check_contains "E03d: the summary counts zero pruned" "pruned=0" "$CLI_OUT"
  check_file "E03e: a kept stub is never unlinked" "$stub"
  check_file "E03f: the indeterminate sibling is never unlinked" "$(session_path "$root/ind" "$SID_A")"
}

# E04 — re-running must be a no-op. A second run that reported work would mean the
# first run left the tree in a state it does not recognise as finished.
run_e_idempotent() {
  local home ext
  home="$(new_home)"; ext="$(new_ext_root)"
  race_fixture
  run_cli_prune "$home" "$ext" "$RACE_ROOT"
  check "E04a: first run exits 0" "0" "$CLI_RC"
  check_contains "E04b: first run prunes one file" "pruned=1" "$CLI_OUT"
  run_cli_prune "$home" "$ext" "$RACE_ROOT"
  check "E04c: second run exits 0" "0" "$CLI_RC"
  check_contains "E04d: second run prunes nothing" "pruned=0" "$CLI_OUT"
  check_contains "E04e: second run finds no candidate" "would-prune=0" "$CLI_OUT"
  check_contains "E04f: only the surviving copy remains to scan" "scanned=1" "$CLI_OUT"
  check_file "E04g: the counterpart is still there after two runs" "$RACE_CP"
}

# ---- E2: TOCTOU races R-1 .. R-9 -------------------------------------------

# Serialization: `E=<state>:<reason|->:<scope|->` for the entry describing the stub,
# plus the stub's own presence checked from bash afterwards. The presence check is the
# assertion that actually matters — a correct state string with a deleted file would be
# a report bug hiding data loss.
race_case() { # <name> <mutation-js> <want-E> <present|gone>
  local name="$1" mut="$2" want="$3" want_stub="$4"
  race_fixture
  R_ROOT="$(native_path "$RACE_ROOT")" R_STUB="$(native_file "$RACE_STUB")" \
  R_CP="$(native_file "$RACE_CP")" R_SID="$SID_A" R_OTHER="$SID_B" \
    node_m "
const m=require('$REQUIRE_PATH');
const fs=require('fs');
const STUB=process.env.R_STUB, CP=process.env.R_CP;
const SID=process.env.R_SID, OTHER=process.env.R_OTHER;
const T=function(sid,t){return JSON.stringify({type:'custom-title',sessionId:sid,customTitle:t})+'\n';};
const C=function(sid){return JSON.stringify({type:'user',sessionId:sid,message:{role:'user',content:'hi'}})+'\n';};
const planned=m.planPruneRoots({roots:[process.env.R_ROOT]});
$mut
const seen=[];
m.executePrunePlan({plan:planned.plan, dryRun:false, onEntry:function(e){seen.push(e);}});
const hit=seen.filter(function(e){
  return String(e.file).replace(/\\\\/g,'/').indexOf('/stub/')>=0;
})[0]||{};
console.log('E='+(hit.state||'-')+':'+(hit.reason||'-')+':'+(hit.scope||'-'));"
  check "$name: reported outcome" "$want" "$NODE_OUT"
  if [ "$want_stub" = "gone" ]; then
    check_no_file "$name: the stub was unlinked" "$RACE_STUB"
  else
    check_file "$name: the stub was NOT unlinked" "$RACE_STUB"
  fi
}

# R-1, R-2, R-4 and R-5 mutate the COUNTERPART between plan and execute in ways that
# destroy the evidence the prune decision rested on, so each must abort the unlink. They
# are separate rows rather than one representative case because they fail differently:
# emptied, stripped of its transcript, and replaced-by-another-session all reach the
# re-verification through different branches. (The counterpart mutation that must NOT
# abort — losing its title — is R-3, deliberately kept out of this group.)
run_e_counterpart_races() {
  race_case "R-1 counterpart emptied after planning" \
    "fs.writeFileSync(CP,'');" \
    "E=changed:counterpart-changed:-" present

  race_case "R-2 counterpart's content record removed after planning" \
    "fs.writeFileSync(CP,T(SID,'Alpha'));" \
    "E=changed:counterpart-changed:-" present

  race_case "R-4 counterpart replaced by a different session's transcript" \
    "fs.writeFileSync(CP,C(OTHER)+T(OTHER,'Alpha'));" \
    "E=changed:counterpart-changed:-" present

  # R-5: a vanished counterpart is `changed`, not `unreadable`. ENOENT means the fact
  # under verification (a surviving copy exists) is simply false now; EACCES (R-6)
  # means it could not be observed. The two must not collapse, because only the second
  # is an observation failure that has to raise the exit code.
  race_case "R-5 counterpart deleted after planning" \
    "fs.unlinkSync(CP);" \
    "E=changed:counterpart-changed:-" present
}

# R-3 — the row that guards the DELIBERATE semantic change of #1655, which is why it sits
# apart from R-1..R-5 rather than inside the "each one destroys the evidence" group. The
# counterpart loses its custom-title between plan and execute and keeps only the content
# record for this session. Nothing the decision rested on has gone: the surviving copy
# still holds the transcript, so re-verification succeeds and the prune correctly
# proceeds. If anyone ever re-introduces a title condition — in verifyCounterpart, in the
# re-verification call site, or as a "safety" extra check — this row goes red immediately.
run_e_title_no_longer_load_bearing() {
  race_case "R-3 counterpart's custom-title removed after planning" \
    "fs.writeFileSync(CP,C(SID));" \
    "E=pruned:-:-" gone
}

# SKIPPED (when deny_read cannot prove the denial): R-6 — the counterpart becomes
#          unreadable between plan and execute -> `unreadable ... scope=counterpart`,
#          stub survives, exit-1 side.
# Because: chmod is advisory on MSYS/Windows and ignored under root, so a false PASS is
#          the alternative. The denial is probed on a scratch file first.
# Needed:  a POSIX host running as a non-root user.
# TL3 gap: a real home directory whose permissions change mid-run (profile sync,
#          security agent, another user's file) is the realistic trigger.
run_e_unreadable_race() {
  local probe
  probe="$(new_dir)/probe"
  mkdir -p "$(dirname "$probe")"
  printf 'x\n' > "$probe"
  if ! deny_read "$probe"; then
    skip_case "R-6 unreadable counterpart (chmod is advisory on this host, or running as root)"
    return 0
  fi
  allow_read "$probe"

  race_case "R-6 counterpart becomes unreadable after planning" \
    "fs.chmodSync(CP,0);" \
    "E=unreadable:EACCES:counterpart" present
  allow_read "$RACE_ROOT"
}

# R-7 / R-8 mutate the STUB itself. The stub-ness verdict (I1) is just as perishable as
# the counterpart evidence: Claude Code appending a real message to a title-only file is
# precisely how a stub stops being a stub.
run_e_stub_races() {
  race_case "R-7 stub gains a content record after planning" \
    "fs.appendFileSync(STUB,C(SID));" \
    "E=changed:stub-changed:-" present

  # R-8 is the rigorous form of R-7: the replacement title is the same byte length and
  # the mtime is restored, so a re-check that compares only size/mtime would see an
  # unchanged file and delete a title that no counterpart carries. Only re-reading the
  # titleKeys catches it.
  race_case "R-8 stub's title replaced, same size and mtime" \
    "var st=fs.statSync(STUB); fs.writeFileSync(STUB,T(SID,'Bravo')); fs.utimesSync(STUB,st.atime,st.mtime);" \
    "E=changed:stub-changed:-" present
}

# R-9 — the control group. Without it, every row above would also pass if
# executePrunePlan simply never deleted anything: the mutations would look like they
# were being honoured when in fact nothing was ever at risk.
run_e_control() {
  local cp_before
  race_case "R-9 control: nothing mutated between plan and execute" \
    "" "E=pruned:-:-" gone
  cp_before="$(hash_of "$RACE_CP")"
  check_file "R-9: the counterpart survives the control run" "$RACE_CP"
  check "R-9: the counterpart is byte-identical after the control run" \
    "$cp_before" "$(hash_of "$RACE_CP")"
}

run_e_dry_run
run_e_prune
run_e_keep_not_deleted
run_e_idempotent
run_e_counterpart_races
run_e_title_no_longer_load_bearing
run_e_unreadable_race
run_e_stub_races
run_e_control
