# Part of tests/bin-vscode-cc-repair-prune.sh (sourced, not standalone).
# Tests: bin/vscode-cc-repair/prune/execute.js, bin/vscode-cc-repair/prune.js, bin/vscode-cc-repair/primitives.js
# Tags: bin, vscode, prune, execute, security, identity, platform, session-files, scope:common, pwsh-not-required, TL2
#
# K — "is this the same file?" and "is this the same name?", the two questions
# isCounterpartPath answers with string comparisons that the rest of this module already
# answers properly through primitives.js.
#
# K1 (same FILE). `path.resolve(a) !== path.resolve(b)` is a comparison of SPELLINGS. It
# collapses `.` and `..` and nothing else, so every alias mechanism the host offers — a
# junction, a symlink, and on win32 a different letter case — produces two spellings of one
# file that this test calls "different". primitives.js exports realPathKey precisely for
# this, prune.js already uses it to dedup the scan, and execute.js does not. A `via` that
# IS the target is the one piece of evidence that can never be evidence: a file cannot be
# its own surviving copy. J03 pins the plain spelling of that rule; these rows pin the
# rule rather than the spelling.
#
# K2 (same NAME). `viaBase.toLowerCase() !== path.basename(...).toLowerCase()` folds case
# unconditionally, and prune.js's duplicate-group key does the same. primitives.js exports
# pathKey, which folds ONLY on win32. On a case-sensitive filesystem those two lines fuse
# two genuinely different session files into one group and then let one authorise the
# other's deletion — while sessionIdOf / isOwnTitleRecord / isMatchingContentRecord compare
# the session id with `===` and continue to treat them as two different sessions. The
# expected outcome is therefore PLATFORM-DEPENDENT, and the rows are driven by a probe of
# the same `process.platform` the code under test branches on, never by a hardcoded answer.

# The platform predicate the code under test uses. Read from node rather than from `uname`
# so the test and pathKey can never disagree about which branch is live.
CASE_FOLDS="$(run_with_timeout 30 node -e 'process.stdout.write(process.platform==="win32"?"yes":"no")')"

# guard_case (execute-guard.sh) with one extra native path handed to the snippet as
# `process.env.A_ALT`, so a `via` can point outside the projects root.
ident_case() { # <projects-root> <alt-native-path> <js-mutating-cand> ; sets NODE_OUT
  A_ROOT="$(native_path "$1")" A_ALT="$2" node_m "
const m=require('$REQUIRE_PATH');
const path=require('path');
const root=process.env.A_ROOT;
const alt=process.env.A_ALT;
const planned=m.planPruneRoots({roots:[root]});
const cand=planned.plan.filter(function(d){return d.action==='prune-candidate';})[0];
if (!cand) { console.log('E=no-candidate:-:-'); } else {
  $3
  const seen=[];
  m.executePrunePlan({plan:[cand], dryRun:false, onEntry:function(e){seen.push(e);}});
  const e=seen[0]||{};
  console.log('E='+(e.state||'-')+':'+(e.reason||'-')+':'+
              (e.via?String(e.via).replace(/\\\\/g,'/'):'-'));
}"
}

# isCounterpartPath called directly, so the answer is the boolean rather than whatever the
# I2 re-verification happens to say afterwards. Prints `C=<true|false>`.
counterpart_call() { # <file> <root> <via-file> <via-root> ; sets NODE_OUT
  K_F="$1" K_R="$2" K_VF="$3" K_VR="$4" node_m "
const x=require('$EXECUTE_REQUIRE');
console.log('C='+String(x.isCounterpartPath({
  file: process.env.K_F, root: process.env.K_R,
  via: { file: process.env.K_VF, root: process.env.K_VR },
})));"
}

# ---- K1: the same file under a different spelling ---------------------------

run_k_alias_identity() {
  local proj h alias_dir

  # K01 — a directory JUNCTION beside the projects root, pointing at the stub's own
  # directory. `<alias>/<uuid>.jsonl` and `<stub>/<uuid>.jsonl` are one file; path.resolve
  # cannot tell, realpath can. Today this sails past the identity check and the module goes
  # on to ask the STUB whether it justifies deleting itself — the answer happens to be no
  # (a stub holds no transcript), so the file survives by accident rather than by rule.
  # `failed:not-a-counterpart` is the outcome the guard owes: a plan naming the target as
  # its own evidence is a caller error, not a race.
  proj="$(guard_fixture)"; h="$(hash_of "$(session_path "$proj/stub" "$SID_A")")"
  alias_dir="$(new_dir)/alias"
  if ! make_dir_alias "$alias_dir" "$proj/stub"; then
    rm -rf "$alias_dir" 2>/dev/null || true
    skip_case "K01 junction alias to the stub's directory (this host cannot create a directory alias)"
  else
    # native_file, not native_path: native_path cds into the directory and asks the shell
    # where it is, which RESOLVES the junction — handing the canonical spelling to the code
    # under test and testing nothing. The unresolved spelling is the whole point.
    ident_case "$proj" "$(native_file "$alias_dir")" \
      "cand.via={root:alt,file:path.join(alt,'$SID_A.jsonl')};"
    check "K01a: a via that reaches the stub itself through an alias is refused" \
      "E=failed:not-a-counterpart:-" "$NODE_OUT"
    guard_survives "K01b" "$proj" "$h"
    rm -rf "$alias_dir" 2>/dev/null || true
  fi

  # K02 — the same construction with a FILE symlink rather than a directory alias, which is
  # the shape a dotfiles manager or a roaming profile actually produces.
  proj="$(guard_fixture)"; h="$(hash_of "$(session_path "$proj/stub" "$SID_A")")"
  alias_dir="$(new_dir)"
  if ! make_file_alias "$alias_dir/$SID_A.jsonl" "$(session_path "$proj/stub" "$SID_A")"; then
    # SKIPPED: a `via` reaching the target through a FILE symlink.
    # Because: on Windows_NT `ln -s` silently produces a real COPY under the MSYS default
    #          (the same host limitation scan.sh D03a documents), so the alias would not be
    #          an alias and the row would assert nothing. K01's junction covers the same
    #          realpath-vs-resolve gap through the one alias mechanism this host does have.
    # L3 gap:  a POSIX host, where a symlinked session file is the realistic trigger and
    #          where realpathSync resolves it while path.resolve does not.
    rm -f "$alias_dir/$SID_A.jsonl" 2>/dev/null || true
    skip_case "K02 file symlink alias to the stub (this host cannot create a file symlink)"
  else
    ident_case "$proj" "$(native_path "$alias_dir")" \
      "cand.via={root:alt,file:path.join(alt,'$SID_A.jsonl')};"
    check "K02a: a via that reaches the stub through a file symlink is refused" \
      "E=failed:not-a-counterpart:-" "$NODE_OUT"
    guard_survives "K02b" "$proj" "$h"
    rm -f "$alias_dir/$SID_A.jsonl" 2>/dev/null || true
  fi

  # K03 — `.` segments. path.resolve already collapses these, so this row is NOT an attack:
  # it is the empirical proof that `.`-spelling is not the hole (and, once the fix lands,
  # that canonicalizing did not accidentally start accepting the target as its own
  # evidence). Recorded because the obvious guess about which spellings slip past is wrong.
  proj="$(guard_fixture)"; h="$(hash_of "$(session_path "$proj/stub" "$SID_A")")"
  ident_case "$proj" "-" \
    "cand.via={root:cand.root,file:path.join(path.dirname(cand.file),'.','$SID_A.jsonl')};"
  check "K03a: a via spelled with a . segment is still the target, and still refused" \
    "E=failed:not-a-counterpart:-" "$NODE_OUT"
  guard_survives "K03b" "$proj" "$h"

  # K04 — Pattern 4 / Pattern 1's mirror. A genuine counterpart in a DIFFERENT project
  # directory is a different real file, and canonicalizing must not make it look like the
  # target. Without this row the whole K1 group is satisfied by a guard that rejects
  # everything.
  proj="$(guard_fixture)"
  ident_case "$proj" "-" "void 0;"
  check "K04a: a genuine counterpart in another project directory still prunes" \
    "E=pruned:-:real/$SID_A.jsonl" "$NODE_OUT"
  check_no_file "K04b: the stub was displaced" "$(session_path "$proj/stub" "$SID_A")"
  check_file "K04c: the counterpart survives" "$(session_path "$proj/real" "$SID_A")"
}

# ---- K2: case folding, decided by platform ----------------------------------

# A case-bearing fixture: SID_A is all digits, so only the SID_C pair has an "other case"
# spelling at all. stub + real, same shape as guard_fixture.
ident_fixture() { # ; prints the projects root
  local proj
  proj="$(new_proj_root)"
  { title_line "$SID_C" "Alpha"; } | mk_session "$proj/stub" "$SID_C"
  { content_line "$SID_C"; title_line "$SID_C" "Bravo"; } | mk_session "$proj/real" "$SID_C"
  printf '%s' "$proj"
}

run_k_case_identity() {
  local proj stub want_same want_group
  proj="$(ident_fixture)"
  stub="$(native_file "$(session_path "$proj/stub" "$SID_C")")"

  # K05 — sanctioned direction: identical spelling, two different project directories.
  # Accepted on every platform.
  counterpart_call "$stub" "$(native_path "$proj/stub")" \
    "$(native_file "$(session_path "$proj/real" "$SID_C")")" "$(native_path "$proj/real")"
  check "K05: an identically-named counterpart in another directory is accepted" \
    "C=true" "$NODE_OUT"

  # K06 — the TARGET spelled in the other case. Refused on every platform, for two different
  # reasons that both follow from pathKey/realPathKey: on win32 the filesystem folds, so the
  # two spellings are one file and a file can never be its own surviving copy (J03's rule,
  # stated about identity rather than about spelling); on a case-sensitive host they are two
  # different names, so it is not a copy of this session either way. Today, on win32, it is
  # ACCEPTED — the basename compare folds while the identity compare does not.
  counterpart_call "$stub" "$(native_path "$proj/stub")" \
    "$(printf '%s/%s.jsonl' "$(native_path "$proj/stub")" "$SID_C_UPPER")" \
    "$(native_path "$proj/stub")"
  check "K06: the target spelled in the other case is never its own counterpart" \
    "C=false" "$NODE_OUT"

  # K07 — a DIFFERENT file whose basename differs only in case. On win32 the two names are
  # the same name, so a copy in another directory is a legitimate counterpart. On a
  # case-sensitive host they are two different session files carrying two different session
  # ids, and letting one authorise the other's deletion is the split-brain: the basename
  # comparison says "same session", `record.sessionId === sessionId` says "different
  # session", and the deletion is decided by whichever of the two runs last.
  if [ "$CASE_FOLDS" = "yes" ]; then want_same="C=true"; else want_same="C=false"; fi
  counterpart_call "$stub" "$(native_path "$proj/stub")" \
    "$(printf '%s/%s.jsonl' "$(native_path "$proj/real")" "$SID_C_UPPER")" \
    "$(native_path "$proj/real")"
  check "K07: a case-variant basename is the same name only where the platform says so" \
    "$want_same" "$NODE_OUT"

  # K08 — the other call site: prune.js's duplicate-group key, which lowercases the basename
  # unconditionally. Driven end to end, because the group count is what the report prints
  # and it is the only externally visible statement of how the two files were partitioned.
  # Two case-variant spellings in two directories: one group where the platform folds, none
  # where it does not.
  local home ext proj2
  home="$(new_home)"; ext="$(new_ext_root)"; proj2="$(new_proj_root)"
  { title_line "$SID_C" "Alpha"; } | mk_session "$proj2/stub" "$SID_C"
  { content_line "$SID_C_UPPER"; title_line "$SID_C_UPPER" "Alpha"; } \
    | mk_session "$proj2/other" "$SID_C_UPPER"
  if [ "$CASE_FOLDS" = "yes" ]; then want_group="groups=1"; else want_group="groups=0"; fi
  run_cli_prune "$home" "$ext" "$proj2"
  check "K08a: exit 0" "0" "$CLI_RC"
  check_contains "K08b: the grouping key folds case exactly where the platform does" \
    "$want_group" "$CLI_OUT"

  # K09 — the split-brain consequence, asserted where a user can see it rather than on an
  # internal key. Whichever way the platform partitions those two files, NOTHING may be
  # pruned: they are either one name holding two different session ids (so no copy proves
  # anything about the other) or two names with no duplicate at all. A build where grouping
  # and identity disagree is a build where one of them authorises a deletion the other
  # would refuse.
  check_contains "K09a: no prune is authorised across the mismatch" "pruned=0" "$CLI_OUT"
  check_contains "K09b: and nothing failed either" "failed=0" "$CLI_OUT"
  check_file "K09c: the stub survives" "$(session_path "$proj2/stub" "$SID_C")"
  check_file "K09d: the case variant survives" "$(session_path "$proj2/other" "$SID_C_UPPER")"
  check_no_file "K09e: no rescue copy was written, so nothing was displaced" \
    "$(session_path "$proj2/stub" "$SID_C").bak"
}

run_k_alias_identity
run_k_case_identity
