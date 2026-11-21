"use strict";
// Role cases of tests/hooks/feature-3019-pm-instructions.js (#3019): who gets which bundle, from PM state only.
// No case markers (the dispatcher owns them).
const assert = require("node:assert");
const cp = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const { gitInit } = require("../../lib/harness");
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

// workflowDirect: a workflow session whose issue a PM holds directly -> the workflow bundle, no forge call.
function workflowDirect(S) {
  const w = makeWorld(S, "wf-direct");
  const md = { [MD_ENV]: S.md("wf-direct", fixtureMd()) };
  const pmSid = P.uuid(0x30190201);
  const wf = P.uuid(0x30190202);
  const bare = P.uuid(0x30190203);
  w.pm(pmSid, P.pm({ tag: "PM-dirA", issues: [4201] }));
  w.plain(wf);
  w.intent(wf, ["#4201"]);
  w.plain(bare);
  test("role-workflow: intent ## Issues held directly -> the workflow bundle under the role=workflow header", () => {
    const r = w.probe({ sid: wf, deadline: "hook" }, md);
    assert.strictEqual(firstLine(r.value), H_WF, brief(r));
    only(r, BUNDLE.workflow);
  });
  test("role-workflow: the block names the PM tag and the PM's full session id, without spawning", () => {
    const r = w.probe({ sid: wf, deadline: "hook" }, md);
    has(r, "PM-dirA");
    has(r, pmSid);
    assert.strictEqual(r.calls, 0, `fake gh was called: ${brief(r)}`);
  });
  test("role-workflow: explicit issues replace the intent lookup (a session without an intent resolves too)", () => {
    const r = w.probe({ sid: bare, issues: [{ number: 4201 }], deadline: "hook" }, md);
    assert.strictEqual(firstLine(r.value), H_WF, brief(r));
    has(r, pmSid);
  });
  test("role-workflow: explicit empty issues -> nothing (the startup case)", () => none(w.probe({ sid: bare, issues: [], deadline: "hook" }, md)));
}

// tieBreak: two active PMs hold the same issue directly -> the injected PM is what `bin/pm-state owner` answers.
function tieBreak(S) {
  const w = makeWorld(S, "tie");
  const md = { [MD_ENV]: S.md("tie", fixtureMd()) };
  const held = (tag, n, at) => P.pm({ tag, issues: [n], current_since: at, assignment_log: [{ at, op: "init", issues: [{ number: n }], reason: "fixture" }] });
  w.pm(P.uuid(0x3019030a), held("PM-late", 4301, "2026-11-06T00:00:00.000Z"));
  w.pm(P.uuid(0x3019030b), held("PM-early", 4301, "2026-11-02T00:00:00.000Z"));
  w.pm(P.uuid(0x30190308), held("PM-tieB", 4302, "2026-11-05T00:00:00.000Z"));
  w.pm(P.uuid(0x30190309), held("PM-tieA", 4302, "2026-11-05T00:00:00.000Z"));
  const others = { 4301: ["PM-late", "PM-early"], 4302: ["PM-tieA", "PM-tieB"] };
  for (const [label, n] of [["different assigned_at", 4301], ["the same assigned_at, tags differing", 4302]]) {
    test(`role-workflow-tie: ${label} -> the same PM as bin/pm-state owner, without spawning`, () => {
      const owner = w.pmState(["owner", "--issue", `#${n}`]);
      assert.ok(owner && owner.tag && owner.session_id, `pm-state owner gave no owner: ${JSON.stringify(owner)}`);
      const r = w.probe({ sid: P.uuid(0x30190399), issues: [{ number: n }], deadline: "hook" }, md);
      has(r, owner.tag);
      has(r, owner.session_id);
      for (const t of others[n].filter((x) => x !== owner.tag)) lacks(r, t);
      assert.strictEqual(r.calls, 0, brief(r));
    });
  }
}

// metaRouted: no direct holder but an active PM exists -> one bin/pm-state owner spawn inside the deadline slice.
function metaRouted(S) {
  const w = makeWorld(S, "meta");
  const md = { [MD_ENV]: S.md("meta", fixtureMd()) };
  const pmSid = P.uuid(0x30190401);
  const wf = P.uuid(0x30190402);
  const failing = P.uuid(0x30190403);
  w.pm(pmSid, P.pm({ tag: "PM-meta", issues: [4400] }));
  w.plain(wf);
  w.intent(wf, ["#4401"]);
  w.plain(failing);
  w.intent(failing, ["#4409"]);
  w.setMap({ "o/r#4400": { parent: null, labels: ["meta"] }, "o/r#4401": { parent: { number: 4400, repo: "o/r" } }, "o/r#4409": { fail: true } });
  test("role-meta: a child of a held meta resolves through the forge and is injected", () => {
    const r = w.probe({ sid: wf, deadline: "hook" }, md);
    assert.strictEqual(firstLine(r.value), H_WF, brief(r));
    has(r, "PM-meta");
    has(r, pmSid);
    assert.ok(r.calls >= 1, `fake gh was never called: ${brief(r)}`);
  });
  test("role-meta: a deadline whose slice is 0 -> no spawn and no injection (fail-open)", () => {
    const r = w.probe({ sid: wf, deadline: "zero" }, md);
    none(r);
    assert.strictEqual(r.calls, 0, brief(r));
  });
  test("role-meta: a slow forge -> the owner lookup times out inside the hook budget and is left out", () => {
    const r = w.probe({ sid: wf, deadline: "hook" }, Object.assign({ PM_FAKE_GH_SLEEP_MS: 8000 }, md));
    none(r);
    assert.ok(r.innerMs < 7000, `the lookup took ${r.innerMs} ms against a 1500 ms slice`);
  });
  test("role-meta: bin/pm-state owner exits non-zero -> that issue is left out (fail-open)", () => none(w.probe({ sid: failing, deadline: "hook" }, md)));
  const w2 = makeWorld(S, "meta-none");
  const wf2 = P.uuid(0x30190404);
  w2.pm(P.uuid(0x30190405), P.pm({ tag: "PM-gone", issues: [4400], archived_at: "2026-11-02T00:00:00.000Z" }));
  w2.plain(wf2);
  w2.intent(wf2, ["#4401"]);
  w2.setMap({ "o/r#4400": { parent: null, labels: ["meta"] }, "o/r#4401": { parent: { number: 4400, repo: "o/r" } } });
  test("role-meta: no active PM at all -> no spawn and no injection", () => {
    const r = w2.probe({ sid: wf2, deadline: "hook" }, md);
    none(r);
    assert.strictEqual(r.calls, 0, brief(r));
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
  test("role-peer: only a recorded role=pm header and no PM-state owner -> nothing", () => {
    const r = w.probe({ sid: wf, deadline: "hook" }, md);
    none(r);
  });
}

// roleIn(w, cwd, sid, issues) -> resolveRole's answer from a child whose process cwd (and opts.cwd, the
// assumed injection point) is cwd; no deadline, so the owner spawn fallback never runs.
const ROLE_JS = path.join(W8.ROOT, "hooks", "lib", "pm-instructions", "role.js");
function roleIn(w, cwd, sid, issues) {
  const script = "const q=JSON.parse(process.env.ROLE_REQ);process.stdout.write(JSON.stringify(require(q.mod).resolveRole(q.sid,{issues:q.issues,cwd:q.cwd})))";
  const req = JSON.stringify({ mod: ROLE_JS, sid, issues, cwd });
  const r = cp.spawnSync(process.execPath, ["-e", script], {
    cwd, env: w.env({ ROLE_REQ: req, GIT_CEILING_DIRECTORIES: path.dirname(cwd) }), encoding: "utf8", timeout: 60000,
  });
  if (r.status !== 0) throw new Error(`resolveRole child exit=${r.status}: ${String(r.stderr).slice(0, 400)}`);
  return JSON.parse(r.stdout);
}

// repoDir(S, name, origin) -> a fixture dir: a git repo with that origin, or a plain dir when origin is null.
function repoDir(S, name, origin) {
  const d = path.join(S.tmp, `cwd-${name}`);
  fs.mkdirSync(d, { recursive: true });
  if (origin === null) return d;
  gitInit(d);
  const g = cp.spawnSync("git", ["-C", d, "remote", "add", "origin", origin], { encoding: "utf8", timeout: 30000 });
  if (g.status !== 0) throw new Error(`git remote add: ${g.stderr}`);
  return d;
}

// currentGeneration: after a hand-over the upstream state keeps an active pm mark; only the file with the
// largest pm.current_since for the tag is the current generation and holds the PM role.
function currentGeneration(S) {
  const w = makeWorld(S, "gen");
  const cwd = repoDir(S, "gen", "https://github.com/o/r.git");
  const up = P.uuid(0x30190601);
  const down = P.uuid(0x30190602);
  w.pm(up, P.pm({ tag: "PM-gen", issues: [4601], current_since: "2026-11-01T00:00:00.000Z" }));
  w.pm(down, P.pm({ tag: "PM-gen", issues: [4601], current_since: "2026-11-08T00:00:00.000Z", upstream_session_id: up }));
  test("R-gen-1: an active pm mark that is not the current generation of its tag -> role null", () => {
    assert.deepStrictEqual(roleIn(w, cwd, up, []), { role: null });
  });
  test("R-gen-2: the current generation (largest current_since) -> role pm with its tag", () => {
    const r = roleIn(w, cwd, down, []);
    assert.strictEqual(r.role, "pm", JSON.stringify(r));
    assert.strictEqual(r.tag, "PM-gen", JSON.stringify(r));
  });
}

// homeRepo: a bare #N in a workflow session resolves to the cwd origin's owner/repo before it is compared
// with the PM's repo-resolved list; a cwd without an origin keeps a bare ref compared by its given repo.
function homeRepo(S) {
  const w = makeWorld(S, "home");
  const pmSid = P.uuid(0x30190701);
  const wf = P.uuid(0x30190702);
  w.pm(pmSid, P.pm({ tag: "PM-home", issues: [{ number: 4701, repo: "ownerA/repoA" }, 4702] }));
  w.plain(wf);
  const inA = repoDir(S, "home-a", "https://github.com/ownerA/repoA.git");
  const inB = repoDir(S, "home-b", "https://github.com/ownerB/repoB.git");
  const noGit = repoDir(S, "home-none", null);
  test("R-repo-1: bare #N, cwd origin ownerB/repoB, PM holds ownerA/repoA#N -> no owner, role null", () => {
    assert.deepStrictEqual(roleIn(w, inB, wf, [{ number: 4701 }]), { role: null });
  });
  test("R-repo-2: bare #N, cwd origin ownerA/repoA, PM holds ownerA/repoA#N -> role workflow with that PM", () => {
    const r = roleIn(w, inA, wf, [{ number: 4701 }]);
    assert.strictEqual(r.role, "workflow", JSON.stringify(r));
    assert.deepStrictEqual(r.owners.map((o) => [o.tag, o.session_id]), [["PM-home", pmSid]], JSON.stringify(r));
  });
  test("R-repo-boundary: cwd without origin -> a bare #N does not match a repo-resolved PM ref", () => {
    assert.deepStrictEqual(roleIn(w, noGit, wf, [{ number: 4701 }]), { role: null });
  });
  test("R-repo-boundary: cwd without origin -> a bare #N still matches a bare PM ref", () => {
    const r = roleIn(w, noGit, wf, [{ number: 4702 }]);
    assert.strictEqual(r.role, "workflow", JSON.stringify(r));
    assert.deepStrictEqual(r.owners.map((o) => o.session_id), [pmSid], JSON.stringify(r));
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
  w.setMap({ "o/r#4410": { parent: null, labels: ["meta"] }, "o/r#4411": { parent: { number: 4410, repo: "o/r" } } });
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

module.exports = { pmRole, workflowDirect, tieBreak, metaRouted, peerOnly, currentGeneration, homeRepo, hookSlowForge };
