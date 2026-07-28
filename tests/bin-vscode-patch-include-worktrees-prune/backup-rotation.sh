# Part of tests/bin-vscode-patch-include-worktrees-prune.sh (sourced, not standalone).
# Tests: bin/lib/vscode-patch-include-worktrees/prune/execute.js, bin/lib/vscode-patch-include-worktrees/cli.js
# Tags: bin, vscode, prune, execute, backup, rescue, session-files, scope:common, pwsh-not-required, TL2
#
# J11-J15 — the rescue copy across REPEATED prunes of the same session.
#
# execute-guard.sh J06-J10 established that one prune displaces the stub instead of
# destroying it. This file is about the second and third time, which is the ordinary case
# rather than an exotic one: the uuid is the session's, Claude Code recreates a stub under
# it, and the tool is meant to be run again. A `renameSync(file, file + '.bak')` that fires
# unconditionally therefore OVERWRITES the rescue copy of the previous stub — and that copy
# is the only place the earlier title still exists. The whole argument for the residual
# TOCTOU window being survivable ("reverting is just dropping the suffix") is void the
# moment the file you would revert to has been silently replaced.
#
# The rule under test (rules/coding.md sanctions the timestamped variant "when history
# preservation is needed"):
#
#   no `<uuid>.jsonl.bak`      -> rename to `<uuid>.jsonl.bak`                 (J11)
#   `<uuid>.jsonl.bak` present -> rename to `<uuid>.jsonl.bak.YYYYMMDD_HHMMSS`,
#                                 and the pre-existing `.bak` is NOT touched   (J08, J12)
#
# Pattern 1 throughout: the assertion is never the exit code alone, it is that each
# predecessor rescue copy is still present and still byte-identical.

# The `backup=` value from a report line, or the empty string.
backup_field() { # <report-line>
  printf '%s\n' "$1" | tr ' ' '\n' | grep '^backup=' | head -1 | sed 's/^backup=//'
}

# stub + real, the minimal group in which a prune is authorised at all.
rotation_fixture() { # <projects-root> <stub-title>
  { title_line "$SID_A" "$2"; } | mk_session "$1/stub" "$SID_A"
  { content_line "$SID_A"; } | mk_session "$1/real" "$SID_A"
}

# ---- J11: the sanctioned direction — first prune, plain .bak ----------------

# Pattern 4. The timestamped form must be the EXCEPTION, reached only when the plain name
# is taken. A fix that always timestamps would satisfy every "predecessor survives" row in
# this file and still be wrong: it turns the session store into an ever-growing pile of
# rescue copies and it breaks the one-step revert the design rests on.
run_j_first_prune_plain() {
  local home ext proj stub before line
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  rotation_fixture "$proj" "Alpha"
  stub="$(session_path "$proj/stub" "$SID_A")"
  before="$(hash_of "$stub")"

  run_cli_prune "$home" "$ext" "$proj"
  check "J11a: exit 0" "0" "$CLI_RC"
  check_contains "J11b: the prune happened" "pruned=1" "$CLI_OUT"
  check_contains "J11c: nothing failed" "failed=0" "$CLI_OUT"
  check_file "J11d: with no .bak present the plain name is used" "$stub.bak"
  check "J11e: and it is byte-identical to the stub" "$before" "$(hash_of "$stub.bak")"
  check "J11f: no timestamped copy is written when the plain name was free" "" \
    "$(timestamped_backup "$proj/stub" "$SID_A")"
  check "J11g: exactly one file in the stub directory" "1" "$(count_files "$proj/stub")"
  line="$(prune_line "pruned" "$CLI_OUT")"
  check "J11h: backup= names the plain .bak that was actually written" \
    "$SID_A.jsonl.bak" "$(backup_field "$line")"
}

# ---- J12: a THIRD prune destroys neither predecessor ------------------------

# The `.bak.<ts>` predecessor is seeded with a fixed historical stamp rather than being
# produced by a preceding run: two runs inside the same wall-clock second would otherwise
# generate the same name, and the row would be testing the clock instead of the rule.
run_j_third_prune() {
  local home ext proj stub old_ts h_bak h_old h3 line newest
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  rotation_fixture "$proj" "Charlie"
  stub="$(session_path "$proj/stub" "$SID_A")"
  old_ts="$stub.bak.20000101_000000"
  printf 'rescue copy of stub #1 — the oldest title\n' > "$stub.bak"
  printf 'rescue copy of stub #2 — the second title\n' > "$old_ts"
  h_bak="$(hash_of "$stub.bak")"
  h_old="$(hash_of "$old_ts")"
  h3="$(hash_of "$stub")"

  run_cli_prune "$home" "$ext" "$proj"
  check "J12a: exit 0" "0" "$CLI_RC"
  check_contains "J12b: the third prune still happens" "pruned=1" "$CLI_OUT"
  check_contains "J12c: nothing failed" "failed=0" "$CLI_OUT"
  check_file "J12d: predecessor #1 (.bak) still exists" "$stub.bak"
  check "J12e: predecessor #1 is byte-identical" "$h_bak" "$(hash_of "$stub.bak")"
  check_file "J12f: predecessor #2 (.bak.<ts>) still exists" "$old_ts"
  check "J12g: predecessor #2 is byte-identical" "$h_old" "$(hash_of "$old_ts")"
  newest="$(timestamped_backup "$proj/stub" "$SID_A")"
  check "J12h: a third rescue copy was written, not one of the predecessors" "ok" \
    "$([ -n "$newest" ] && [ "$newest" != "$old_ts" ] && echo ok || echo "got:$newest")"
  check "J12i: and it holds the stub this run displaced" "$h3" "$(hash_of "$newest")"
  check "J12j: three rescue copies now coexist" "3" "$(count_files "$proj/stub")"
  line="$(prune_line "pruned" "$CLI_OUT")"
  check "J12k: backup= names the file this run wrote" \
    "$(basename "$newest")" "$(backup_field "$line")"
}

# ---- J13: every rescue copy is inert ----------------------------------------

# J09 covers the plain `.bak`. The timestamped form ends in digits rather than `.bak`, so
# it is a DIFFERENT string against SESSION_FILE_PATTERN — a pattern loosened to `\.jsonl`
# anywhere in the name would let it back in, and the tool would start reasoning about its
# own debris. Asserted on a tree holding both forms at once.
run_j_rescue_copies_inert() {
  local home ext proj stub
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  { content_line "$SID_A"; } | mk_session "$proj/real" "$SID_A"
  mkdir -p "$proj/stub"
  stub="$(session_path "$proj/stub" "$SID_A")"
  printf 'rescue copy #1\n' > "$stub.bak"
  printf 'rescue copy #2\n' > "$stub.bak.20000101_000000"

  run_cli_prune "$home" "$ext" "$proj"
  check "J13a: exit 0" "0" "$CLI_RC"
  check_contains "J13b: neither rescue copy is enumerated as a session file" \
    "scanned=1 groups=0" "$CLI_OUT"
  check_contains "J13c: nothing is pruned" "pruned=0" "$CLI_OUT"
  check_file "J13d: rescue copy #1 survives the rescan" "$stub.bak"
  check_file "J13e: rescue copy #2 survives the rescan" "$stub.bak.20000101_000000"
  check_file "J13f: the real copy survives too" "$(session_path "$proj/real" "$SID_A")"
}

# ---- J14: --dry-run writes nothing, even with a .bak already present --------

# J07 pins the rehearsal for the plain case. The branch this file adds is reached only
# when a `.bak` exists, so it needs its own rehearsal row: a rehearsal that took the new
# branch and wrote the timestamped file would leave J07 completely green.
run_j_dry_run_with_existing_bak() {
  local home ext proj stub h_stub h_bak line field
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  rotation_fixture "$proj" "Delta"
  stub="$(session_path "$proj/stub" "$SID_A")"
  printf 'rescue copy that a rehearsal must not disturb\n' > "$stub.bak"
  h_stub="$(hash_of "$stub")"
  h_bak="$(hash_of "$stub.bak")"

  run_cli_prune "$home" "$ext" "$proj" --dry-run
  check "J14a: exit 0" "0" "$CLI_RC"
  check_contains "J14b: the run is a rehearsal" "would-prune=1" "$CLI_OUT"
  check_file "J14c: the stub is untouched" "$stub"
  check "J14d: byte-identical" "$h_stub" "$(hash_of "$stub")"
  check "J14e: the pre-existing .bak is byte-identical too" "$h_bak" "$(hash_of "$stub.bak")"
  check "J14f: no timestamped copy was written" "" \
    "$(timestamped_backup "$proj/stub" "$SID_A")"
  check "J14g: exactly two files — the stub and its one rescue copy" "2" \
    "$(count_files "$proj/stub")"
  # A cautious user looks at --dry-run FIRST. If the rehearsal advertises `.jsonl.bak` and
  # the real run then writes `.jsonl.bak.<ts>`, the rehearsal has told them the wrong
  # recovery path — which is worse than telling them nothing.
  line="$(prune_line "would-prune" "$CLI_OUT")"
  field="$(backup_field "$line")"
  check "J14h: the rehearsal reports the timestamped name it WOULD write" "ok" \
    "$(printf '%s' "$field" | grep -qE "^$SID_A\.jsonl\.bak\.[0-9]{8}_[0-9]{6}\$" && echo ok || echo "got:$field")"
}

# ---- J15: the revert round-trip ---------------------------------------------

# The entire safety argument is "dropping the suffix restores the file". That is a claim
# about bytes, and it is worth one row that actually performs the revert rather than
# inferring it from a hash of something still sitting under the backup name.
run_j_revert_round_trip() {
  local home ext proj stub before ts
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  rotation_fixture "$proj" "Echo"
  stub="$(session_path "$proj/stub" "$SID_A")"
  printf 'an older rescue copy, forcing the timestamped branch\n' > "$stub.bak"
  before="$(hash_of "$stub")"

  run_cli_prune "$home" "$ext" "$proj"
  check_contains "J15a: the prune happened" "pruned=1" "$CLI_OUT"
  ts="$(timestamped_backup "$proj/stub" "$SID_A")"
  if [ -z "$ts" ]; then
    echo "FAIL: J15b: a timestamped rescue copy exists to revert from -- none written"
    FAIL=$((FAIL + 1))
    return 0
  fi
  mv "$ts" "$stub"
  check_file "J15b: the session file is back under its own name" "$stub"
  check "J15c: and it is byte-identical to what was displaced" "$before" "$(hash_of "$stub")"
  check_file "J15d: the earlier rescue copy is still there afterwards" "$stub.bak"
}

# ---- J16: the same-second collision -----------------------------------------
#
# J12 seeds its `.bak.<ts>` predecessor with a FIXED historical stamp, so it proves that an
# OLD generation survives and says nothing about a stamp equal to the one this run would
# produce. backupPathFor probes the plain `.bak` only, and when that name is taken it returns
# `plain + '.' + backupTimestamp()` UNCONDITIONALLY — so a rescue copy written earlier in the
# same wall-clock second is silently replaced by renameSync, which replaces an existing
# destination on both POSIX and Windows. That is the exact opposite of the header's claim
# that "no earlier rescue copy is destroyed either", and the second-per-generation resolution
# is not a theoretical limit: a shell loop, a retry, or two roots in one pass all land inside
# one second routinely.
#
# Driven at the MODULE boundary and made deterministic without a clock seam: the stamp is
# taken from the module's own backupTimestamp(), the collision is seeded with it, and the
# stamp is re-read afterwards — if the second rolled over mid-row the attempt is retried
# rather than asserted on. The assertion is therefore implementation-independent: whatever
# scheme is used (a probe loop, an injected clock, a counter suffix), the returned path must
# simply be a name nothing holds yet.
run_j_same_second_collision() {
  local proj stub
  proj="$(new_proj_root)"
  rotation_fixture "$proj" "Foxtrot"
  stub="$(session_path "$proj/stub" "$SID_A")"

  J_STUB="$(native_file "$stub")" node_m "
const fs=require('fs');
const x=require('$EXECUTE_REQUIRE');
const file=process.env.J_STUB;
let out='no-attempt';
for (let attempt=0; attempt<8; attempt++) {
  const ts=x.backupTimestamp();
  const plain=file+'.bak';
  const stamped=plain+'.'+ts;
  fs.writeFileSync(plain, 'rescue copy of an earlier stub\n');
  fs.writeFileSync(stamped, 'rescue copy written earlier in THIS second\n');
  const got=x.backupPathFor(file);
  // Only assert on an attempt that stayed inside one second: otherwise the seeded stamp is
  // not the one a colliding implementation would have produced, and the row would pass for
  // the wrong reason.
  if (x.backupTimestamp() !== ts) { fs.unlinkSync(plain); fs.unlinkSync(stamped); continue; }
  out = (got===plain) ? 'reused-plain'
      : (got===stamped) ? 'collides-with-same-second-copy'
      : fs.existsSync(got) ? 'collides-with:'+got
      : 'unused';
  break;
}
console.log('P='+out);"
  check "J16a: with the plain .bak and a same-second .bak.<ts> both taken, an UNUSED name is returned" \
    "P=unused" "$NODE_OUT"
}

# ---- J17: the run reports the name it actually wrote ------------------------
#
# The whole recovery story is the `backup=` field: the report alone is meant to be enough to
# revert. A collision breaks that in two ways at once — a predecessor is destroyed, and the
# name printed is the name of a file whose CONTENTS are now someone else's. Driven through
# the real CLI so the assertion covers the path from backupPathFor through renameSync to the
# report line, and seeded across a window of stamps around "now" so that whichever second the
# spawned process lands in is already occupied.
run_j_collision_window_cli() {
  local home ext proj stub before line field seeded
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  rotation_fixture "$proj" "Golf"
  stub="$(session_path "$proj/stub" "$SID_A")"
  before="$(hash_of "$stub")"
  printf 'rescue copy of stub #1\n' > "$stub.bak"

  # One seeded copy per second across the window the spawned CLI can plausibly land in, each
  # with distinct bytes so an overwrite is visible as a changed digest rather than a changed
  # count alone.
  J_STUB="$(native_file "$stub")" node_m "
const fs=require('fs');
const x=require('$EXECUTE_REQUIRE');
const file=process.env.J_STUB;
const names=[];
for (let d=-1; d<=6; d++) {
  const ts=x.backupTimestamp(new Date(Date.now()+d*1000));
  const p=file+'.bak.'+ts;
  fs.writeFileSync(p, 'seeded rescue copy for second '+ts+'\n');
  names.push(ts);
}
console.log('S='+names.length);"
  check "J17a: the collision window was seeded" "S=8" "$NODE_OUT"
  seeded="$(find "$proj/stub" -maxdepth 1 -type f -name "$SID_A.jsonl.bak.*" | sort)"
  # Each seeded copy names its own second in its body, so "was this one overwritten?" is
  # answerable per file. The assertion below reports the NAMES that changed rather than a
  # wall of digests, so a failure says which second collided.

  run_cli_prune "$home" "$ext" "$proj"
  check "J17b: exit 0" "0" "$CLI_RC"
  check_contains "J17c: the prune still happens" "pruned=1" "$CLI_OUT"
  check_contains "J17d: nothing failed" "failed=0" "$CLI_OUT"
  check "J17e: every seeded rescue copy is still present and byte-identical (clobbered names)" \
    "" "$(printf '%s\n' "$seeded" | while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ ! -f "$f" ]; then printf '%s(gone) ' "$(basename "$f")"; continue; fi
      grep -qF -- "seeded rescue copy for second ${f##*.bak.}" "$f" || printf '%s ' "$(basename "$f")"
    done)"
  check "J17f: the plain .bak predecessor is untouched too" \
    "rescue copy of stub #1" "$(cat "$stub.bak")"
  # 1 plain + 8 seeded + 1 written by this run. A collision shows up here as 9.
  check "J17g: this run added a rescue copy rather than replacing one" "10" \
    "$(count_files "$proj/stub")"
  line="$(prune_line "pruned" "$CLI_OUT")"
  field="$(backup_field "$line")"
  check "J17h: backup= names a file that exists" "ok" \
    "$([ -n "$field" ] && [ -f "$proj/stub/$field" ] && echo ok || echo "got:$field")"
  check "J17i: and that file holds the stub this run displaced" "$before" \
    "$([ -n "$field" ] && [ -f "$proj/stub/$field" ] && hash_of "$proj/stub/$field" || echo missing)"
}

# SKIPPED: the timestamped rename itself failing (EACCES/EPERM on a read-only parent).
# Because: chmod is advisory on this host — cli-exit-codes.sh X7 already drives the
#          rename-failure path through deny_unlink() with a probe-first SKIP, and both
#          branches of the naming rule reach the same renameSync call site.
# L3 gap:  a POSIX host where the parent directory is genuinely unwritable, which would
#          show whether the errno surfaces as `failed` with the errno as the reason for
#          the timestamped branch too.

# SKIPPED: two FULL CLI runs genuinely racing inside the same wall-clock second.
# Because: J16 now closes the naming rule deterministically at the module boundary (the
#          stamp is taken from the module, the collision is seeded with it, and the row is
#          retried if the second rolls over), and J17 drives the same collision through the
#          real CLI against a seeded window of stamps. What neither reproduces is two
#          processes reaching renameSync concurrently: the harness would have to win a race
#          it cannot schedule, and the module exposes no seam to pause one side.
# L3 gap:  a real prune of a large ~/.claude/projects driven twice in quick succession by a
#          script or a shell loop, where the two runs overlap rather than merely share a
#          second — the residual TOCTOU window between backupPathFor's probe and the rename.
#          J17's window is also a heuristic in one direction: if the spawned process took
#          longer than the seeded window to reach the rename, the collision it is looking
#          for would not occur and the row would pass without exercising it.

run_j_first_prune_plain
run_j_third_prune
run_j_rescue_copies_inert
run_j_dry_run_with_existing_bak
run_j_revert_round_trip
run_j_same_second_collision
run_j_collision_window_cli
