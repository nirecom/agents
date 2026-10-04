#!/usr/bin/env bash
# Tests: hooks/lib/jev/retention.js
# Tags: TL2, hooks, jev, retention, orphan-sweep, time-travel-by-mtime, scope:issue-specific, pwsh-not-required, onorphan-failure, min-claim-age, recheck-before-remove, newest-mtime-files-only, tombstone-rename, leftover-tomb-restore

# Per-session Jev state must not pile up forever: once a day, a post hook removes session
# dirs untouched for 7 days, and any orphan pending inside is first written out as
# "llm missing" so no dispatch disappears silently. Time moves by rewriting mtimes (C11).

# TL3 gap (what this test does NOT catch): the sweep racing a concurrently live session
# on another terminal; the 7-day floor is the only guard and is what these rows pin.

. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
mock_start

DAY=86400000
# seed_old <sid> <tid> <age-ms>: a real pre-hook pending under <sid>, then age the whole dir.
seed_old() {
  mkpayload "$FX/io/pre-$2.json" pre "$1" "$2"
  run_hook pre "$FX/io/pre-$2.json"
  [ -d "$JEVDIR/$1" ] && hq age "$(np "$JEVDIR/$1")" "$3" --recursive
}
# sweep_marker <age-ms>: (re)create <jevStateDir>/.last-retention-sweep with that age.
sweep_marker() {
  mkdir -p "$JEVDIR"
  : > "$JEVDIR/.last-retention-sweep"
  hq age "$(np "$JEVDIR/.last-retention-sweep")" "$1"
}
exists() { [ -e "$1" ] && echo present || echo absent; }

echo "=== due sweep: 8-day dir removed, 6-day dir kept ==="
case_begin "i-sweep-removes-stale-dirs" "hooks/lib/jev/retention.js"
fx_new i-due
mock_mode '{}'
seed_old jev2460-i-old toolu_i_old $((8 * DAY))
seed_old jev2460-i-recent toolu_i_recent $((6 * DAY))
check "fixture: both seeded dirs hold one pending each" "2" "$(pending_count)"
sweep_marker $((25 * 3600000))
LLM_TEXT="SIGNALS: S1-multi-file" pair jev2460-i-new toolu_i_trigger
check "post exits 0" "0" "$HOOK_RC"
check "the 8-day-old session dir is removed" "absent" "$(exists "$JEVDIR/jev2460-i-old")"
check "its orphan pending was written out once as llm missing" "1|missing" \
  "$(rq toolu_i_old 'recs.length + "|" + (r && r.llm.status)')"
check "the 6-day-old session dir is kept, pending untouched" "present|0" \
  "$(exists "$JEVDIR/jev2460-i-recent")|$(rq toolu_i_recent 'recs.length')"
check "the sweep marker was refreshed" "true" \
  "$(run_with_timeout 30 node -e 'const s = require("fs").statSync(process.argv[1]); process.stdout.write(String(Date.now() - s.mtimeMs < 600000));' "$(np "$JEVDIR/.last-retention-sweep")" 2>/dev/null)"
case_end

echo "=== sweep not due ==="
case_begin "i-sweep-throttled-daily" "hooks/lib/jev/retention.js"
fx_new i-notdue
mock_mode '{}'
seed_old jev2460-i-old2 toolu_i_old2 $((8 * DAY))
sweep_marker 3600000
LLM_TEXT="SIGNALS: S1-multi-file" pair jev2460-i-new2 toolu_i_trigger2
check "post exits 0" "0" "$HOOK_RC"
check "marker 1 hour old: the 8-day-old dir survives with its pending" "present|1" \
  "$(exists "$JEVDIR/jev2460-i-old2")|$(find "$JEVDIR/jev2460-i-old2" -path '*/pending/*' -type f 2>/dev/null | wc -l | tr -d ' ')"
check "marker 1 hour old: no record for the old orphan" "0" "$(rq toolu_i_old2 'recs.length')"
case_end

echo "=== a killed hook's parser temp dir is retention's to remove ==="
# seed_norm <path-under-jev-state> <age-ms>: a leftover norm-* dir holding raw.txt, aged whole.
seed_norm() {
  mkdir -p "$JEVDIR/$1"
  printf 'SIGNALS: S1-multi-file\n' > "$JEVDIR/$1/raw.txt"
  hq age "$(np "$JEVDIR/${1%%/*}")" "$2" --recursive
}
case_begin "i-sweep-removes-norm-leftovers" "hooks/lib/jev/retention.js"
fx_new i-norm
mock_mode '{}'
seed_norm jev2460-i-normold/norm-AbC123 $((8 * DAY))
seed_norm jev2460-i-normrecent/norm-AbC123 $((6 * DAY))
seed_norm norm-Old456 $((8 * DAY))
seed_norm norm-New789 $((6 * DAY))
check "fixture: four leftover raw.txt files, two in session dirs and two at the top level" "4|2" \
  "$(find "$JEVDIR" -name raw.txt -type f 2>/dev/null | wc -l | tr -d ' ')|$(find "$JEVDIR" -mindepth 2 -maxdepth 2 -name raw.txt -type f 2>/dev/null | wc -l | tr -d ' ')"
sweep_marker $((25 * 3600000))
LLM_TEXT="SIGNALS: S1-multi-file" pair jev2460-i-normnew toolu_i_normtrigger
check "post exits 0" "0" "$HOOK_RC"
check "8 days old: the session dir holding only a norm leftover and the top-level leftover are removed" "absent|absent" \
  "$(exists "$JEVDIR/jev2460-i-normold")|$(exists "$JEVDIR/norm-Old456")"
check "6 days old: the session dir and the top-level leftover are kept with their files" "present|present" \
  "$(exists "$JEVDIR/jev2460-i-normrecent/norm-AbC123/raw.txt")|$(exists "$JEVDIR/norm-New789/raw.txt")"
check "a leftover is not a dispatch: the log holds only the triggering record" "1|toolu_i_normtrigger" \
  "$(hq qa "$(np "$LOG")" 'recs.length + "|" + recs.map((x) => x.tool_use_id).join(",")')"
case_end

echo "=== a dir whose orphan was not logged is kept for the next due sweep ==="
# RET_JS seed <sid> <tid>         : one pending entry under <sid>.
# RET_JS sweep <days> <sid=mode>..: one sweepStateDirs at Date.now() + <days>; onOrphan
#   returns {ok:true} (ok), {ok:false} (fail) or throws (throw) per session.
#   Prints "<removed sids>|<sid:tid of every onOrphan call>". Moving now() forward stands
#   in for aging: no marker yet -> due, and each later sweep is a further day+ ahead.
RET_JS="$TMPROOT/retention-drive.js"
cat > "$RET_JS" <<'JS'
"use strict";
const [retPath, pendPath, mode, ...rest] = process.argv.slice(2);
const pending = require(pendPath);
if (mode === "seed") {
  pending.writePending(rest[0], rest[1], { point: "complexity-judge" });
  process.stdout.write("seeded");
} else {
  const t = Date.now() + Number(rest[0]) * 86400000;
  const modes = Object.fromEntries(rest.slice(1).map((kv) => kv.split("=")));
  const calls = [];
  const removed = require(retPath).sweepStateDirs({ now: () => t, onOrphan: (sid, tid) => {
    calls.push(sid + ":" + tid);
    if (modes[sid] === "throw") throw new Error("append failed");
    return { ok: modes[sid] === "ok" };
  } });
  process.stdout.write(removed.sort().join(",") + "|" + calls.sort().join(","));
}
JS
ret() { run_with_timeout 30 node "$(np "$RET_JS")" "$REPO_N/hooks/lib/jev/retention.js" "$REPO_N/hooks/lib/jev/pending.js" "$@" 2>/dev/null; }
# sweep_files <sid>: the -sweep claims left in <sid>'s pending dir.
sweep_files() { find "$JEVDIR/$1/pending" -name '*.claimed-*-sweep' -type f 2>/dev/null | wc -l | tr -d ' '; }

case_begin "i-orphan-not-logged-keeps-dir" "hooks/lib/jev/retention.js"
fx_new i-keep
FAIL_MODES=(fail throw)
for _m in "${FAIL_MODES[@]}"; do
  ret seed "jev2460-i-$_m" "toolu_i_$_m" > /dev/null
done
check "fixture: two sessions with one pending each" "2" "$(pending_count)"
check "8 days on: each orphan is handed over once, neither dir is removed" \
  "|jev2460-i-fail:toolu_i_fail,jev2460-i-throw:toolu_i_throw" "$(ret sweep 8 jev2460-i-fail=fail jev2460-i-throw=throw)"
for _m in "${FAIL_MODES[@]}"; do
  check "$_m: the dir is kept and its orphan stays as one -sweep file" "present|1" \
    "$(exists "$JEVDIR/jev2460-i-$_m")|$(sweep_files "jev2460-i-$_m")"
done
check "16 days on, the hand-off now succeeds: both dirs are removed, each orphan handed over once more" \
  "jev2460-i-fail,jev2460-i-throw|jev2460-i-fail:toolu_i_fail,jev2460-i-throw:toolu_i_throw" \
  "$(ret sweep 16 jev2460-i-fail=ok jev2460-i-throw=ok)"
check "both dirs are gone" "absent|absent" "$(exists "$JEVDIR/jev2460-i-fail")|$(exists "$JEVDIR/jev2460-i-throw")"
case_end

case_begin "i-orphan-logged-removes-dir-once" "hooks/lib/jev/retention.js"
fx_new i-ok
ret seed jev2460-i-ok toolu_i_ok > /dev/null
check "8 days on, the hand-off succeeds: the dir is removed after exactly one onOrphan call" \
  "jev2460-i-ok|jev2460-i-ok:toolu_i_ok" "$(ret sweep 8 jev2460-i-ok=ok)"
check "the dir is gone" "absent" "$(exists "$JEVDIR/jev2460-i-ok")"
check "a later due sweep hands nothing over again" "|" "$(ret sweep 16 jev2460-i-ok=ok)"
case_end

case_begin "i-orphan-mixed-sessions-only-logged-removed" "hooks/lib/jev/retention.js"
fx_new i-mixed
ret seed jev2460-i-a toolu_i_a > /dev/null
ret seed jev2460-i-b toolu_i_b > /dev/null
check "A fails, B succeeds: only B is removed; both were handed over once" \
  "jev2460-i-b|jev2460-i-a:toolu_i_a,jev2460-i-b:toolu_i_b" "$(ret sweep 8 jev2460-i-a=fail jev2460-i-b=ok)"
check "A is kept with its -sweep file; B is gone" "present|1|absent" \
  "$(exists "$JEVDIR/jev2460-i-a")|$(sweep_files jev2460-i-a)|$(exists "$JEVDIR/jev2460-i-b")"
case_end

# RET2_JS fresh <sid> <age-ms> <name>: one pending entry <name> under <sid>, file and dirs aged
#   to now - age; then one sweepStateDirs at the real now with a 8.64 s age floor
#   (maxAgeDays 0.0001), so a dir can be stale while its claim is younger than the pending TTL.
# RET2_JS late <sid> <none|file|pending>: a 2-hour-old pending; onOrphan writes a fresh
#   non-pending file (file) or a new pending (pending) into the dir before returning ok.
#   Both print "<removed sids>|<onOrphan tids>|<dir present?>|<pending names left>".
# RET2_JS newest: newestMtime with and without filesOnly over a 10-day-old file in fresh dirs.
RET2_JS="$TMPROOT/retention-drive2.js"
cat > "$RET2_JS" <<'JS'
"use strict";
const fs = require("fs");
const path = require("path");
const [retPath, pendPath, cmd, ...a] = process.argv.slice(2);
const retention = require(retPath);
const pending = require(pendPath);
const root = path.join(process.env.AGENTS_STATE_DIR, "jev");
const setAge = (p, ms) => { const t = (Date.now() - ms) / 1000; fs.utimesSync(p, t, t); };
function seed(sid, name, ageMs) {
  const pd = pending.pendingDir(sid);
  fs.mkdirSync(pd, { recursive: true });
  fs.writeFileSync(path.join(pd, name), JSON.stringify({ point: "complexity-judge" }));
  for (const p of [path.join(pd, name), pd, path.dirname(pd)]) setAge(p, ageMs);
}
function report(sid, removed, calls) {
  const dir = path.join(root, sid);
  let left = "";
  try { left = fs.readdirSync(pending.pendingDir(sid)).sort().join(","); } catch (_e) { left = ""; }
  return [removed.join(","), calls.join(","), fs.existsSync(dir) ? "present" : "absent", left].join("|");
}
if (cmd === "fresh") {
  const [sid, age, name] = a;
  seed(sid, name, Number(age));
  const calls = [];
  const removed = retention.sweepStateDirs({ maxAgeDays: 0.0001, onOrphan: (_s, tid) => { calls.push(tid); return { ok: true }; } });
  process.stdout.write(report(sid, removed, calls));
} else if (cmd === "late") {
  const [sid, mode] = a;
  seed(sid, "toolu_i_late.json", 7200000);
  const calls = [];
  const removed = retention.sweepStateDirs({ maxAgeDays: 0.0001, onOrphan: (_s, tid) => {
    calls.push(tid);
    if (mode === "file") fs.writeFileSync(path.join(root, sid, "late-write.json"), "{}");
    if (mode === "pending") pending.writePending(sid, "toolu_i_new", { point: "complexity-judge" });
    return { ok: true };
  } });
  process.stdout.write(report(sid, removed, calls));
} else if (cmd === "newest") {
  const d = path.join(root, "newest-probe");
  fs.mkdirSync(path.join(d, "sub"), { recursive: true });
  fs.mkdirSync(path.join(d, "empty"), { recursive: true });
  fs.writeFileSync(path.join(d, "sub", "f.json"), "{}");
  setAge(path.join(d, "sub", "f.json"), 10 * 86400000);
  const now = Date.now();
  const all = retention.newestMtime(d);
  const files = retention.newestMtime(d, true);
  process.stdout.write([now - all < 600000, Math.abs(now - files - 10 * 86400000) < 600000,
    retention.newestMtime(path.join(d, "empty"), true), retention.newestMtime(path.join(d, "no-such"), true)].join("|"));
}
JS
ret2() { run_with_timeout 30 node "$(np "$RET2_JS")" "$REPO_N/hooks/lib/jev/retention.js" "$REPO_N/hooks/lib/jev/pending.js" "$@" 2>/dev/null; }

echo "=== retention leaves a claim younger than the pending TTL to its owner ==="
case_begin "i-fresh-sweep-claim-not-stolen" "hooks/lib/jev/retention.js"
for _row in "sweep|toolu_i_fs.claimed-4242-sweep" "claim|toolu_i_fc.claimed-4242"; do
  _tag="${_row%%|*}"; _name="${_row#*|}"; _tid="${_name%%.claimed-*}"
  fx_new "i-fresh-$_tag"
  check "$_tag: 30-minute-old claim in a stale dir: not handed over, kept in place, dir kept" "||present|$_name" \
    "$(ret2 fresh "jev2460-i-fresh-$_tag" 1800000 "$_name")"
  fx_new "i-old-$_tag"
  check "$_tag control: 2-hour-old claim: handed over once, dir removed" "jev2460-i-old-$_tag|$_tid|absent|" \
    "$(ret2 fresh "jev2460-i-old-$_tag" 7200000 "$_name")"
done
case_end

echo "=== the dir is re-checked right before removal ==="
case_begin "i-late-write-keeps-dir" "hooks/lib/jev/retention.js"
fx_new i-late-none
check "control: nothing written during the sweep: dir removed (dir mtimes the sweep refreshed are ignored)" \
  "jev2460-i-late-none|toolu_i_late|absent|" "$(ret2 late jev2460-i-late-none none)"
fx_new i-late-file
check "a fresh non-pending file written during the sweep: dir kept" \
  "|toolu_i_late|present|" "$(ret2 late jev2460-i-late-file file)"
fx_new i-late-pending
check "a new pending written during the sweep: dir kept with that pending" \
  "|toolu_i_late|present|toolu_i_new.json" "$(ret2 late jev2460-i-late-pending pending)"
case_end

case_begin "i-newest-mtime-files-only" "hooks/lib/jev/retention.js"
fx_new i-newest
check "dir mtimes count by default; filesOnly sees only the 10-day-old file; empty or missing dir is 0" \
  "true|true|0|0" "$(ret2 newest)"
case_end

# rp race <sid> <mode> | rp tombs: tests/hooks/feature-2460-jev-shadow/retention-probe.js.
rp() { run_with_timeout 30 node "$(np "$LIBDIR/retention-probe.js")" "$REPO_N/hooks/lib/jev/retention.js" "$REPO_N/hooks/lib/jev/pending.js" "$@" 2>/dev/null; }

echo "=== removal goes through a tombstone, so a concurrent writer loses nothing ==="
case_begin "i-removal-via-tombstone-stale-empty" "hooks/lib/jev/retention.js"
fx_new i-tomb-none
check "a stale empty dir is removed and reported; beforeRemove ran on a .tomb-<sid>-<digits> dir with the original path already gone; no tombstone left" \
  "jev2460-i-rn|true,true,true|absent||0|" "$(rp race jev2460-i-rn none)"
case_end
case_begin "i-concurrent-writer-live-path-kept" "hooks/lib/jev/retention.js"
fx_new i-tomb-live
check "a pending written into the recreated original path survives; the sid is not reported removed; the tombstone is gone" \
  "|true,true,true|present|toolu_i_live.json|0|" "$(rp race jev2460-i-rl live)"
fx_new i-tomb-both
check "a pending in the tombstone is merged into the new live dir beside the writer's pending; nothing lost, tombstone gone" \
  "|true,true,true|present|toolu_i_live.json,toolu_i_tomb.json|0|" "$(rp race jev2460-i-rb both)"
fx_new i-tomb-conflict
check "same-name pending in both: the live one is not overwritten, the tombstone is kept holding its copy" \
  "|true,true,true|present|toolu_i_x.json|1|LIVE/TOMB" "$(rp race jev2460-i-rc conflict)"
case_end
case_begin "i-late-writer-into-tombstone-restores-dir" "hooks/lib/jev/retention.js"
fx_new i-tomb-tomb
check "a fresh pending written into the tombstone: the dir is restored to its original path with it, not removed" \
  "|true,true,true|present|toolu_i_tomb.json|0|" "$(rp race jev2460-i-rt tomb)"
fx_new i-tomb-file
check "a fresh non-pending file written into the tombstone: the dir is restored with the file, not removed" \
  "|true,true,true|present||0|file-kept" "$(rp race jev2460-i-rf tomb-file)"
case_end

echo "=== leftover .tomb-* dirs: entry-free stale ones cleaned, ones holding entries restored ==="
case_begin "i-leftover-tombstones-cleaned" "hooks/lib/jev/retention.js"
fx_new i-tombs
check "10-day-old entry-free tombstone cleaned, 1 day old kept; a pending or unlogged entry is never deleted but restored to <sid>; none reported removed" \
  "|.tomb-ccc-789|toolu_k.json|toolu_k.unlogged-1-2" "$(rp tombs)"
case_end
case_begin "i-leftover-tomb-restored-then-swept" "hooks/lib/jev/retention.js"
fx_new i-tomb-restore
check "a stale tomb of a dashed sid with an unlogged entry: restored to <sid>/pending, tomb gone, nothing handed over yet" \
  "||toolu_r.unlogged-1-2|false" "$(rp tomb-restore jev2460-tr-42 | cut -d'|' -f1-4)"
fx_new i-tomb-restore2
check "the next due sweep hands the restored orphan to onOrphan once and removes the dir" \
  "jev2460-tr-43|jev2460-tr-43:toolu_r" "$(rp tomb-restore jev2460-tr-43 | cut -d'|' -f5-6)"
case_end
case_begin "i-leftover-tomb-merged-into-live" "hooks/lib/jev/retention.js"
fx_new i-tomb-merge
check "a live dir exists: the free name is merged in, the same-name live file is not overwritten, the tomb is kept with the conflict" \
  "toolu_m_x.json,toolu_m_y.json|LIVE|true|toolu_m_x.json" "$(rp tomb-merge jev2460-tm)"
case_end
case_begin "i-leftover-tomb-invalid-sid-untouched" "hooks/lib/jev/retention.js"
fx_new i-tomb-invalid
check "tombs whose sid part is invalid (a..b, empty) or that lack a -<digits> suffix: left untouched with their entries" \
  ".tomb--456,.tomb-a..b-123,.tomb-nodigits||toolu_v.json,toolu_v.json,toolu_v.json" "$(rp tomb-invalid)"
case_end

finish
