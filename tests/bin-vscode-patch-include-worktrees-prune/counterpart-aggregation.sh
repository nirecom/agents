# Part of tests/bin-vscode-patch-include-worktrees-prune.sh (sourced, not standalone).
# Tests: bin/lib/vscode-patch-include-worktrees/prune.js, bin/lib/vscode-patch-include-worktrees/prune/verify.js
# Tags: bin, vscode, prune, counterparts, aggregation, session-files, scope:common, pwsh-not-required, TL2
#
# C08-C12 — a stub with SEVERAL surviving copies. Split out of planner-verify.sh when
# that file passed the 500-line hard limit; the C-series numbering is continuous across
# the two files on purpose, because the subject is one contract (which copy justifies a
# deletion, and what happens when none of them can).
#
# Reads verify_call() and the C-series subject matter from planner-verify.sh, which the
# dispatcher sources immediately before this file.

# ---- the multi-counterpart fixture vocabulary ------------------------------
#
# C08-C12 all claim to exercise a group with SEVERAL surviving copies, at least one of
# which cannot justify the prune. Building the losing copy out of "a file holding another
# session's transcript" does NOT produce that situation: classifySessionFile derives the
# session id from the BASENAME, so such a file counts the foreign record as `other` and
# classifies `indeterminate` — and planPrune puts only `real` members into `counterparts`.
# Every one of those rows then had exactly one candidate and asserted nothing about the
# search across candidates.
#
# The construction below is, as far as the module's own rules allow, the ONLY one that
# yields a counterpart which classifies `real` and still refuses to verify for the stub:
# the grouping key is the lowercased basename and SESSION_FILE_PATTERN is case-insensitive,
# so a copy named in the other case joins the same group, while `record.sessionId ===
# sessionId` is an exact comparison. The copy is a perfectly good transcript OF ITS OWN
# id and proves nothing about the stub's. (A `real` copy can never fail verification for
# its own id: both passes key on the same predicate and the classifier's 1 MiB budget is
# the stricter of the two.)
mk_refusing_copy() { # <dir> — classifies `real`, refuses to verify for SID_C
  { content_line "$SID_C_UPPER"; title_line "$SID_C_UPPER" "Alpha"; } \
    | mk_session "$1" "$SID_C_UPPER"
}
mk_real_copy() { # <dir> [title] — the copy that justifies the prune
  { content_line "$SID_C"; title_line "$SID_C" "${2:-Bravo}"; } | mk_session "$1" "$SID_C"
}
mk_stub_copy() { # <dir> — title-only, titles its own
  { title_line "$SID_C" "Alpha"; } | mk_session "$1" "$SID_C"
}

# C08 — `via=` must name the copy that actually justified the deletion: without that
# field the report cannot be audited after the fact. Driven end to end so the `via=`
# formatting (a cli.js responsibility) is covered too. Every copy in a group shares a
# basename by definition, so only the directory name distinguishes them in the report.
#
# Two surviving copies, and the one that cannot stand in for this session sorts FIRST.
# The winner deliberately carries a title the stub never had, so the row is also a
# statement that the title text played no part in choosing it.
run_c_via_selection() {
  local home ext proj line
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  mk_stub_copy "$proj/stub"
  mk_refusing_copy "$proj/viano"
  mk_real_copy "$proj/viayes" "Bravo"

  run_cli_prune "$home" "$ext" "$proj" --dry-run
  check "C08a: exit 0" "0" "$CLI_RC"
  check_token "C08b: the stub is reported as a would-prune" "would-prune" "$CLI_OUT"
  line="$(prune_line "would-prune" "$CLI_OUT")"
  check_contains "C08c: the report names the justifying counterpart in via=" "viayes" "$line"
  check_absent "C08d: the copy that could not justify it is not credited" "viano" "$line"
  check_contains "C08f: the group really did hold two surviving copies" \
    "real-copies=2" "$line"
  check_file "C08e: --dry-run left the stub in place" "$(session_path "$proj/stub" "$SID_C")"
}

# ---- C2: aggregation across several counterparts ---------------------------

# C08 shows the happy half of the multi-copy rule (one copy justifies the prune, so it
# happens). C09-C12 cover the half that decides whether a failure is visible at all: if
# the state reported for the stub were taken from the LAST candidate tried, or from the
# first decision-reached one, an observation failure would be silently downgraded to
# `kept` and the run would exit 0 while a file's fate was never actually established.
#
# Note on reachability after #1655: `no-content` can no longer be produced by a copy that
# CLASSIFIED as `real`, because both passes key content on the same session id and the
# classifier's 1 MiB budget is the stricter of the two. A group-level candidate can
# therefore only fail by not being observed at all, which is what C09 and C12 inject.

# Renders the entry describing the stub as `E=<state>:<scope|->`, followed by `OBS=<n>`:
# how many entries in the WHOLE run came back observation-failed. The second field is what
# stops an aggregation row from passing vacuously — a build that quietly dropped the other
# failing member would still report the right state for the stub.
#
# The two-phase path is driven directly (as in lifecycle-race.sh) because a counterpart
# that classifies as `real` but cannot be READ at verification time is only reachable by
# mutating the tree between the two phases — a file that was already unreadable during the
# scan never becomes a candidate in the first place (planPrune row B06).
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
const obs=seen.filter(function(e){
  return e.state==='unreadable' || e.state==='unclassified';
}).length;
console.log('E='+(hit.state||'-')+':'+(hit.scope||'-')+' OBS='+obs);"
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

# C09 — the severity rule on a group with TWO surviving copies, neither of which can
# justify the deletion by the time the unlink is reached. `cp-a-norecord` classifies real
# and refuses (it is another session's transcript, in the one shape that still classifies
# real); `cp-z-hostile` justifies the prune at plan time and becomes unreadable before the
# re-verification. The stub must be reported as `unreadable ... scope=counterpart`: an
# observation that failed, never `kept`. Reporting `kept` would claim the file was
# examined and consciously retained, when the only copy that mattered was never observed.
# `cp-z-hostile` deliberately carries a title the stub never had, so the row would go red
# with a title-shaped refusal if title text were reintroduced as a condition — and the run
# would then report a decision reached where an observation failed.
run_c_all_counterparts_fail() {
  local root stub
  if ! dir_read_faults; then
    skip_case "C09 mixed-severity aggregation (host does not fault on reading a directory)"
    return 0
  fi
  root="$(new_proj_root)"
  mk_stub_copy "$root/stub"
  mk_refusing_copy "$root/cp-a-norecord"
  mk_real_copy "$root/cp-z-hostile" "Charlie"
  stub="$(session_path "$root/stub" "$SID_C")"

  agg_entry "$root" "$(session_path "$root/cp-z-hostile" "$SID_C")"
  check "C09a: an unobserved counterpart outranks any decision reached" \
    "E=unreadable:counterpart OBS=1" "$NODE_OUT"
  check_file "C09b: nothing is unlinked when no counterpart verifies" "$stub"
  allow_read "$root"
}

# SKIPPED: heavier() resolving a MIXED pair of severities at PLAN time — one counterpart
#          refusing with `no-content` (a decision reached) and another failing with
#          `unreadable` (an observation failed), in either order.
# Because: a counterpart is only ever a member classified `real`, and a file that cannot
#          be read classifies `unreadable`, so it is never offered as a counterpart in the
#          first place (planPrune, row B06). The mixed pair is unconstructible through the
#          public API; C09 reaches the same ranking at EXECUTE time, which is where it
#          actually protects a file.
# L3 gap:  a counterpart that becomes unreadable DURING planPruneRoots — between its own
#          classification and resolveCandidate's read of it — is a real race no fixture
#          can schedule; only a concurrent-writer soak against a live tree would see it.

# C10 / C11 — the candidate search must survey the whole group, not stop at the first
# member that cannot justify the prune. The two rows are the same situation with the
# directory names swapped, so whichever order the scan happens to enumerate them in, one
# of the two rows has the NON-justifying copy first; a loop that gave up on the first
# member it could not use fails at least one of them. Run for real (not --dry-run, unlike
# C08) so the deletion itself is the assertion.
#
# Both rows use the refusing-copy construction, so both members really are surviving
# copies and `real-copies=2` is the proof that the group had two of them. The justifying
# copy carries a title the stub never had, so both rows go red the moment title text is
# reintroduced as a condition.
run_c_candidate_search_continues() {
  local home ext proj line
  home="$(new_home)"; ext="$(new_ext_root)"

  # C10 — the non-justifying copy sorts first.
  proj="$(new_proj_root)"
  mk_stub_copy "$proj/stub"
  mk_refusing_copy "$proj/cp-a-refuses"
  mk_real_copy "$proj/cp-z-real" "Bravo"
  run_cli_prune "$home" "$ext" "$proj"
  check "C10a: exit 0" "0" "$CLI_RC"
  check_contains "C10b: the prune still happens past a non-justifying first member" \
    "pruned=1" "$CLI_OUT"
  check_contains "C10c: the non-justifying member is not also reported as a keep" \
    "kept=0" "$CLI_OUT"
  line="$(prune_line "pruned" "$CLI_OUT")"
  check_contains "C10d: via= names the copy holding this session's transcript" \
    "cp-z-real" "$line"
  check_absent "C10e: the refusing copy is not credited" "cp-a-refuses" "$line"
  # Both members are surviving copies; the search had to get past the first one.
  check_contains "C10f: the group really did hold two surviving copies" \
    "real-copies=2" "$line"
  check_no_file "C10g: the stub is gone" "$(session_path "$proj/stub" "$SID_C")"
  check_file "C10h: the justifying copy survives" "$(session_path "$proj/cp-z-real" "$SID_C")"
  check_file "C10i: the refusing copy survives" \
    "$(session_path "$proj/cp-a-refuses" "$SID_C_UPPER")"

  # C11 — the justifying copy sorts first: the mirror image, so the pair is order-agnostic.
  proj="$(new_proj_root)"
  mk_stub_copy "$proj/stub"
  mk_real_copy "$proj/cp-a-real" "Bravo"
  mk_refusing_copy "$proj/cp-z-refuses"
  run_cli_prune "$home" "$ext" "$proj"
  check "C11a: exit 0" "0" "$CLI_RC"
  check_contains "C11b: the prune happens with the justifying copy first too" \
    "pruned=1" "$CLI_OUT"
  line="$(prune_line "pruned" "$CLI_OUT")"
  check_contains "C11c: via= names the copy holding this session's transcript" \
    "cp-a-real" "$line"
  check_absent "C11d: the refusing copy is not credited" "cp-z-refuses" "$line"
  check_contains "C11g: this group held two surviving copies too" "real-copies=2" "$line"
  check_no_file "C11e: the stub is gone" "$(session_path "$proj/stub" "$SID_C")"
  check_file "C11f: the refusing copy survives" \
    "$(session_path "$proj/cp-z-refuses" "$SID_C_UPPER")"
}

# C12 — every copy in the group is an OBSERVATION failure, of the two different kinds:
# one is too large to judge (`unclassified`, truncated) and one cannot be read at all
# (`unreadable`). Detail plan 3.8 ranks observation failure above decision reached but
# does NOT define an order BETWEEN the two observation-failed states, so the assertion is
# exactly what the plan promises: the reported state is one of them, never `kept`, and
# the stub is not deleted. Pinning a winner here would invent a contract the plan does
# not state.
run_c_two_observation_failures() {
  local root stub big got obs
  if ! dir_read_faults; then
    skip_case "C12 two observation failures (host does not fault on reading a directory)"
    return 0
  fi
  root="$(new_proj_root)"
  mk_stub_copy "$root/stub"
  # cp-a-norecord: a surviving copy that cannot stand in for this session, so the search
  # is forced past it before it ever reaches the copy that becomes unreadable.
  mk_refusing_copy "$root/cp-a-norecord"
  # cp-big: nothing but filler ahead of the caps (`lead none`), so BOTH budgets run out
  # before any content record is seen. The old `lead content` spelling would now trip the
  # early stop on line 1 and the file would sail through as a perfectly good counterpart.
  mkdir -p "$root/cp-big"
  big="$(session_path "$root/cp-big" "$SID_C")"
  gen_big "$big" "$SID_C" $((VERIFY_MAX_SCAN + 128)) title none none
  mk_real_copy "$root/cp-m-hostile" "Alpha"
  stub="$(session_path "$root/stub" "$SID_C")"

  agg_entry "$root" "$(session_path "$root/cp-m-hostile" "$SID_C")"
  obs="${NODE_OUT##* }"
  case "${NODE_OUT%% *}" in
    E=unreadable:*|E=unclassified:*) got="observation-failed" ;;
    *) got="${NODE_OUT%% *}" ;;
  esac
  check "C12a: two observation failures never collapse into a kept" \
    "observation-failed" "$got"
  # The stub's own entry AND cp-big's: neither observation failure is swallowed, and the
  # count is what stops C12a from passing on a run where cp-big silently went missing.
  check "C12c: both observation failures are reported" "OBS=2" "$obs"
  check_file "C12b: nothing is unlinked when both counterparts are unobservable" "$stub"
  rm -f "$big"
  allow_read "$root"
}

run_c_via_selection

run_c_all_counterparts_fail

run_c_candidate_search_continues

run_c_two_observation_failures
