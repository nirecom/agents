# Fault, crash and lock cases (M5-M8, M13) for feat-2511-session-relocation.sh.
# Sourced by the dispatcher after its pin; defines case bodies only.

# A failure before the commit point leaves the legacy root authoritative and intact.
m5_one() {
  local fault="$1" sid="$2" before
  seed_session "$LEG" "$sid"
  before="$(snap "$LEG")"
  move "$sid" "$fault"
  like "M5 $fault: one RELOCATE_FAILED line" "$MV_OUT" "RELOCATE_FAILED*"
  [[ "$fault" != reconcile && "$fault" != lstat ]] || like "M5 $fault: stopped by the kept-entry check" "$MV_OUT" "RELOCATE_FAILED sid=$sid reason=reconcile *"
  eq "M5 $fault: exactly one stdout line" "$(lines "$MV_OUT")" "1"
  eq "M5 $fault: stderr is empty" "$MV_ERR" ""
  eq "M5 $fault: exit 0" "$MV_RC" "0"
  eq "M5 $fault: the legacy root is byte-identical" "$(snap "$LEG")" "$before"
  eq "M5 $fault: no new-root entry for the sid" "$(entries "$NEW" "$sid")" ""
  eq "M5 $fault: no work dir is left" "$(workdirs "$NEW" "$sid")" ""
  eq "M5 $fault: the session still routes legacy" "$(route "$sid")" "$LEG"
}

c_m5_pre_commit_faults() {
  local fault i=0
  new_home m5
  # reconcile: only the control dir's re-copy fails while the json reconciles cleanly; that
  # one kept entry must still stop the commit (neither root split, the session routes legacy).
  # lstat: a non-ENOENT stat error on the control dir is a kept entry, never a deletion.
  for fault in copy rewrite reconcile lstat json-rename; do
    i=$((i + 1))
    m5_one "$fault" "$(sid_of "50$i")"
  done
}

c_m6_old_delete() {
  local sid
  new_home m6
  sid="$(sid_of 601)"
  seed_session "$LEG" "$sid"
  move "$sid" old-delete
  like "M6 old-delete: RELOCATED with leftovers > 0" "$MV_OUT" "RELOCATED sid=$sid entries=* leftovers=[1-9]*"
  eq "M6 old-delete: the new json is committed" "$(test -f "$NEW/$sid.json" && echo present)" "present"
  eq "M6 old-delete: the session routes to the new root" "$(route "$sid")" "$NEW"
}

# crash_then_recover <label> <fault> <sid> <premise-fn> — the fault kills the mover; the
# premise proves the fault fired; a rerun after the dead mover's locks age finishes it.
crash_then_recover() {
  local label="$1" fault="$2" sid="$3"
  mkdir -p "$T/$label-orig"
  cp "$LEG/$sid.control/supervisor-state.json" "$T/$label-orig/"
  move "$sid" "$fault"
  "$4" "$sid"
  eq "$label: the json is not published by the crash" "$(test -e "$NEW/$sid.json" || echo absent)" "absent"
  eq "$label: the session still routes legacy after the crash" "$(route "$sid")" "$LEG"
  age_locks "$LEG"
  move "$sid"
  like "$label: the rerun reports RELOCATED" "$MV_OUT" "RELOCATED sid=$sid *"
  eq "$label: the rerun routes to the new root" "$(route "$sid")" "$NEW"
  eq "$label: the new control dir holds the original supervisor state" \
    "$(cmp -s "$T/$label-orig/supervisor-state.json" "$NEW/$sid.control/supervisor-state.json" && echo same)" "same"
  eq "$label: the marker reached the new root" "$(cat "$NEW/$sid.workflow-off" 2>/dev/null || true)" "off"
  eq "$label: no work dir is left" "$(workdirs "$NEW" "$sid")" ""
}

m7_premise() {
  eq "M7 premise: the control dir was published before the crash" \
    "$(test -d "$NEW/$1.control" && echo published)" "published"
}

m7b_premise() {
  like "M7b premise: a non-json entry is left in the new root" "$(entries "$NEW" "$1")" "?*"
}

c_m7_control_crash() {
  local sid
  new_home m7
  sid="$(sid_of 701)"
  seed_session "$LEG" "$sid"
  crash_then_recover "M7" control-rename "$sid" m7_premise
}

c_m7b_rollback_crash() {
  local sid
  new_home m7b
  sid="$(sid_of 711)"
  seed_session "$LEG" "$sid"
  crash_then_recover "M7b" rollback "$sid" m7b_premise
}

# #2512 security F3: the one-shot OFF-clearance token and claim are dropped, never
# migrated — a copy would survive an unlocked consumer spending the legacy token.
c_m7c_stale_clearance() {
  local sid n
  new_home m7c
  sid="$(sid_of 721)"
  seed_session "$LEG" "$sid"
  printf 'legacy-copy\n' >"$LEG/$sid.off-clearance"
  printf 'legacy-claim\n' >"$LEG/$sid.off-clearance.claimed"
  mkdir -p "$NEW"
  printf 'stale\n' >"$NEW/$sid.off-clearance"
  eq "M7c premise: a clearance-only sid still routes legacy" "$(route "$sid")" "$LEG"
  move "$sid"
  like "M7c the stale clearance does not stop the move" "$MV_OUT" "RELOCATED sid=$sid * leftovers=0"
  for n in "$sid.off-clearance" "$sid.off-clearance.claimed"; do
    eq "M7c $n is not present in the new root" "$(test -e "$NEW/$n" || echo absent)" "absent"
    eq "M7c $n is removed from the legacy root" "$(test -e "$LEG/$n" || echo gone)" "gone"
  done
  eq "M7c the rest of the session still moved" "$(test -e "$NEW/$sid.workflow-off" && echo present)" "present"
}

c_m8_stale_workdir() {
  local sid other
  new_home m8
  sid="$(sid_of 801)"
  other="$(sid_of 802)"
  seed_session "$LEG" "$sid"
  mkdir -p "$NEW/.relocating-$sid-99999/$sid.control" "$NEW/.relocating-$other-1"
  printf 'junk\n' >"$NEW/.relocating-$sid-99999/$sid.json"
  move "$sid"
  like "M8 the move succeeds over a crashed work dir" "$MV_OUT" "RELOCATED sid=$sid *"
  eq "M8 the crashed work dir of the sid is swept" "$(workdirs "$NEW" "$sid")" ""
  eq "M8 another sid's work dir is left alone" "$(test -d "$NEW/.relocating-$other-1" && echo kept)" "kept"
  eq "M8 the committed json is the session's, not the junk" "$(grep -c junk "$NEW/$sid.json" 2>/dev/null || true)" "0"
}

c_m13_lock() {
  local sid lockd before
  new_home m13
  sid="$(sid_of 1301)"
  seed_session "$LEG" "$sid"
  lockd="$LEG/$sid.control/supervisor-state.json.lock"
  mkdir -p "$lockd"
  printf 'held-by-test' >"$lockd/owner"
  before="$(snap "$LEG")"
  move "$sid"
  like "M13 a held supervisor lock -> lock-timeout" "$MV_OUT" "RELOCATE_FAILED*reason=lock-timeout*"
  eq "M13 the legacy root is intact" "$(snap "$LEG")" "$before"
  eq "M13 no new-root entry for the sid" "$(entries "$NEW" "$sid")" ""
  rm -rf "$lockd"
  printf 'partial\n' >"$LEG/$sid.control/supervisor-state.json.tmp"
  printf 'partial\n' >"$LEG/$sid.note.tmp"
  move "$sid"
  like "M13 without the lock the move succeeds" "$MV_OUT" "RELOCATED sid=$sid *"
  eq "M13 no .lock or .tmp name reached the new root" \
    "$(find "$NEW" \( -name '*.lock' -o -name '*.tmp' \) 2>/dev/null || true)" ""
}

# The workflow-state lock (<sid>.json.lock, taken first) held by another writer.
# The holder names a foreign host so state-lock.js never reclaims it as a dead pid,
# and its mtime is fresh so it is not stale by age.
# Assumption: the mover honours STATE_RELOCATION_LOCK_TIMEOUT_MS to shorten the wait;
# if it does not, the default state-lock timeout (3 s) still ends the wait.
c_m13_state_lock() {
  local sid lockf before
  new_home m13s
  sid="$(sid_of 1311)"
  seed_session "$LEG" "$sid"
  lockf="$LEG/$sid.json.lock"
  printf '{"pid":1,"host":"other-host-2511.example","at":"%s"}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$lockf"
  before="$(snap "$LEG")"
  MV_EXTRA=("STATE_RELOCATION_LOCK_TIMEOUT_MS=500")
  move "$sid"
  MV_EXTRA=()
  like "M13s a held workflow-state lock -> lock-timeout" "$MV_OUT" "RELOCATE_FAILED*reason=lock-timeout*"
  eq "M13s exit 0 with one stdout line" "$MV_RC|$(lines "$MV_OUT")" "0|1"
  eq "M13s the legacy root is intact (lock file included)" "$(snap "$LEG")" "$before"
  eq "M13s no new-root entry for the sid" "$(entries "$NEW" "$sid")" ""
  eq "M13s the session still routes legacy" "$(route "$sid")" "$LEG"
  rm -f "$lockf"
  move "$sid"
  like "M13s after the holder releases, a rerun succeeds" "$MV_OUT" "RELOCATED sid=$sid *"
  eq "M13s the rerun routes to the new root" "$(route "$sid")" "$NEW"
  eq "M13s no .lock name reached the new root" "$(find "$NEW" -name '*.lock' 2>/dev/null || true)" ""
}

# Codex C3: a writer that resolved the legacy path before the commit and writes after
# it must not lose its write to the legacy delete. deleteLegacy now runs inside the
# mover's locks (#2512 C1), so the driver wraps fs.rmSync: the first legacy removal is
# deleteLegacy's, and the late writers run just before it, in-process.
# Each writer resolves its path inside its lock, as the real state-io and supervisor
# writers do; an unlocked writer holding a pre-resolved path is M16's case.
M14_DRIVER='
const fs = require("fs");
const path = require("path");
const [A, sid, leg] = process.argv.slice(1);
const core = require(A + "/hooks/workflow-state/state-io/core.js");
const stateLock = require(A + "/hooks/workflow-state/state-io/state-lock.js");
const supLock = require(A + "/hooks/lib/supervisor-state-writer/lock.js");
const supShared = require(A + "/hooks/lib/supervisor-state-writer/shared.js");
const { relocate } = require(A + "/hooks/lib/temporary-migrations/state-dir-relocation/move.js");
const legN = path.resolve(leg);
const slash = (p) => String(p).replace(/\\/g, "/");
const r = { preState: slash(core.getStatePath(sid)), preSup: slash(supShared.getStatePath(sid, { forWrite: true })), window: 0 };
const realRm = fs.rmSync;
fs.rmSync = function (p, o) {
  if (path.resolve(String(p)).startsWith(legN + path.sep) && r.window === 0) {
    r.window = 1;
    try {
      r.stateWrote = slash(stateLock.withStateLock(sid, () => {
        const f = core.getStatePath(sid);
        const s = JSON.parse(fs.readFileSync(f, "utf8"));
        s.late_writer = "kept";
        fs.writeFileSync(f, JSON.stringify(s));
        return f;
      }));
    } catch (e) { r.stateErr = String(e.message); }
    try {
      r.supWrote = slash(supLock.withSessionStateLock(sid, () => {
        const f = supShared.getStatePath(sid, { forWrite: true });
        const s = JSON.parse(fs.readFileSync(f, "utf8"));
        s.late_writer = "kept";
        fs.writeFileSync(f, JSON.stringify(s));
        return f;
      }));
    } catch (e) { r.supErr = String(e.message); }
  }
  return realRm.call(this, p, o);
};
r.line = relocate(sid);
process.stdout.write(JSON.stringify(r));
'

# m14_field <json> <key> — one top-level string field of the driver report.
m14_field() { node -e 'const o = JSON.parse(process.argv[1]); process.stdout.write(String(o[process.argv[2]] ?? ""))' "$1" "$2"; }

c_m14_late_writer_window() {
  local sid out
  new_home m14
  sid="$(sid_of 1401)"
  seed_session "$LEG" "$sid"
  out="$(cd "$T/cwd" && run_with_timeout 60 "${DENV[@]}" HOME="$H" USERPROFILE="$H" \
    node -e "$M14_DRIVER" "$A" "$sid" "$LEG" 2>"$T/m14.err")" || true
  like "M14 premise: the move commits" "$(m14_field "$out" line)" "RELOCATED sid=$sid *"
  eq "M14 premise: the state writer resolved the legacy json before the commit" "$(m14_field "$out" preState)" "$LEG/$sid.json"
  eq "M14 premise: the supervisor writer resolved the legacy control dir before the commit" \
    "$(m14_field "$out" preSup)" "$LEG/$sid.control/supervisor-state.json"
  eq "M14 premise: the point after the commit, just before deleteLegacy, was reached" "$(m14_field "$out" window)" "1"
  eq "M14 the state writer in the window has no error" "$(m14_field "$out" stateErr)" ""
  eq "M14 the state writer in the window lands in the new root" "$(m14_field "$out" stateWrote)" "$NEW/$sid.json"
  eq "M14 the state write survives deleteLegacy" "$(grep -c '"late_writer":"kept"' "$NEW/$sid.json" 2>/dev/null || true)" "1"
  eq "M14 the supervisor writer in the window has no error" "$(m14_field "$out" supErr)" ""
  eq "M14 the supervisor writer in the window lands in the new root" \
    "$(m14_field "$out" supWrote)" "$NEW/$sid.control/supervisor-state.json"
  eq "M14 the supervisor write survives deleteLegacy" \
    "$(grep -c '"late_writer":"kept"' "$NEW/$sid.control/supervisor-state.json" 2>/dev/null || true)" "1"
  eq "M14 no legacy json is left for a late write to hide in" "$(test -e "$LEG/$sid.json" || echo absent)" "absent"
  eq "M14 the session routes to the new root" "$(route "$sid")" "$NEW"
}

# #2512 C1: legacy writes that land between the copy and the commit (an unlocked marker
# writer, or a path resolved before the move) are reconciled into the new root before
# the legacy delete. The driver wraps fs.renameSync and mutates the legacy session just
# before the commit rename of <new>/<sid>.json.
M16_DRIVER='
const fs = require("fs");
const path = require("path");
const [A, sid, leg, nw] = process.argv.slice(1);
const { relocate } = require(A + "/hooks/lib/temporary-migrations/state-dir-relocation/move.js");
const commit = path.resolve(nw, sid + ".json");
const realRename = fs.renameSync;
const r = { fired: 0 };
fs.renameSync = function (from, to) {
  if (r.fired === 0 && path.resolve(String(to)) === commit) {
    r.fired = 1;
    fs.writeFileSync(path.join(leg, sid + ".workflow-off"), "changed\n");
    fs.writeFileSync(path.join(leg, sid + ".control", "late.txt"), "late\n");
    fs.writeFileSync(path.join(leg, sid + ".next-step-paused"), "marker\n");
    fs.rmSync(path.join(leg, sid + ".instructions-loaded", "CLAUDE.md"));
  }
  return realRename.call(this, from, to);
};
r.line = relocate(sid);
process.stdout.write(JSON.stringify(r));
'

c_m16_mid_move_writes() {
  local sid out
  new_home m16
  sid="$(sid_of 1601)"
  seed_session "$LEG" "$sid"
  out="$(cd "$T/cwd" && run_with_timeout 60 "${DENV[@]}" HOME="$H" USERPROFILE="$H" \
    node -e "$M16_DRIVER" "$A" "$sid" "$LEG" "$NEW" 2>"$T/m16.err")" || true
  eq "M16 premise: the legacy writes ran just before the commit" "$(m14_field "$out" fired)" "1"
  like "M16 the move commits with no leftovers" "$(m14_field "$out" line)" "RELOCATED sid=$sid entries=* leftovers=0"
  eq "M16 a changed legacy file is re-copied" "$(cat "$NEW/$sid.workflow-off" 2>/dev/null || true)" "changed"
  eq "M16 a file added inside a copied dir is copied" "$(cat "$NEW/$sid.control/late.txt" 2>/dev/null || true)" "late"
  eq "M16 a top-level entry added since the copy is copied" "$(cat "$NEW/$sid.next-step-paused" 2>/dev/null || true)" "marker"
  eq "M16 a file deleted from legacy is removed from the new root" \
    "$(test -e "$NEW/$sid.instructions-loaded/CLAUDE.md" || echo absent)" "absent"
  eq "M16 the legacy session is gone" "$(entries "$LEG" "$sid")" ""
  eq "M16 the session routes to the new root" "$(route "$sid")" "$NEW"
}

# #2512 review: the post-commit reconcile must treat a stat it cannot complete as a kept
# entry, on either side. The driver changes the legacy marker just before the commit
# rename (as M16) and from then on fails lstat of that marker's <side> path with EPERM.
# dst: a skipped re-copy would let the legacy delete take the newer content.
# src: reading the failure as a deletion would drop the new-root copy.
# dir: readdir of the legacy control dir fails instead; its children must not read as vanished.
M18_DRIVER='
const fs = require("fs");
const path = require("path");
const [A, sid, leg, nw, side] = process.argv.slice(1);
const { relocate } = require(A + "/hooks/lib/temporary-migrations/state-dir-relocation/move.js");
const commit = path.resolve(nw, sid + ".json");
const target = path.resolve(side === "src" ? leg : nw, sid + ".workflow-off");
const ctlDir = path.resolve(leg, sid + ".control");
const realRename = fs.renameSync;
const realLstat = fs.lstatSync;
const realReaddir = fs.readdirSync;
const r = { fired: 0, faulted: 0 };
fs.renameSync = function (from, to) {
  if (r.fired === 0 && path.resolve(String(to)) === commit) {
    r.fired = 1;
    fs.writeFileSync(path.join(leg, sid + ".workflow-off"), "changed\n");
  }
  return realRename.call(this, from, to);
};
fs.lstatSync = function (p, o) {
  if (side !== "dir" && r.fired === 1 && path.resolve(String(p)) === target) {
    r.faulted = 1;
    throw Object.assign(new Error("injected EPERM"), { code: "EPERM" });
  }
  return realLstat.call(this, p, o);
};
fs.readdirSync = function (p, o) {
  if (side === "dir" && r.fired === 1 && path.resolve(String(p)) === ctlDir) {
    r.faulted = 1;
    throw Object.assign(new Error("injected EPERM"), { code: "EPERM" });
  }
  return realReaddir.call(this, p, o);
};
r.line = relocate(sid);
process.stdout.write(JSON.stringify(r));
'

c_m18_post_commit_stat_errors() {
  local side sid out n=1800
  for side in dst src; do
    n=$((n + 1))
    new_home "m18-$side"
    sid="$(sid_of "$n")"
    seed_session "$LEG" "$sid"
    out="$(cd "$T/cwd" && run_with_timeout 60 "${DENV[@]}" HOME="$H" USERPROFILE="$H" \
      node -e "$M18_DRIVER" "$A" "$sid" "$LEG" "$NEW" "$side" 2>"$T/m18.err")" || true
    eq "M18 $side premise: the legacy marker changed just before the commit" "$(m14_field "$out" fired)" "1"
    eq "M18 $side premise: the post-commit lstat failed" "$(m14_field "$out" faulted)" "1"
    like "M18 $side: the entry is counted as a leftover" "$(m14_field "$out" line)" "RELOCATED sid=$sid entries=* leftovers=1"
    eq "M18 $side: the newer legacy content is not deleted" "$(cat "$LEG/$sid.workflow-off" 2>/dev/null || true)" "changed"
    eq "M18 $side: the new-root copy is not dropped" "$(test -e "$NEW/$sid.workflow-off" && echo present)" "present"
    eq "M18 $side: the session routes to the new root" "$(route "$sid")" "$NEW"
  done
  new_home m18-dir
  sid="$(sid_of 1803)"
  seed_session "$LEG" "$sid"
  out="$(cd "$T/cwd" && run_with_timeout 60 "${DENV[@]}" HOME="$H" USERPROFILE="$H" \
    node -e "$M18_DRIVER" "$A" "$sid" "$LEG" "$NEW" dir 2>"$T/m18.err")" || true
  eq "M18 dir premise: the post-commit readdir failed" "$(m14_field "$out" faulted)" "1"
  like "M18 dir: the control dir is counted as a leftover" "$(m14_field "$out" line)" "RELOCATED sid=$sid entries=* leftovers=1"
  eq "M18 dir: a child under the unreadable dir is not dropped from the new root" \
    "$(cat "$NEW/$sid.control/supervisor-state.json" 2>/dev/null || true)" '{"layer1":{"findings":[]}}'
  eq "M18 dir: the legacy child is not deleted" "$(test -e "$LEG/$sid.control/supervisor-state.json" && echo present)" "present"
}

# #2512 round 2 #3: after the commit every writer locks new-root paths, so the mover
# holds the new-root workflow-state and supervisor locks from before the commit through
# deleteLegacy. The driver (1) unlinks the legacy marker just before the commit rename,
# as an unlocked WORKFLOW_ON does, and (2) at deleteLegacy's first legacy removal asks a
# separate process to take both new-root locks: it must be refused while the mover runs.
M17_DRIVER='
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const [A, sid, leg, nw] = process.argv.slice(1);
const { relocate } = require(A + "/hooks/lib/temporary-migrations/state-dir-relocation/move.js");
const commit = path.resolve(nw, sid + ".json");
const legN = path.resolve(leg);
const CHILD = `
const [A, sid] = process.argv.slice(1);
const stateLock = require(A + "/hooks/workflow-state/state-io/state-lock.js");
const supLock = require(A + "/hooks/lib/supervisor-state-writer/lock.js");
const out = {};
try { out.state = stateLock.withStateLock(sid, () => "ran", { timeoutMs: 300 }); }
catch (e) { out.state = e.name; }
console.error = () => {};
out.sup = String(supLock.withSessionStateLock(sid, () => "ran"));
process.stdout.write(JSON.stringify(out));
`;
const realRename = fs.renameSync;
const realRm = fs.rmSync;
const r = { unlinked: 0, window: 0 };
fs.renameSync = function (from, to) {
  if (r.unlinked === 0 && path.resolve(String(to)) === commit) {
    r.unlinked = 1;
    fs.unlinkSync(path.join(leg, sid + ".workflow-off"));
  }
  return realRename.call(this, from, to);
};
fs.rmSync = function (p, o) {
  if (r.window === 0 && path.resolve(String(p)).startsWith(legN + path.sep)) {
    r.window = 1;
    const c = spawnSync(process.execPath, ["-e", CHILD, A, sid], { encoding: "utf8", timeout: 20000 });
    try { Object.assign(r, JSON.parse(c.stdout)); } catch (_) { r.childErr = String(c.stderr || c.error); }
  }
  return realRm.call(this, p, o);
};
r.line = relocate(sid);
process.stdout.write(JSON.stringify(r));
'

c_m17_new_root_locks_held() {
  local sid out
  new_home m17
  sid="$(sid_of 1701)"
  seed_session "$LEG" "$sid"
  out="$(cd "$T/cwd" && run_with_timeout 60 "${DENV[@]}" HOME="$H" USERPROFILE="$H" \
    node -e "$M17_DRIVER" "$A" "$sid" "$LEG" "$NEW" 2>"$T/m17.err")" || true
  eq "M17 premise: the legacy marker was unlinked just before the commit" "$(m14_field "$out" unlinked)" "1"
  eq "M17 premise: deleteLegacy's window was reached" "$(m14_field "$out" window)" "1"
  like "M17 the move commits with no leftovers" "$(m14_field "$out" line)" "RELOCATED sid=$sid entries=* leftovers=0"
  eq "M17 another process cannot take the new-root workflow-state lock before deleteLegacy ends" \
    "$(m14_field "$out" state)" "StateLockTimeoutError"
  eq "M17 another process cannot take the new-root supervisor lock before deleteLegacy ends" \
    "$(m14_field "$out" sup)" "undefined"
  eq "M17 a marker unlinked from legacy before the commit is not left in the new root" \
    "$(test -e "$NEW/$sid.workflow-off" || echo absent)" "absent"
  eq "M17 no new-root lock is left after the move" "$(find "$NEW" -name '*.lock' 2>/dev/null || true)" ""
  eq "M17 the session routes to the new root" "$(route "$sid")" "$NEW"
}

case_begin "m17-new-root-locks-held-through-delete" "hooks/lib/temporary-migrations/state-dir-relocation/move.js"
c_m17_new_root_locks_held
case_end

case_begin "m14-late-writer-before-legacy-delete" "hooks/lib/temporary-migrations/state-dir-relocation/move.js"
c_m14_late_writer_window
case_end

case_begin "m16-mid-move-writes-reconciled" "hooks/lib/temporary-migrations/state-dir-relocation/reconcile.js"
c_m16_mid_move_writes
case_end

case_begin "m18-post-commit-stat-errors-kept" "hooks/lib/temporary-migrations/state-dir-relocation/reconcile.js"
c_m18_post_commit_stat_errors
case_end
