#!/usr/bin/env bash
# tests/feature-1733-state-event-stream/cleanup-stale.sh
# Tests: hooks/workflow-state/state-io/zombie-cleanup.js, hooks/workflow-state/state-io/state-lock.js, hooks/workflow-state/state-io/core.js
# Tags: workflow-state, event-stream, zombie-cleanup, stale-lock, tmp-leftovers, scope:issue-specific, pwsh-not-required, TL2
#
# The sweep that keeps ~/.claude/workflow from growing forever decided "is this session
# still alive?" from `created_at` + `steps[*].updated_at`. #1733 deletes `steps` from the
# file, so an unchanged sweep reads a long-running session as untouched-since-creation and
# DELETES IT — a live workflow losing its state mid-session, which no assertion elsewhere
# in this suite would notice. Hence Z1: old created_at + recent events must SURVIVE.
#
# The same sweep gains two new kinds of debris, both created by #1733 and both left behind
# when a writer is killed: `<sid>.json.lock` and the unique `<sid>.json.<pid>.<n>.tmp`.
# Reclaiming those is only safe if it is age-based — a sweep that deletes a FRESH lock or
# another process's in-flight tmp corrupts the very write it was meant to tidy up after.
#
# Z7/Z8 pin the blast radius of ONE bad file. This sweep runs on EVERY SessionStart over
# the WHOLE workflow dir, so an uncaught JSON.parse (a truncated file left by a killed
# writer, a zero-byte file, a stray `.txt`/`.bak`, a subdirectory) does not merely skip
# that entry — it aborts the sweep for every other session in the directory, and the
# symptom is a workflow dir that silently stops being reclaimed. Per-entry containment is
# therefore asserted directly: the bad entry must neither crash the sweep nor be rewritten,
# while the valid stale/fresh files around it are still judged correctly.
#
# TL3 gap (what this file does NOT catch):
# - the real SessionStart invocation (`cleanupZombies(7)` in hooks/session-start.js).
# - a genuinely killed writer: the debris is fabricated with fs + utimes rather than by
#   SIGKILLing a node process mid-write.
# Closest-to-action mitigation: hook-registration category in bin/check-verification-gate.sh.

CASE_TAG="clean"
# shellcheck source=tests/feature-1733-state-event-stream/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Fixture builders shared by every case. Ages are expressed in days from now so the
# assertions read the same way the cutoff does.
CLEAN_JS='const os = require("os");
const WF = process.env.CLAUDE_WORKFLOW_DIR;
const DAY = 24 * 60 * 60 * 1000;
const ago = (days) => new Date(Date.now() - days * DAY).toISOString();
const agoMs = (days) => Date.now() - days * DAY;
const P = (name) => path.join(WF, name);
const put = (name, content, ageDays) => {
  const p = P(name);
  fs.writeFileSync(p, typeof content === "string" ? content : JSON.stringify(content, null, 2));
  if (ageDays) { const t = agoMs(ageDays) / 1000; fs.utimesSync(p, t, t); }
  return p;
};
const exists = (name) => fs.existsSync(P(name));
const v2 = (id, createdDays, eventDays) => ({
  version: 2,
  session_id: id,
  created_at: ago(createdDays),
  events: eventDays === null ? [] : [{
    seq: 1, at: ago(eventDays), kind: "step_status", step: "run_tests",
    status: "in_progress", provenance: "observed", origin: "mark-step",
  }],
  current: { steps: {} },
});
const sweep = (days) => S.cleanupZombies(days === undefined ? 7 : days);
'

echo "== Z1: an old session with RECENT events is still active and must survive the sweep =="
if run_case "Z1/recent-events-keep-old-session"; then
    next_sid
    nodejs "$SID" "$PRE$CLEAN_JS"'
// created 30 days ago, last event 1 hour ago: a long-running session, not a zombie.
put("z1-active.json", v2("z1-active", 30, 1 / 24));
sweep(7);
console.log("survived=" + exists("z1-active.json"));
'
    assert_eq "Z1/recent-events-keep-old-session" "survived=true" "$NODE_OUT"
fi

echo "== Z2: a session whose newest event is older than the cutoff is removed =="
if run_case "Z2/genuinely-stale-removed"; then
    next_sid
    nodejs "$SID" "$PRE$CLEAN_JS"'
put("z2-stale.json", v2("z2-stale", 30, 20));
put("z2-empty.json", v2("z2-empty", 30, null));   // no events at all: created_at decides
put("z2-fresh.json", v2("z2-fresh", 30, 0.5));
sweep(7);
console.log([
  "stale=" + exists("z2-stale.json"),
  "empty=" + exists("z2-empty.json"),
  "fresh=" + exists("z2-fresh.json"),
].join(" "));
'
    assert_eq "Z2/genuinely-stale-removed" "stale=false empty=false fresh=true" "$NODE_OUT"
fi

echo "== Z3: a not-yet-migrated v1 file is still judged by its own timestamps =="
if run_case "Z3/v1-file-still-judged-correctly"; then
    next_sid
    nodejs "$SID" "$PRE$CLEAN_JS"'
// The sweep runs before anything migrates these files, so it must keep understanding v1.
put("z3-v1-active.json", { version: 1, session_id: "z3a", created_at: ago(30),
  steps: { run_tests: { status: "in_progress", updated_at: ago(0.5) } } });
put("z3-v1-stale.json", { version: 1, session_id: "z3s", created_at: ago(30),
  steps: { run_tests: { status: "complete", updated_at: ago(25) } } });
sweep(7);
console.log("active=" + exists("z3-v1-active.json") + " stale=" + exists("z3-v1-stale.json"));
'
    assert_eq "Z3/v1-file-still-judged-correctly" "active=true stale=false" "$NODE_OUT"
fi

echo "== Z4: a stale lock is reclaimed, a fresh lock is left strictly alone =="
if run_case "Z4/lock-reclaim-is-age-based"; then
    next_sid
    nodejs "$SID" "$PRE$CLEAN_JS"'
const dead = { pid: 999999, host: os.hostname(), at: ago(10) };
const live = { pid: process.pid, host: os.hostname(), at: ago(0) };
put("z4-dead.json", v2("z4-dead", 1, 0.1));
put("z4-live.json", v2("z4-live", 1, 0.1));
put("z4-dead.json.lock", JSON.stringify(dead), 10);
put("z4-live.json.lock", JSON.stringify(live), 0);
// A lock whose payload never parsed is the worst debris of all: nothing can reclaim it
// by pid, so age is the only handle left.
put("z4-garbage.json.lock", "{not json", 10);
sweep(7);
console.log([
  "dead_lock=" + exists("z4-dead.json.lock"),
  "live_lock=" + exists("z4-live.json.lock"),
  "garbage_lock=" + exists("z4-garbage.json.lock"),
  "states_intact=" + (exists("z4-dead.json") && exists("z4-live.json")),
].join(" "));
'
    assert_eq "Z4/lock-reclaim-is-age-based" \
        "dead_lock=false live_lock=true garbage_lock=false states_intact=true" "$NODE_OUT"
fi

echo "== Z5: unique per-write tmp leftovers are swept without touching an in-flight one =="
if run_case "Z5/tmp-leftovers"; then
    next_sid
    nodejs "$SID" "$PRE$CLEAN_JS"'
// The tmp name carries the writer pid precisely so two concurrent writers cannot collide;
// the sweep must respect that boundary and delete only by age, never by "not my pid".
put("z5.json", v2("z5", 1, 0.1));
put("z5.json.4242.1.tmp", "{}", 10);
put("z5.json.4242.2.tmp", "{}", 10);
put("z5.json." + process.pid + ".7.tmp", "{}", 0);
sweep(7);
console.log([
  "old1=" + exists("z5.json.4242.1.tmp"),
  "old2=" + exists("z5.json.4242.2.tmp"),
  "inflight=" + exists("z5.json." + process.pid + ".7.tmp"),
  "state=" + exists("z5.json"),
].join(" "));
'
    assert_eq "Z5/tmp-leftovers" "old1=false old2=false inflight=true state=true" "$NODE_OUT"
fi

echo "== Z6: a live lock still blocks a competing writer after the sweep has run =="
if run_case "Z6/sweep-does-not-break-live-locking"; then
    next_sid
    # Deleting a live lock would not show up as a missing FILE — it shows up as two
    # writers entering the critical section at once. This case asserts the lock the sweep
    # spared is still enforcing.
    nodejs "$SID" "$PRE$CLEAN_JS"'
const L = require("./hooks/workflow-state/state-io/state-lock");
S.markStep(sid, "workflow_init", "complete");
let held = "-", blocked = "-";
L.withStateLock(sid, () => {
  held = fs.existsSync(sp() + ".lock") ? "yes" : "no";
  sweep(7);
  held = held + "/" + (fs.existsSync(sp() + ".lock") ? "yes" : "no");
  // Re-entrant by design (appendEvents nests inside writeState), so the inner acquire
  // must succeed rather than deadlock.
  try { L.withStateLock(sid, () => 1); blocked = "reentrant-ok"; }
  catch (e) { blocked = "reentrant-threw:" + e.name; }
});
const after = fs.existsSync(sp() + ".lock");
console.log("held=" + held + " " + blocked + " released=" + !after);
'
    assert_eq "Z6/sweep-does-not-break-live-locking" "held=yes/yes reentrant-ok released=true" "$NODE_OUT"
fi

echo "== Z7: a corrupt state file cannot abort the sweep of every other session =="
if run_case "Z7/corrupt-file-does-not-abort-sweep"; then
    next_sid
    nodejs "$SID" "$PRE$CLEAN_JS"'
// Names are chosen so the corrupt entries sort BOTH before and after the valid ones:
// readdir order must not decide whether the rest of the directory gets swept.
const CORRUPT = ["z7-aaa-truncated.json", "z7-bbb-empty.json", "z7-zzz-garbage.json"];
put("z7-aaa-truncated.json", "{ \"version\": 2, \"session_id\": \"z7a\", \"events\": [ { \"seq\": 1,", 10);
put("z7-bbb-empty.json", "", 10);                       // zero bytes: JSON.parse("") throws too
put("z7-zzz-garbage.json", "<<< not json at all >>>", 10);
put("z7-mmm-stale.json", v2("z7-mmm-stale", 30, 20));   // genuinely stale -> must be removed
put("z7-nnn-fresh.json", v2("z7-nnn-fresh", 30, 0.5));  // active         -> must survive
const before = {};
CORRUPT.forEach((n) => { before[n] = fs.readFileSync(P(n), "utf8"); });
let threw = "none";
try { sweep(7); } catch (e) { threw = (e && e.name) || "Error"; }
// Removing an unreadable file is a legitimate policy; REWRITING one is not — those bytes
// are the only evidence left of whatever the killed writer was doing.
const mangled = CORRUPT.filter((n) => exists(n) && fs.readFileSync(P(n), "utf8") !== before[n]);
console.log([
  "threw=" + threw,
  "stale=" + exists("z7-mmm-stale.json"),
  "fresh=" + exists("z7-nnn-fresh.json"),
  "mangled=" + (mangled.join(",") || "0"),
].join(" "));
'
    assert_eq "Z7/corrupt-file-does-not-abort-sweep" \
        "threw=none stale=false fresh=true mangled=0" "$NODE_OUT"
fi

echo "== Z8: non-state entries in the workflow dir are not mistaken for sessions =="
if run_case "Z8/non-state-entries-ignored"; then
    next_sid
    nodejs "$SID" "$PRE$CLEAN_JS"'
// The workflow dir is shared: supervisor markers, session-scoped sentinel files, editor
// backups and the odd scratch file all live here. The sweep owns `<sid>.json` (plus its
// own `.lock` / `.tmp` debris) and nothing else.
fs.mkdirSync(P("z8-subdir"), { recursive: true });
put("z8-subdir/inner.json", v2("z8-inner", 30, 20));   // stale-shaped, but not a session file
put("z8-notes.txt", "scratch", 10);
put("z8-state.json.bak", JSON.stringify(v2("z8-bak", 30, 20)), 10);
put("z8-no-extension", "stray", 10);
put("z8-live.json", v2("z8-live", 1, 0.1));
put("z8-live.json.lock", JSON.stringify({ pid: process.pid, host: os.hostname(), at: ago(0) }), 0);
put("z8-stale.json", v2("z8-stale", 30, 20));
put("z8-fresh.json", v2("z8-fresh", 30, 0.5));
let threw = "none";
try { sweep(7); } catch (e) { threw = (e && e.name) || "Error"; }
console.log([
  "threw=" + threw,
  "notes=" + exists("z8-notes.txt"),
  "bak=" + exists("z8-state.json.bak"),
  "stray=" + exists("z8-no-extension"),
  "subdir_inner=" + exists("z8-subdir/inner.json"),
  "fresh_lock=" + exists("z8-live.json.lock"),
  "stale=" + exists("z8-stale.json"),
  "fresh=" + exists("z8-fresh.json"),
].join(" "));
'
    assert_eq "Z8/non-state-entries-ignored" \
        "threw=none notes=true bak=true stray=true subdir_inner=true fresh_lock=true stale=false fresh=true" \
        "$NODE_OUT"
fi

feature_banner
finish "cleanup-stale"
