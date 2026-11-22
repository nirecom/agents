"use strict";
// Role cases of tests/hooks/feature-3019-pm-instructions.js (#3019, #2942): who gets which bundle — the PM
// role from PM state, the workflow role from the forge PM field. No case markers (the dispatcher owns them).
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const W8 = require("./world");

const { P, MD_ENV, CONTRACT, BUNDLE, mark, fixtureMd, makeWorld, brief, firstLine } = W8;
const H_PM = "[pm-instructions role=pm timing=session-start]";
const H_WF = "[pm-instructions role=workflow timing=session-start]";
const has = (r, s) => assert.ok(String(r.value).includes(s), `missing ${JSON.stringify(s)}: ${brief(r)}`);
const lacks = (r, s) => assert.ok(!String(r.value).includes(s), `unexpected ${JSON.stringify(s)}: ${brief(r)}`);
const none = (r) => assert.strictEqual(r.value, null, brief(r));
const only = (r, want) => {
  for (const c of CONTRACT) (want.includes(c) ? has : lacks)(r, mark(c));
  lacks(r, "BODY-in-a-comment");
};

// pmRole: an active PM -> the PM bundle with its tag and issues; archived or unmarked -> nothing.
function pmRole(S) {
  const w = makeWorld(S, "pm-role");
  const md = { [MD_ENV]: S.md("pm-role", fixtureMd()) };
  const active = P.uuid(0x30190101);
  const archived = P.uuid(0x30190102);
  const plain = P.uuid(0x30190103);
  w.pm(active, P.pm({ tag: "PM-roleA", issues: [4101, { number: 4102, repo: "x/y" }] }));
  w.pm(archived, P.pm({ tag: "PM-roleZ", issues: [4103], archived_at: "2026-11-02T00:00:00.000Z" }));
  w.plain(plain);
  test("role-pm: an active PM gets the PM session bundle under the role=pm header", () => {
    const r = w.probe({ sid: active }, md);
    assert.strictEqual(firstLine(r.value), H_PM, brief(r));
    only(r, BUNDLE.pm);
  });
  test("role-pm: the PM block names its PM tag and every assigned issue", () => {
    const r = w.probe({ sid: active }, md);
    for (const s of ["PM-roleA", "#4101", "x/y#4102"]) has(r, s);
    assert.strictEqual(r.calls, 0, brief(r));
  });
  test("role-pm: an archived PM (pm mark, archived_at set) gets nothing", () => none(w.probe({ sid: archived }, md)));
  test("role-pm: a session without a PM mark and without issues gets nothing", () => none(w.probe({ sid: plain }, md)));
  test("role-pm: a session with no state file at all gets nothing (fail-open, no throw)", () => none(w.probe({ sid: P.uuid(0x30190104) }, md)));
}

// workflowDirect: the PM field of the session's own issue names an active PM -> the workflow bundle.
function workflowDirect(S) {
  const w = makeWorld(S, "wf-direct");
  const md = { [MD_ENV]: S.md("wf-direct", fixtureMd()) };
  const pmSid = P.uuid(0x30190201);
  const wf = P.uuid(0x30190202);
  const bare = P.uuid(0x30190203);
  w.pm(pmSid, P.pm({ tag: "PM-dirA", issues: [4201] }));
  w.field({ "o/r#4201": "PM-dirA" });
  w.plain(wf);
  w.intent(wf, ["#4201"]);
  w.plain(bare);
  test("role-workflow: intent ## Issues whose PM field names a PM -> the workflow bundle under the role=workflow header", () => {
    const r = w.probe({ sid: wf, deadline: "hook" }, md);
    assert.strictEqual(firstLine(r.value), H_WF, brief(r));
    only(r, BUNDLE.workflow);
    assert.strictEqual(r.err.trim(), "", brief(r));
  });
  test("role-workflow: the block names the PM tag and the PM's full session id, read from the PM field via bin/pm-state owner", () => {
    const r = w.probe({ sid: wf, deadline: "hook" }, md);
    has(r, "PM-dirA");
    has(r, pmSid);
    assert.ok(r.calls >= 1, `the PM field was never read: ${brief(r)}`);
  });
  test("role-workflow: explicit issues replace the intent lookup (a session without an intent resolves too)", () => {
    const r = w.probe({ sid: bare, issues: [{ number: 4201 }], deadline: "hook" }, md);
    assert.strictEqual(firstLine(r.value), H_WF, brief(r));
    has(r, pmSid);
  });
  test("role-workflow: explicit empty issues -> nothing (the startup case)", () => none(w.probe({ sid: bare, issues: [], deadline: "hook" }, md)));
}

// fieldDecides: the PM field alone decides the owner (#2942). The former local tie-break by assigned_at is
// gone — the field holds one tag, so two state lists naming one issue no longer compete; these cases pin
// that the state lists are not an input either way.
function fieldDecides(S) {
  const w = makeWorld(S, "field");
  const md = { [MD_ENV]: S.md("field", fixtureMd()) };
  const held = (tag, n, at) => P.pm({ tag, issues: [n], current_since: at, assignment_log: [{ at, op: "init", issues: [{ number: n }], reason: "fixture" }] });
  const early = P.uuid(0x3019030b);
  const unlisted = P.uuid(0x30190308);
  w.pm(P.uuid(0x3019030a), held("PM-late", 4301, "2026-11-06T00:00:00.000Z"));
  w.pm(early, held("PM-early", 4301, "2026-11-02T00:00:00.000Z"));
  w.pm(unlisted, P.pm({ tag: "PM-unlisted", issues: [] }));
  w.pm(P.uuid(0x30190309), P.pm({ tag: "PM-listed", issues: [4303] }));
  w.field({ "o/r#4301": "PM-early", "o/r#4302": "PM-unlisted", "o/r#4303": null });
  const probe = (n) => w.probe({ sid: P.uuid(0x30190399), issues: [{ number: n }], deadline: "hook" }, md);
  test("role-workflow-field: two state lists hold the issue -> the PM the field names, the same as bin/pm-state owner", () => {
    const owner = w.pmState(["owner", "--issue", "#4301"]);
    assert.deepStrictEqual(owner, { tag: "PM-early", session_id: early });
    const r = probe(4301);
    has(r, "PM-early");
    has(r, early);
    lacks(r, "PM-late");
  });
  test("role-workflow-field: the field names a PM whose state list lacks the issue -> that PM is injected", () => {
    const r = probe(4302);
    has(r, "PM-unlisted");
    has(r, unlisted);
  });
  test("role-workflow-field: a state list holds the issue but the field is empty ({pm:null}) -> no injection, no stderr line", () => {
    const r = probe(4303);
    none(r);
    assert.strictEqual(r.err.trim(), "", brief(r));
  });
}

// failLine(r) -> asserts exactly one stderr line, the inject.js fail-open reason of a failed owner lookup.
const failLine = (r) => {
  const lines = String(r.err).split(/\r?\n/).filter(Boolean);
  assert.strictEqual(lines.length, 1, `stderr lines: ${JSON.stringify(r.err)}`);
  assert.ok(lines[0].startsWith("pm-instructions: owner lookup failed"), `stderr: ${JSON.stringify(r.err)}`);
  return lines[0];
};

// metaRouted: the child's own PM field is empty and its meta parent's names a PM -> the ancestor's value, read
// by one bin/pm-state owner spawn inside the deadline slice; every failed lookup is one stderr reason line.
function metaRouted(S) {
  const w = makeWorld(S, "meta");
  const md = { [MD_ENV]: S.md("meta", fixtureMd()) };
  const pmSid = P.uuid(0x30190401);
  const wf = P.uuid(0x30190402);
  const failing = P.uuid(0x30190403);
  const stranger = P.uuid(0x30190406);
  w.pm(pmSid, P.pm({ tag: "PM-meta", issues: [4400] }));
  w.plain(wf);
  w.intent(wf, ["#4401"]);
  w.plain(failing);
  w.intent(failing, ["#4409"]);
  w.plain(stranger);
  w.intent(stranger, ["#4408"]);
  w.setMap({
    "o/r#4400": { parent: null, labels: ["meta"], pm: "PM-meta" }, "o/r#4401": { parent: { number: 4400, repo: "o/r" } },
    "o/r#4409": { fail: true }, "o/r#4408": { parent: null, pm: "PM-stranger" },
  });
  test("role-meta: a child of a meta whose PM field names a PM resolves through the ancestor chain and is injected", () => {
    const r = w.probe({ sid: wf, deadline: "hook" }, md);
    assert.strictEqual(firstLine(r.value), H_WF, brief(r));
    has(r, "PM-meta");
    has(r, pmSid);
    assert.ok(r.calls >= 1, `fake gh was never called: ${brief(r)}`);
  });
  test("role-meta: a deadline whose slice is 0 -> no spawn, no injection, one owner-lookup-failed line (fail-open)", () => {
    const r = w.probe({ sid: wf, deadline: "zero" }, md);
    none(r);
    assert.strictEqual(r.calls, 0, brief(r));
    failLine(r);
  });
  test("role-meta: a slow forge -> the owner lookup times out inside the hook budget, no injection, one owner-lookup-failed line", () => {
    const r = w.probe({ sid: wf, deadline: "hook" }, Object.assign({ PM_FAKE_GH_SLEEP_MS: 8000 }, md));
    none(r);
    assert.ok(r.innerMs < 7000, `the lookup took ${r.innerMs} ms against a 1500 ms slice`);
    assert.match(failLine(r), /#4401 timeout/);
  });
  test("role-meta: the forge read fails (bin/pm-state owner exits non-zero) -> no injection, one owner-lookup-failed line", () => {
    const r = w.probe({ sid: failing, deadline: "hook" }, md);
    none(r);
    assert.match(failLine(r), /#4409 exit 1/);
  });
  test("role-meta: the PM field names a tag no local PM state holds (tag-not-local) -> no injection, one owner-lookup-failed line", () => {
    const r = w.probe({ sid: stranger, deadline: "hook" }, md);
    none(r);
    assert.match(failLine(r), /#4408/);
  });
  const w2 = makeWorld(S, "meta-none");
  const wf2 = P.uuid(0x30190404);
  w2.pm(P.uuid(0x30190405), P.pm({ tag: "PM-gone", issues: [4400], archived_at: "2026-11-02T00:00:00.000Z" }));
  w2.plain(wf2);
  w2.intent(wf2, ["#4401"]);
  w2.setMap({ "o/r#4400": { parent: null, labels: ["meta"], pm: "PM-gone" }, "o/r#4401": { parent: { number: 4400, repo: "o/r" } } });
  test("role-meta: the meta's PM field names an ended (archived) PM -> {pm:null}: no injection, no stderr line", () => {
    const r = w2.probe({ sid: wf2, deadline: "hook" }, md);
    none(r);
    assert.strictEqual(r.err.trim(), "", brief(r));
  });
}

// peerOnly: a recorded role=pm peer-msg header is a self-claim and never decides the role.
function peerOnly(S) {
  const w = makeWorld(S, "peer");
  const md = { [MD_ENV]: S.md("peer", fixtureMd()) };
  const wf = P.uuid(0x30190501);
  const peer = P.uuid(0x30190502);
  w.pm(P.uuid(0x30190503), P.pm({ tag: "PM-other", issues: [4599] }));
  w.plain(peer);
  w.plain(wf);
  w.intent(wf, ["#4501"]);
  w.progress(wf, `[peer-msg v1] from-session=${peer} msg-id=00000000-0000-4000-8000-000000004501 reply-to=${peer} reply-kind=session-id role=pm pm-issues=#4501`);
  w.setMap({ "o/r#4501": { parent: null } });
  test("role-peer: only a recorded role=pm header and an empty PM field -> nothing", () => {
    const r = w.probe({ sid: wf, deadline: "hook" }, md);
    none(r);
  });
}

// constOf(file, re) -> the number a source constant is set to; throws when the pattern no longer matches.
function constOf(file, re) {
  const m = re.exec(fs.readFileSync(path.join(W8.ROOT, "hooks", ...file), "utf8"));
  if (!m) throw new Error(`${file.join("/")}: ${re} not found`);
  return Number(m[1]);
}

// hookSlowForge: the real hooks against a forge slower than the hook budget stay inside that budget and
// leave the meta-routed owner out while the session-id line survives.
function hookSlowForge(S) {
  const w = makeWorld(S, "hook-slow");
  const md = { [MD_ENV]: S.md("hook-slow", fixtureMd()) };
  const wf = P.uuid(0x30190c01);
  w.pm(P.uuid(0x30190c02), P.pm({ tag: "PM-slow", issues: [4410] }));
  w.plain(wf);
  w.intent(wf, ["#4411"]);
  w.setMap({ "o/r#4410": { parent: null, labels: ["meta"], pm: "PM-slow" }, "o/r#4411": { parent: { number: 4410, repo: "o/r" } } });
  // The deadline is anchored at the hook's process start and already keeps a safety margin back, and the
  // owner spawn takes its kill margin out of its slice, so a correct hook exits before the budget. Allow one
  // TREE_KILL_MARGIN_MS on top for what the child clock cannot see: process creation and pipe teardown.
  const killMargin = constOf(["lib", "pm-instructions", "role.js"], /const TREE_KILL_MARGIN_MS = (\d+);/);
  const budgets = [
    ["session-start.js", "SessionStart", constOf(["session-start.js"], /const HOOK_TIMEOUT_MS = (\d+);/)],
    ["post-compact.js", "PostCompact", constOf(["post-compact.js"], /createDeadline\(\{ hookTimeoutMs: (\d+) \}\)/)],
  ];
  for (const [file, event, budget] of budgets) {
    test(`role-hook-slow-forge ${event}: elapsed within the ${budget} ms budget + ${killMargin} ms, no owner block, session-id line kept`, () => {
      const sleep = budget * 2;
      const r = w.hook(file, wf, event, Object.assign({ PM_FAKE_GH_SLEEP_MS: sleep }, md));
      const ctxBrief = `code=${r.code} ms=${r.ms} ctx=${JSON.stringify(r.ctx.slice(-600))} err=${JSON.stringify(r.err.slice(0, 300))}`;
      assert.strictEqual(r.code, 0, ctxBrief);
      assert.ok(r.ms < budget + killMargin, `the hook took ${r.ms} ms: ${ctxBrief}`);
      assert.ok(r.ctx.includes(`Current workflow session_id: ${wf}`), ctxBrief);
      assert.ok(!r.ctx.includes("[pm-instructions") && !r.ctx.includes("PM-slow"), ctxBrief);
    });
  }
}

module.exports = { pmRole, workflowDirect, fieldDecides, metaRouted, peerOnly, hookSlowForge };
