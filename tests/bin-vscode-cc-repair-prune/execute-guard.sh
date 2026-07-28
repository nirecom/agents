# Part of tests/bin-vscode-cc-repair-prune.sh (sourced, not standalone).
# Tests: bin/lib/vscode-cc-repair/prune/execute.js, bin/lib/vscode-cc-repair/prune.js, bin/lib/vscode-cc-repair/cli.js
# Tags: bin, vscode, prune, execute, security, backup, session-files, scope:common, pwsh-not-required, TL2
#
# J — the two protections at the point of no return.
#
# F2 — THE COUNTERPART PATH IS NOT RE-ASSERTED. executePrunePlan is a public export, and
# prunable() knows it: it re-reads the stub, re-checks the stub's basename against
# SESSION_FILE_PATTERN, and re-verifies the counterpart. What it never checks is WHICH
# FILE the counterpart is. A plan whose `via` names `notes.txt` — any file at all that
# happens to contain one line tagged with the session id — sails through the I2
# re-verification and the genuine stub is destroyed on the strength of it. The security
# scan reproduced exactly that. `via` is not incidental bookkeeping for the report; it is
# the evidence, so it has to satisfy the same boundary the evidence was collected under.
#
# F3 — NO BACKUP. The old comment above the unlink says a wrong deletion "is unrecoverable
# because no backup is taken", which states the problem rather than solving it. Renaming
# the stub to `<uuid>.jsonl.bak` costs one syscall, is invisible to listSessionFiles (the
# pattern requires the bare `.jsonl` suffix) and invisible to the VS Code extension, and
# turns every residual hole in this file — the ones no test can close — from data loss
# into an inconvenience.
#
# Both are driven through the real two-phase path, because a forged plan is precisely the
# input `executePrunePlan(...)` accepts from any caller.

# ---- the forged-plan fixture ------------------------------------------------

# stub/  : the file a wrong decision destroys — the thing being protected
# real/  : the legitimate counterpart, the only file entitled to authorise that
# decoy/ : NOT a session file, and carrying content tagged with the stub's session id.
#          This is the security scan's input: it satisfies I2 and nothing else.
# other/ : a genuine session file with a DIFFERENT basename, also carrying the stub's
#          session id. It passes a basename-pattern check and is still the wrong file —
#          which is why matching the pattern cannot be the whole rule.
guard_fixture() { # ; prints the projects root
  local proj
  proj="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$proj/stub" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Bravo"; } | mk_session "$proj/real" "$SID_A"
  mkdir -p "$proj/decoy"
  content_line "$SID_A" > "$proj/decoy/not-a-session-file.txt"
  { content_line "$SID_A"; } | mk_session "$proj/other" "$SID_B"
  printf '%s' "$proj"
}

# Plans for real, applies <js> to the candidate (the forgery), executes for real, and
# renders the outcome as `E=<state>:<reason|->:<via|->`. `via` is normalized to forward
# slashes: path.relative yields backslashes on Windows and the separator is not the
# subject of any row here.
guard_case() { # <projects-root> <js-mutating-cand> ; sets NODE_OUT
  A_ROOT="$(native_path "$1")" node_m "
const m=require('$REQUIRE_PATH');
const path=require('path');
const root=process.env.A_ROOT;
const planned=m.planPruneRoots({roots:[root]});
const cand=planned.plan.filter(function(d){return d.action==='prune-candidate';})[0];
if (!cand) { console.log('E=no-candidate:-:-'); } else {
  $2
  const seen=[];
  m.executePrunePlan({plan:[cand], dryRun:false, onEntry:function(e){seen.push(e);}});
  const e=seen[0]||{};
  console.log('E='+(e.state||'-')+':'+(e.reason||'-')+':'+
              (e.via?String(e.via).replace(/\\\\/g,'/'):'-'));
}"
}

# Pattern 1 for every forged-via row: the assertion is not the returned state, it is that
# the file is still there, unchanged, and that nothing was written next to it either.
guard_survives() { # <id-prefix> <projects-root> <stub-hash>
  local id="$1" proj="$2" want="$3" stub
  stub="$(session_path "$proj/stub" "$SID_A")"
  check_file "$id-exists: the stub still exists" "$stub"
  check "$id-identical: the stub is byte-identical" "$want" "$(hash_of "$stub")"
  check_no_file "$id-no-backup: nothing was written next to it either" "$stub.bak"
}

# ---- J1: a forged `via` must not reach the syscall --------------------------

run_j_forged_via() {
  local proj h

  # J01 — the reproduced attack. `via` names a plain .txt file that happens to carry a
  # content record for this session. I2 is satisfied by it; the basename boundary is not.
  proj="$(guard_fixture)"; h="$(hash_of "$(session_path "$proj/stub" "$SID_A")")"
  guard_case "$proj" "cand.via={root:root,file:path.join(root,'decoy','not-a-session-file.txt')};"
  check "J01a: a via outside SESSION_FILE_PATTERN is refused" \
    "E=failed:not-a-counterpart:-" "$NODE_OUT"
  guard_survives "J01b" "$proj" "$h"
  check_file "J01c: the decoy is left alone too" "$proj/decoy/not-a-session-file.txt"

  # J02 — `via` names a real session file, so a pattern check alone passes. It is a
  # different SESSION: a copy of the stub is by definition a file of the same basename,
  # and anything else is a different transcript being used as an alibi.
  proj="$(guard_fixture)"; h="$(hash_of "$(session_path "$proj/stub" "$SID_A")")"
  guard_case "$proj" "cand.via={root:root,file:path.join(root,'other','$SID_B.jsonl')};"
  check "J02a: a via whose basename is not the stub's is refused" \
    "E=failed:not-a-counterpart:-" "$NODE_OUT"
  guard_survives "J02b" "$proj" "$h"
  check_file "J02c: the other session's file is left alone" \
    "$(session_path "$proj/other" "$SID_B")"

  # J03 — `via` names the stub itself. A file can never be its own surviving copy; without
  # an explicit identity check the answer would depend on whether the stub happens to
  # satisfy I2, which is an accident, not a guard.
  proj="$(guard_fixture)"; h="$(hash_of "$(session_path "$proj/stub" "$SID_A")")"
  guard_case "$proj" "cand.via={root:cand.root,file:cand.file};"
  check "J03a: a via pointing at the stub itself is refused" \
    "E=failed:not-a-counterpart:-" "$NODE_OUT"
  guard_survives "J03b" "$proj" "$h"

  # J04 — no `via` at all. Today this reaches verifyCounterpart(null, ...) and comes back
  # `unreadable`, which is an OBSERVATION failure: it says the counterpart could not be
  # read, when in truth the plan never named one. A malformed plan is a caller error and
  # belongs with the other `failed` outcomes, not in the bucket that means "re-run later".
  proj="$(guard_fixture)"; h="$(hash_of "$(session_path "$proj/stub" "$SID_A")")"
  guard_case "$proj" "cand.via=null;"
  check "J04a: a plan with no via is refused as a caller error, not an observation failure" \
    "E=failed:not-a-counterpart:-" "$NODE_OUT"
  guard_survives "J04b" "$proj" "$h"

  # J05 — Pattern 4. The untouched plan, through the identical driver: the guard must not
  # be reachable by any legitimate plan, or it would simply have disabled the feature.
  proj="$(guard_fixture)"
  guard_case "$proj" "void 0;"
  check "J05a: the plan the planner itself produced still prunes" \
    "E=pruned:-:real/$SID_A.jsonl" "$NODE_OUT"
  check_no_file "J05b: the stub is gone" "$(session_path "$proj/stub" "$SID_A")"
  check_file "J05c: the counterpart survives" "$(session_path "$proj/real" "$SID_A")"
}

# ---- J2: displace, do not destroy -------------------------------------------

# The stub is renamed to `<uuid>.jsonl.bak` instead of being unlinked. The suffix is what
# makes it free: SESSION_FILE_PATTERN requires the bare `.jsonl` ending, so the backup is
# not a session file to this tool and not a session to the extension either — it is inert
# bytes that a user can restore by hand after a mistake nobody predicted.
run_j_backup() {
  local home ext proj stub before

  # J06 — the backup exists and is the stub, byte for byte. A backup that is not identical
  # to what was removed is not a backup.
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$proj/stub" "$SID_A"
  { content_line "$SID_A"; } | mk_session "$proj/real" "$SID_A"
  stub="$(session_path "$proj/stub" "$SID_A")"
  before="$(hash_of "$stub")"
  run_cli_prune "$home" "$ext" "$proj"
  check "J06a: exit 0" "0" "$CLI_RC"
  check_contains "J06b: the prune happened" "pruned=1" "$CLI_OUT"
  check_no_file "J06c: the stub is gone from its session name" "$stub"
  check_file "J06d: it was displaced to <uuid>.jsonl.bak" "$stub.bak"
  check "J06e: the backup is byte-identical to what was removed" "$before" "$(hash_of "$stub.bak")"

  # J09 — and the backup is inert: a second run must not see it as a session file, or the
  # tool would start reasoning about its own debris.
  run_cli_prune "$home" "$ext" "$proj"
  check "J09a: exit 0 on the rescan" "0" "$CLI_RC"
  check_contains "J09b: the .bak is not enumerated as a session file" \
    "scanned=1 groups=0" "$CLI_OUT"
  check_contains "J09c: nothing further is pruned" "pruned=0" "$CLI_OUT"
  check_file "J09d: the backup is still there after the rescan" "$stub.bak"

  # J07 — a rehearsal writes NOTHING. --dry-run that leaves a `.bak` behind is not a
  # rehearsal, and the flag exists precisely so a user can look before committing.
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$proj/stub" "$SID_A"
  { content_line "$SID_A"; } | mk_session "$proj/real" "$SID_A"
  stub="$(session_path "$proj/stub" "$SID_A")"
  before="$(hash_of "$stub")"
  run_cli_prune "$home" "$ext" "$proj" --dry-run
  check "J07a: exit 0" "0" "$CLI_RC"
  check_contains "J07b: the run is a rehearsal" "would-prune=1" "$CLI_OUT"
  check_file "J07c: the stub is untouched" "$stub"
  check "J07d: byte-identical" "$before" "$(hash_of "$stub")"
  check_no_file "J07e: --dry-run wrote no backup" "$stub.bak"

  # J08 — a `.bak` that already exists is the RESCUE COPY OF AN EARLIER STUB, and it is the
  # only copy of that earlier title: Claude Code recreates a stub under the same uuid, so a
  # second prune of the same session is the ordinary case, not an exotic one. Overwriting
  # the first backup therefore destroys exactly the thing the backup exists to preserve.
  # rules/coding.md sanctions the timestamped variant "when history preservation is needed",
  # and this is that case:
  #   no `.bak`        -> `<uuid>.jsonl.bak`                    (J11, the sanctioned direction)
  #   `.bak` present   -> `<uuid>.jsonl.bak.YYYYMMDD_HHMMSS`, and the pre-existing `.bak`
  #                       is left COMPLETELY untouched
  # The stale content is deliberately distinctive so "not overwritten" is provable by hash.
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$proj/stub" "$SID_A"
  { content_line "$SID_A"; } | mk_session "$proj/real" "$SID_A"
  stub="$(session_path "$proj/stub" "$SID_A")"
  before="$(hash_of "$stub")"
  printf 'rescue copy of the FIRST stub, holding a title that exists nowhere else\n' > "$stub.bak"
  local bak_before ts_file line
  bak_before="$(hash_of "$stub.bak")"
  run_cli_prune "$home" "$ext" "$proj"
  check "J08a: exit 0" "0" "$CLI_RC"
  check_contains "J08b: a pre-existing .bak does not fail the prune" "pruned=1" "$CLI_OUT"
  check_contains "J08c: and nothing is reported as failed" "failed=0" "$CLI_OUT"
  check_file "J08d: the pre-existing .bak still exists" "$stub.bak"
  check "J08e: the pre-existing .bak is byte-identical — the earlier title survives" \
    "$bak_before" "$(hash_of "$stub.bak")"
  ts_file="$(timestamped_backup "$proj/stub" "$SID_A")"
  check_file "J08f: a timestamped rescue copy appeared alongside it" "$ts_file"
  check "J08g: and it is byte-identical to the stub that was just displaced" \
    "$before" "$(hash_of "$ts_file")"
  check "J08h: the suffix is exactly YYYYMMDD_HHMMSS" "ok" \
    "$(printf '%s' "${ts_file##*.bak.}" | grep -qE '^[0-9]{8}_[0-9]{6}$' && echo ok || echo "bad:${ts_file##*.bak.}")"
  check "J08i: exactly two files remain in the stub directory (nothing else was written)" \
    "2" "$(count_files "$proj/stub")"
  # The report is the ONLY thing a user has when they want the file back, so it must name
  # the file that was actually written — not the plain `.bak` this run refused to touch.
  line="$(prune_line "pruned" "$CLI_OUT")"
  check_contains "J08j: backup= names the file that was actually written" \
    "backup=$(basename "$ts_file")" "$line"
}

# J10 — the report has to SAY where the file went. A user who runs this tool, sees
# `pruned`, and then wants the file back has only the report to go on; `backup=` is the
# difference between a recoverable mistake and a lost one. Asserted on the rehearsal line
# too, because --dry-run is where a cautious user looks FIRST, and a rehearsal that hides
# the recovery path is the one that gets trusted by accident.
run_j_backup_reported() {
  local home ext proj line
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$proj/stub" "$SID_A"
  { content_line "$SID_A"; } | mk_session "$proj/real" "$SID_A"

  run_cli_prune "$home" "$ext" "$proj" --dry-run
  line="$(prune_line "would-prune" "$CLI_OUT")"
  check_contains "J10a: the rehearsal line names the backup it would write" "backup=" "$line"
  check_contains "J10b: and names it as a .bak" ".jsonl.bak" "$line"
  check_contains "J10c: the rehearsal still names the counterpart" "via=" "$line"

  run_cli_prune "$home" "$ext" "$proj"
  line="$(prune_line "pruned" "$CLI_OUT")"
  check_contains "J10d: the pruned line names the backup that was written" "backup=" "$line"
  check_contains "J10e: and names it as a .bak" ".jsonl.bak" "$line"
  check_contains "J10f: the pruned line still names the counterpart" "via=" "$line"
  check_contains "J10g: and still carries the group's real-copy count" "real-copies=" "$line"
}

# SKIPPED: the rename itself failing (a read-only parent directory, EACCES/EPERM/EXDEV),
#          which must be reported `failed` with the errno as the reason.
# Because: the only portable-ish way to make it fail is a read-only parent, and chmod is
#          advisory on this host — cli-exit-codes.sh X7 already drives that path through
#          deny_unlink() with a probe-first SKIP, and it is the same call site. Repeating
#          it here would add a second row that skips on exactly the same hosts.
# L3 gap:  EXDEV. The stub and its `.bak` are always in the same directory, so a
#          cross-device rename cannot occur under any fixture; on a real machine a
#          bind-mounted or junctioned project directory could still produce one, and only
#          a run against such a tree would show whether the errno path reads sensibly.

# SKIPPED: a `via` naming a file that has been REPLACED between plan and execute by a
#          different file with the same basename (an inode swap).
# Because: the guard this file is about is a path-shape check; the content check that
#          follows it is I2, re-run against the live file, and lifecycle-race.sh R-4/R-5
#          already drive exactly that substitution. Nothing here would add coverage.
# L3 gap:  a genuinely concurrent writer between the re-verification and the rename —
#          the residual TOCTOU window the backup exists to make survivable.

run_j_forged_via
run_j_backup
run_j_backup_reported
