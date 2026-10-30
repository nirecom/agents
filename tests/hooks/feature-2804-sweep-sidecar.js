#!/usr/bin/env node
// tests/hooks/feature-2804-sweep-sidecar.js
// Tests: hooks/workflow-state/state-io/zombie-cleanup.js
// Tags: TL2, hooks, workflow-state, zombie-cleanup, presentation-receipt, sidecar, scope:issue-specific, pwsh-not-required
// #2804 Step 1: the sweep judges `<sid>.json` (stem matches SESSION_ID_VALID_RE) as state by its
// activity time, and every other `*.json` as a sidecar it never reads: kept while `<owner>.json`
// exists, else removed only after CONTROL_RETENTION_DAYS (30) of mtime. Before #2804 a receipt
// (no created_at / events) was age 0 and removed by the next SessionStart of any session.
// TL3 gap: the real SessionStart call (hooks/session-start.js cleanupZombies(7)); the debris here is
// fabricated with fs + utimes. Mitigation: bin/check-verification-gate.sh category hook-registration.
"use strict";

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test } = require("node:test");
const fs = require("fs");
const os = require("os");
const path = require("path");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2804s-"));
process.chdir(SCRATCH);
process.on("exit", () => {
  process.chdir(os.tmpdir());
  restore();
  fs.rmSync(SCRATCH, { recursive: true, force: true });
});

const WF = process.env.WORKFLOW_STATE_DIR;
const ZC = require("../../hooks/workflow-state/state-io/zombie-cleanup");

const show = (x) => { try { return JSON.stringify(x); } catch (_) { return String(x); } };
// check(name, ok, detail) — one node:test test over a verdict computed now (the cases mutate the
// shared state root in order, so nothing is evaluated lazily inside the test body).
function check(name, ok, detail) {
  const why = typeof detail === "string" ? detail : show(detail);
  test(name, () => { if (!ok) assert.fail(why); });
}

const DAY = 24 * 60 * 60 * 1000;
const ago = (days) => new Date(Date.now() - days * DAY).toISOString();
const P = (name) => path.join(WF, name);
const touch = (name, ageDays) => { const t = (Date.now() - ageDays * DAY) / 1000; fs.utimesSync(P(name), t, t); };
// put(name, body, mtimeAgeDays) -> writes the file; a non-zero age back-dates its mtime.
function put(name, body, ageDays) {
  fs.writeFileSync(P(name), typeof body === "string" ? body : JSON.stringify(body, null, 2));
  if (ageDays) touch(name, ageDays);
}
const exists = (name) => fs.existsSync(P(name));
const v2 = (id, createdDays, eventDays) => ({
  version: 2, session_id: id, created_at: ago(createdDays),
  events: [{ seq: 1, at: ago(eventDays), kind: "step_status", step: "run_tests", status: "in_progress", provenance: "observed", origin: "test-fixture" }],
  current: { steps: {} },
});
const receiptBody = () => ({
  absPath: path.join(SCRATCH, "plan.md"), link: { kind: "url", value: "https://example.invalid/test-owner/test-repo/blob/main/plan.md" },
  contentSha: "a".repeat(64), anchorUuid: "a-anchor", writtenAt: ago(40),
});
const CURSOR_BODY = { plansDir: path.join(SCRATCH, "plans"), plansDirMtimeMs: Date.now() - DAY, scannedAt: ago(1), complete: true, retryAfter: null, failed: [] };
// sweep() -> null when cleanupZombies(7) returned, else the thrown message.
function sweep() {
  try { ZC.cleanupZombies(7); return null; } catch (e) { return String(e && e.message); }
}

caseBegin("z9-real-zombie-state-removed", "hooks/workflow-state/state-io/zombie-cleanup.js");
{
  put("z9-owner.json", v2("z9-owner", 30, 20));
  put("z9-fresh.json", v2("z9-fresh", 30, 0.5));
  const threw = sweep();
  check("Z9: the sweep does not throw", threw === null, threw);
  check("Z9: a state whose newest activity is 20 days old is removed", !exists("z9-owner.json"), "z9-owner.json still exists");
  check("Z9: a state active 12 hours ago is kept", exists("z9-fresh.json"), "z9-fresh.json removed");
}
caseEnd();

caseBegin("z10-live-owner-sidecar-kept", "hooks/workflow-state/state-io/zombie-cleanup.js");
{
  put("z10-live.json", v2("z10-live", 1, 0.1));
  put("z10-live.confirm-plan-receipt-detail.json", receiptBody(), 40);
  sweep();
  check("Z10: a 40-day-old receipt sidecar of a live owner is kept", exists("z10-live.confirm-plan-receipt-detail.json"), "receipt sidecar removed");
  check("Z10: the live owner state is kept", exists("z10-live.json"), "owner state removed");
}
caseEnd();

caseBegin("z11-orphan-sidecar-mtime-rule", "hooks/workflow-state/state-io/zombie-cleanup.js");
{
  put("z11-gone.confirm-plan-receipt-intent.json", receiptBody(), 40);
  put("z11-gone.confirm-plan-receipt-outline.json", receiptBody(), 1);
  sweep();
  check("Z11: an orphan sidecar (no z11-gone.json) with mtime 40 days is removed", !exists("z11-gone.confirm-plan-receipt-intent.json"), "40-day orphan kept");
  check("Z11: an orphan sidecar with mtime 1 day is kept (not reaped at age 0)", exists("z11-gone.confirm-plan-receipt-outline.json"), "1-day orphan removed");
}
caseEnd();

caseBegin("z11b-orphan-sidecar-retention-boundary", "hooks/workflow-state/state-io/zombie-cleanup.js");
{
  // The rule is mtime < Date.now() - 30 days at sweep time; one hour each side keeps it free of clock jitter.
  const HOUR = 1 / 24;
  put("z18-gone.confirm-plan-receipt-intent.json", receiptBody(), 30 - HOUR);
  put("z18-gone.confirm-plan-receipt-outline.json", receiptBody(), 30 + HOUR);
  const threw = sweep();
  check("Z11b: the sweep does not throw", threw === null, threw);
  check("Z11b: an orphan sidecar with mtime 30 days minus 1 hour is kept", exists("z18-gone.confirm-plan-receipt-intent.json"), "30d-1h orphan removed");
  check("Z11b: an orphan sidecar with mtime 30 days plus 1 hour is removed", !exists("z18-gone.confirm-plan-receipt-outline.json"), "30d+1h orphan kept");
}
caseEnd();

caseBegin("z12-sidecar-with-state-keys-stays-sidecar", "hooks/workflow-state/state-io/zombie-cleanup.js");
{
  put("z12-live.json", v2("z12-live", 1, 0.1));
  put("z12-live.x.json", v2("z12-live", 30, 20));
  sweep();
  check("Z12: a sidecar whose body is an old state is judged as a sidecar of a live owner and kept", exists("z12-live.x.json"), "z12-live.x.json removed");
}
caseEnd();

caseBegin("z13-state-judged-by-name", "hooks/workflow-state/state-io/zombie-cleanup.js");
{
  put("20261027-101500.json", v2("20261027-101500", 30, 20));
  put("a.json", v2("a", 1, 0.1));
  put("a.b.json", { note: "dotted stem" }, 40);
  sweep();
  check("Z13: a YYYYMMDD-HHMMSS state stem with old activity is removed as state", !exists("20261027-101500.json"), "20261027-101500.json kept");
  check("Z13: a.b.json (40-day mtime) is a sidecar of a and kept while a.json exists", exists("a.b.json"), "a.b.json removed while a.json exists");
  fs.rmSync(P("a.json"), { force: true });
  if (!exists("a.b.json")) put("a.b.json", { note: "dotted stem" });
  touch("a.b.json", 1);
  sweep();
  check("Z13: without a.json, a.b.json with mtime 1 day is kept", exists("a.b.json"), "a.b.json removed at 1 day");
  if (!exists("a.b.json")) put("a.b.json", { note: "dotted stem" });
  touch("a.b.json", 40);
  sweep();
  check("Z13: without a.json, a.b.json with mtime 40 days is removed", !exists("a.b.json"), "a.b.json kept at 40 days");
}
caseEnd();

caseBegin("z14-ownerless-non-state-json", "hooks/workflow-state/state-io/zombie-cleanup.js");
{
  put(".control-migration-cursor.json", CURSOR_BODY, 1);
  sweep();
  check("Z14: the migration cursor with mtime 1 day is kept (not reaped at age 0)", exists(".control-migration-cursor.json"), "cursor removed at 1 day");
  if (!exists(".control-migration-cursor.json")) put(".control-migration-cursor.json", CURSOR_BODY);
  touch(".control-migration-cursor.json", 40);
  sweep();
  check("Z14: the migration cursor with mtime 40 days is removed", !exists(".control-migration-cursor.json"), "cursor kept at 40 days");
}
caseEnd();

caseBegin("sidecar-body-never-read", "hooks/workflow-state/state-io/zombie-cleanup.js");
{
  put("z15-live.json", v2("z15-live", 1, 0.1));
  put("z15-live.corrupt.json", "{ not json", 40);
  put("z15-gone.corrupt.json", "{ not json", 40);
  const threw = sweep();
  check("sidecar: a corrupt sidecar does not abort the sweep", threw === null, threw);
  check("sidecar: a corrupt 40-day sidecar of a live owner is kept", exists("z15-live.corrupt.json"), "removed");
  check("sidecar: a corrupt 40-day orphan sidecar is removed by mtime", !exists("z15-gone.corrupt.json"), "kept");
}
caseEnd();

caseBegin("state-without-activity-time", "hooks/workflow-state/state-io/zombie-cleanup.js");
{
  // A `<sid>.json` is state by name: lastActivityMs() is 0 when no created_at / events[].at parses,
  // so a parseable state with no activity time is reclaimed at once (mtime is never consulted).
  // An unparseable `<sid>.json` throws in JSON.parse and is skipped, i.e. kept, without stopping the sweep.
  put("z17-recent.json", v2("z17-recent", 1, 0.1));
  put("z17-empty.json", {});
  put("z17-badtime.json", { version: 2, session_id: "z17-badtime", created_at: "not a date", events: [{ seq: 1, at: "never" }] });
  put("z17-corrupt.json", "{ not json");
  const threw = sweep();
  check("no-activity: the sweep does not throw", threw === null, threw);
  check("no-activity: a state with no created_at / events (fresh mtime) is reclaimed", !exists("z17-empty.json"), "z17-empty.json kept");
  check("no-activity: a state whose times do not parse (fresh mtime) is reclaimed", !exists("z17-badtime.json"), "z17-badtime.json kept");
  check("no-activity: an unparseable state is skipped and kept", exists("z17-corrupt.json"), "z17-corrupt.json removed");
  check("no-activity: a recent valid sibling state is kept in the same run", exists("z17-recent.json"), "z17-recent.json removed");
}
caseEnd();

caseBegin("sweep-idempotent","hooks/workflow-state/state-io/zombie-cleanup.js");
{
  const NAMES = ["z16-live.json", "z16-live.confirm-plan-receipt-outline.json", "z16-gone.confirm-plan-receipt-outline.json"];
  put("z16-live.json", v2("z16-live", 1, 0.1));
  put("z16-live.confirm-plan-receipt-outline.json", receiptBody(), 40);
  put("z16-gone.confirm-plan-receipt-outline.json", receiptBody(), 40);
  const first = sweep();
  const a = NAMES.map(exists);
  const second = sweep();
  const b = NAMES.map(exists);
  check("idempotent: two sweeps in a row do not throw", first === null && second === null, show([first, second]));
  check("idempotent: the second sweep leaves the same entries as the first", show(a) === show(b), show({ a, b }));
  check("idempotent: live owner and its sidecar kept, orphan removed", show(b) === show([true, true, false]), show(b));
}
caseEnd();
