"use strict";
// SessionStart / PostCompact cases of tests/hooks/feature-3019-pm-instructions.js (#3019). No case markers.
// Both hooks append the library's output verbatim; a failing library never costs the session-id line.
const assert = require("node:assert");
const cp = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const { gitInit } = require("../../lib/harness");
const W8 = require("./world");

const { P, MD_ENV, fixtureMd, makeWorld } = W8;
const ANNOUNCE = "Current workflow session_id: ";
const bad = (r) => `code=${r.code} ctx=${JSON.stringify(r.ctx.slice(-800))} err=${JSON.stringify(r.err.slice(0, 300))}`;
const HOOKS = [["session-start.js", "SessionStart"], ["post-compact.js", "PostCompact"]];

function setup(S, which) {
  const w = makeWorld(S, `hook-${which}`);
  const pmSid = P.uuid(0x30190901);
  const wf = P.uuid(0x30190902);
  const plain = P.uuid(0x30190903);
  w.pm(pmSid, P.pm({ tag: "PM-hook", issues: [4901] }));
  w.plain(wf);
  w.intent(wf, ["#4901"]);
  w.plain(plain);
  return { w, pmSid, wf, plain };
}

// symmetry(S, which) -> the cases of one hook (which = 0 session-start, 1 post-compact).
function symmetry(S, which) {
  const { w, pmSid, wf, plain } = setup(S, which);
  const [file, event] = HOOKS[which];
  const md = { [MD_ENV]: S.md(`hook-${which}`, fixtureMd()) };
  for (const [label, sid] of [["workflow session", wf], ["PM session", pmSid]]) {
    test(`hook-${event}: a ${label} carries the library output verbatim`, () => {
      const lib = w.probe({ sid, deadline: "hook" }, md);
      assert.strictEqual(typeof lib.value, "string", `the library gave no block: ${JSON.stringify(lib.value)}`);
      const r = w.hook(file, sid, event, md);
      assert.strictEqual(r.code, 0, bad(r));
      assert.ok(r.ctx.includes(lib.value), `library block not in the ${event} context: ${bad(r)}`);
      assert.strictEqual(r.ctx.split("[pm-instructions role=").length - 1, 1, `block count: ${bad(r)}`);
    });
  }
  test(`hook-${event}: the md missing -> the session-id line survives and nothing is injected`, () => {
    const r = w.hook(file, wf, event, { [MD_ENV]: S.md(`hook-absent-${which}`, null) });
    assert.strictEqual(r.code, 0, bad(r));
    assert.ok(r.ctx.includes(`${ANNOUNCE}${wf}`), bad(r));
    assert.ok(!r.ctx.includes("[pm-instructions"), bad(r));
  });
  test(`hook-${event}: a session with no PM role -> no block, the session-id line intact`, () => {
    const r = w.hook(file, plain, event, md);
    assert.strictEqual(r.code, 0, bad(r));
    assert.ok(r.ctx.includes(`${ANNOUNCE}${plain}`), bad(r));
    assert.ok(!r.ctx.includes("[pm-instructions"), bad(r));
  });
}

// hookIn(w, S, file, event, sid, cwd, extra) -> {code, err, ctx}: the hook run with cwd as both the hook
// input `cwd` and the child process cwd (world.js pins both to the shared o/r repo).
// procCwd (optional) splits the child process cwd from the input cwd.
function hookIn(w, S, file, event, sid, cwd, extra, procCwd) {
  const input = JSON.stringify({ session_id: sid, hook_event_name: event, source: event === "SessionStart" ? "resume" : undefined, cwd, transcript_path: path.join(S.transcripts, `${sid}.jsonl`) });
  const env = w.env(Object.assign({ CLAUDE_PROJECT_DIR: cwd, GIT_CEILING_DIRECTORIES: path.dirname(cwd) }, extra));
  const r = cp.spawnSync(process.execPath, [path.join(W8.ROOT, "hooks", file)], { cwd: procCwd || cwd, env, input, encoding: "utf8", timeout: 90000 });
  let ctx = "";
  try { const j = JSON.parse(String(r.stdout).trim() || "{}"); const h = j.hookSpecificOutput || j; ctx = typeof h.additionalContext === "string" ? h.additionalContext : ""; } catch (_) { ctx = ""; }
  return { code: r.status, err: `${r.stderr || ""}${r.error ? String(r.error) : ""}`, ctx };
}

function originDir(S, name, origin) {
  const d = path.join(S.tmp, `hook-cwd-${name}`);
  fs.mkdirSync(d, { recursive: true });
  if (origin === null) return d;
  gitInit(d);
  const g = cp.spawnSync("git", ["-C", d, "remote", "add", "origin", origin], { encoding: "utf8", timeout: 30000 });
  if (g.status !== 0) throw new Error(`git remote add: ${g.stderr}`);
  return d;
}

// hookHomeRepo: both hooks resolve a workflow session's bare intent #N against the hook cwd's origin, so a
// PM holding ownerA/repoA#N is injected only when the session runs in ownerA/repoA.
function hookHomeRepo(S) {
  const w = makeWorld(S, "hook-home");
  const pmSid = P.uuid(0x30190a01);
  const wf = P.uuid(0x30190a02);
  w.pm(pmSid, P.pm({ tag: "PM-hookhome", issues: [{ number: 4950, repo: "ownerA/repoA" }] }));
  w.plain(wf);
  w.intent(wf, ["#4950"]);
  const md = { [MD_ENV]: S.md("hook-home", fixtureMd()) };
  const inA = originDir(S, "a", "https://github.com/ownerA/repoA.git");
  const inB = originDir(S, "b", "https://github.com/ownerB/repoB.git");
  const neutral = originDir(S, "none", null);
  for (const [file, event] of HOOKS) {
    // The owner spawn fallback reads the origin of the process cwd, so only a neutral process cwd shows
    // whether the hook input cwd itself reaches resolveRole.
    test(`hook-home-repo-${event}: input cwd origin ownerA/repoA, process cwd without origin -> the PM block`, () => {
      const r = hookIn(w, S, file, event, wf, inA, md, neutral);
      assert.strictEqual(r.code, 0, bad(r));
      assert.ok(r.ctx.includes("[pm-instructions role=workflow"), `no workflow block: ${bad(r)}`);
      assert.ok(r.ctx.includes("PM-hookhome") && r.ctx.includes(pmSid), `the PM is not named: ${bad(r)}`);
    });
    test(`hook-home-repo-${event}: input cwd origin ownerB/repoB, process cwd without origin -> no PM block`, () => {
      const r = hookIn(w, S, file, event, wf, inB, md, neutral);
      assert.strictEqual(r.code, 0, bad(r));
      assert.ok(!r.ctx.includes("[pm-instructions role="), bad(r));
    });
    test(`hook-home-repo-${event}: cwd origin ownerA/repoA, bare intent #N held as ownerA/repoA#N -> the PM block`, () => {
      const r = hookIn(w, S, file, event, wf, inA, md);
      assert.strictEqual(r.code, 0, bad(r));
      assert.ok(r.ctx.includes("[pm-instructions role=workflow"), `no workflow block: ${bad(r)}`);
      assert.ok(r.ctx.includes("PM-hookhome") && r.ctx.includes(pmSid), `the PM is not named: ${bad(r)}`);
    });
    test(`hook-home-repo-${event}: cwd origin ownerB/repoB, the same bare intent #N -> no PM block`, () => {
      const r = hookIn(w, S, file, event, wf, inB, md);
      assert.strictEqual(r.code, 0, bad(r));
      assert.ok(r.ctx.includes(`${ANNOUNCE}${wf}`), bad(r));
      assert.ok(!r.ctx.includes("[pm-instructions role="), bad(r));
    });
  }
}

// startup: source only gates inheritance and the resume mark in session-start.js; the PM block depends on
// the session's own state and intent, so a fresh id gets none and an existing PM/workflow session gets its own.
function startup(S) {
  const w = makeWorld(S, "hook-startup");
  const pmSid = P.uuid(0x30190b01);
  const wf = P.uuid(0x30190b02);
  const fresh = P.uuid(0x30190b03);
  w.pm(pmSid, P.pm({ tag: "PM-startup", issues: [4902] }));
  w.plain(wf);
  w.intent(wf, ["#4902"]);
  const md = { [MD_ENV]: S.md("hook-startup", fixtureMd()) };
  const START = { source: "startup" };
  test("hook-SessionStart-startup: a fresh session id without a state file -> no block, the session-id line intact", () => {
    assert.ok(!w.within(() => P.exists(fresh)), "the fresh id already has a state file");
    const r = w.hook("session-start.js", fresh, "SessionStart", md, START);
    assert.strictEqual(r.code, 0, bad(r));
    assert.ok(r.ctx.includes(`${ANNOUNCE}${fresh}`), bad(r));
    assert.ok(!r.ctx.includes("[pm-instructions"), bad(r));
  });
  for (const [label, sid, role] of [["workflow session", wf, "workflow"], ["PM session", pmSid, "pm"]]) {
    test(`hook-SessionStart-startup: a ${label} gets the same block as on resume`, () => {
      const lib = w.probe({ sid, deadline: "hook" }, md);
      assert.strictEqual(typeof lib.value, "string", `the library gave no block: ${JSON.stringify(lib.value)}`);
      const r = w.hook("session-start.js", sid, "SessionStart", md, START);
      assert.strictEqual(r.code, 0, bad(r));
      assert.ok(r.ctx.includes(`${ANNOUNCE}${sid}`), bad(r));
      assert.ok(r.ctx.includes(`[pm-instructions role=${role} `), bad(r));
      assert.ok(r.ctx.includes(lib.value), `library block not in the startup context: ${bad(r)}`);
    });
  }
}

module.exports = { sessionStart: (S) => symmetry(S, 0), postCompact: (S) => symmetry(S, 1), hookHomeRepo, startup };
