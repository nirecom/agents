#!/usr/bin/env node
"use strict";
// Tests: bin/workflow/handoff-append
// Tags: handoff, origin, security, regression-2652, state-handoff-record, scope:issue-specific, pwsh-not-required, TL1
// #2652 security review C2: a model calling the CLI must not forge an "observed" machine record.
// The CLI accepts only --origin procedure-point (provenance "declared"); gate-block and auto-record
// are hook-only origins written through write.js directly, so the CLI refuses them with exit 2.
// TDD: cases cli-refuses-hook-only-*, no-cli-path-writes-observed and help-lists-only-procedure-point
// are expected red until /write-code narrows the CLI's accepted origins.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test } = require("node:test");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "handoff-append-origins-"));
for (const d of ["home", "transcripts"]) fs.mkdirSync(path.join(TMP, d));
process.env.HOME = path.join(TMP, "home");
process.env.USERPROFILE = path.join(TMP, "home");
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
process.chdir(TMP);
process.on("exit", () => {
  process.chdir(os.tmpdir());
  restore();
  fs.rmSync(TMP, { recursive: true, force: true });
});

const fx = require("../lib/state-handoff-record-fixture");
const CLI = path.join(fx.REPO, "bin", "workflow", "handoff-append");
const S = require(path.join(fx.REPO, "hooks", "workflow-state", "state-io"));
const HOOK_ONLY = ["gate-block", "auto-record"];

// cli(args) — one CLI run; {rc, out, err}.
function cli(args) {
  const r = spawnSync(process.execPath, [CLI, ...args], { encoding: "utf8", timeout: 60000 });
  return { rc: r.status, out: String(r.stdout || ""), err: String(r.stderr || "") };
}
function append(sid, key, origin) {
  return cli(["--session", sid, "--class", "D", "--step", "-", "--key", key, "--summary", "s", "--pointer", "-", "--origin", origin]);
}
// records(sid, key) — the state handoff records in the sid's state file, optionally narrowed to one key.
function records(sid, key) {
  if (!fs.existsSync(fx.statePath(sid))) return [];
  const ev = (S.readRawState(sid) || {}).events || [];
  return ev.filter((e) => e && e.kind === "state_handoff_record" && (!key || e.record_key === key));
}

caseBegin("cli-procedure-point-is-declared", "bin/workflow/handoff-append");
{
  const sid = "h2652-pp";
  fx.makeState(sid);
  const r = append(sid, "k-pp", "procedure-point");
  const recs = records(sid, "k-pp");
  test("C1: --origin procedure-point exits 0 and reports WRITTEN=1", () => {
    assert.strictEqual(r.rc, 0, r.err);
    assert.match(r.out, /WRITTEN=1/);
  });
  test("C1: it lands as exactly one state handoff record with origin procedure-point and provenance declared", () => {
    assert.deepStrictEqual(recs.map((e) => [e.origin, e.provenance, e.cls]), [["procedure-point", "declared", "D"]]);
  });
}
caseEnd();

caseBegin("cli-refuses-hook-only-gate-block", "bin/workflow/handoff-append");
{
  const sid = "h2652-gate";
  fx.makeState(sid);
  const r = append(sid, "k-gate", "gate-block");
  const recs = records(sid, "k-gate");
  test("C2: --origin gate-block exits 2", () => assert.strictEqual(r.rc, 2, r.out + r.err));
  test("C2: stderr calls gate-block hook-only and names procedure-point", () => {
    assert.match(r.err, /hook-only/);
    assert.match(r.err, /procedure-point/);
  });
  test("C2: no WRITTEN=1 and no state handoff record", () => {
    assert.doesNotMatch(r.out, /WRITTEN=1/);
    assert.deepStrictEqual(recs, []);
  });
}
caseEnd();

caseBegin("cli-refuses-hook-only-auto-record", "bin/workflow/handoff-append");
{
  const sid = "h2652-auto";
  fx.makeState(sid);
  const r = append(sid, "k-auto", "auto-record");
  const recs = records(sid, "k-auto");
  test("C3: --origin auto-record exits 2", () => assert.strictEqual(r.rc, 2, r.out + r.err));
  test("C3: stderr calls auto-record hook-only and names procedure-point", () => {
    assert.match(r.err, /hook-only/);
    assert.match(r.err, /procedure-point/);
  });
  test("C3: no WRITTEN=1 and no state handoff record", () => {
    assert.doesNotMatch(r.out, /WRITTEN=1/);
    assert.deepStrictEqual(recs, []);
  });
}
caseEnd();

caseBegin("no-cli-path-writes-observed", "bin/workflow/handoff-append");
{
  const sid = "h2652-every-origin";
  fx.makeState(sid);
  for (const o of ["procedure-point", ...HOOK_ONLY, "step-end", "flush"]) append(sid, `k-${o}`, o);
  const recs = records(sid);
  test("C4: after every origin value is tried, no state handoff record carries provenance observed", () => {
    assert.deepStrictEqual(recs.filter((e) => e.provenance === "observed").map((e) => e.origin), []);
  });
  test("C4: the procedure-point attempt still landed (non-vacuity)", () => {
    assert.deepStrictEqual(recs.map((e) => e.origin), ["procedure-point"]);
  });
}
caseEnd();

caseBegin("help-lists-only-procedure-point", "bin/workflow/handoff-append");
{
  const r = cli(["--help"]);
  const line = r.out.split(/\r?\n/).find((l) => /--origin <origin>.*one of:/.test(l)) || "";
  test("C5: --help has an --origin line naming procedure-point", () => {
    assert.strictEqual(r.rc, 0);
    assert.match(line, /procedure-point/);
  });
  test("C5: the --origin line names neither gate-block nor auto-record", () => {
    assert.doesNotMatch(line, /gate-block|auto-record/);
  });
}
caseEnd();

caseBegin("unknown-or-missing-origin-refused", "bin/workflow/handoff-append");
{
  const sid = "h2652-bad-origin";
  fx.makeState(sid);
  const unknown = append(sid, "k-unknown", "observed");
  const missing = cli(["--session", sid, "--class", "D", "--step", "-", "--key", "k-missing", "--summary", "s", "--pointer", "-"]);
  const recs = records(sid);
  test("C6: --origin observed exits 2", () => assert.strictEqual(unknown.rc, 2, unknown.out + unknown.err));
  test("C6: a missing --origin exits 2", () => assert.strictEqual(missing.rc, 2, missing.out + missing.err));
  test("C6: neither writes a record or reports WRITTEN=1", () => {
    assert.deepStrictEqual(recs, []);
    assert.doesNotMatch(unknown.out + missing.out, /WRITTEN=1/);
  });
}
caseEnd();

caseBegin("cli-overflow-record-is-declared", "bin/workflow/handoff-append");
{
  // OV-CLI: the budget is pre-filled with raw declared records just short of 64KB, so the one
  // CLI call is the record that overflows it; the overflow record must follow procedure-point -> declared.
  const sid = "h2652-overflow";
  fx.makeState(sid);
  const at = fx.isoAt(0);
  const bytes = (ev) => Buffer.byteLength(JSON.stringify(Object.assign({}, ev, { seq: 1000000000 })), "utf8");
  const fill = [];
  let used = 0;
  for (let i = 0; ; i += 1) {
    const ev = fx.record({ cls: "D", at_step: "-", record_key: `fill.${i}`, summary: "x".repeat(300), pointer: "-", origin: "procedure-point", provenance: "declared", at });
    if (used + bytes(ev) > 65536 - 100) break;
    fill.push(ev);
    used += bytes(ev);
  }
  fx.pushEvents(sid, fill);
  const r = cli(["--session", sid, "--class", "D", "--step", "-", "--key", "k-over", "--summary", "y".repeat(200), "--pointer", "-", "--origin", "procedure-point"]);
  const over = records(sid, "state-handoff:overflow");
  test("OV-CLI: the overflowing call exits 0 and reports WRITTEN=0 REASON=overflow", () => {
    assert.strictEqual(r.rc, 0, r.err);
    assert.match(r.out, /WRITTEN=0 REASON=overflow/);
  });
  test("OV-CLI: exactly one overflow record, origin procedure-point and provenance declared", () => {
    assert.deepStrictEqual(over.map((e) => [e.cls, e.origin, e.provenance]), [["B", "procedure-point", "declared"]]);
  });
}
caseEnd();

caseBegin("no-state-is-not-written", "bin/workflow/handoff-append");
{
  const sid = "h2652-no-state";
  const r = append(sid, "k-nostate", "procedure-point");
  test("C7: procedure-point with no state file prints WRITTEN=0 REASON=no-state and exits 0", () => {
    assert.strictEqual(r.rc, 0, r.err);
    assert.match(r.out, /WRITTEN=0 REASON=no-state/);
  });
  test("C7: no state file is created", () => {
    assert.strictEqual(fs.existsSync(fx.statePath(sid)), false);
  });
}
caseEnd();
