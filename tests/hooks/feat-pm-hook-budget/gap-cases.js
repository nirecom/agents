"use strict";
// Gap cases of tests/hooks/feat-pm-hook-budget.js (#3152); the entrypoint holds their case markers.
//   postWrite(S, cleanup, slackMs): the stages after the PM field write (the inbox read, the write's re-read) hang
//     until their timeout and stay inside the windows budget.js gives them.
//   origin(S): the production budget origin (createHookBudget with no startedAt).
//   writerDefault(S, cleanup): the limited budget runPmWriter builds when deps carry none.
const { test } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { performance } = require("node:perf_hooks");

// Longer than any stage limit, so the world kills the call at its timeout.
const HANG_MS = 999999;

const isInbox = (S, c) => c.kind === "graphql" && String(c.query || "").includes(S.INBOX_QUERY);

function postWrite(S, cleanup, slackMs) {
  const { P, G } = S;
  test("P1 /pm-add whose post-write inbox read hangs: accepted, the read killed within budget.inboxMs() and the hook", () => {
    const me = S.seed({ issues: [31631] });
    try {
      const delay = (c) => (isInbox(S, c) ? HANG_MS : S.slow(400)(c));
      const x = S.respond(me.sid, P.wrapped("pm-add", "#31632"), { delay });
      S.assertAccepted(x, "add", me.tag);
      S.assertWithinHook(x);
      const inbox = x.calls.filter((c) => isInbox(S, c));
      assert.ok(inbox.some((c) => c.outcome === "ETIMEDOUT"), `no inbox read was killed: ${S.brief(x)}`);
      for (const c of inbox) {
        assert.ok(Number.isFinite(c.timeout) && c.timeout <= x.B.INBOX_MS, `inbox timeout ${c.timeout} > INBOX_MS ${x.B.INBOX_MS}: ${S.brief(x)}`);
        assert.ok(c.start + c.timeout <= x.hd + slackMs, `the inbox read runs past the hook deadline: ${S.brief(x)}`);
      }
      assert.strictEqual(G.pmStore()[S.itemOf(31632)], me.tag, "a hung inbox never undoes the write");
    } finally { cleanup([me.sid]); }
  });
  test("P2 /pm-add whose write and its re-read both hang: refused as unknown, the re-read inside writeWindow().reread", () => {
    const me = S.seed({ issues: [31641] });
    let wrote = false;
    const delay = (c) => {
      if (c.kind !== "graphql") return S.slow(400)(c);
      if (c.mutation) { wrote = true; return HANG_MS; }
      return wrote && !isInbox(S, c) ? HANG_MS : 400;
    };
    try {
      const x = S.respond(me.sid, P.wrapped("pm-add", "#31642"), { delay });
      const B = x.B;
      S.assertRefusedWith(x, "timeout");
      assert.match(x.r.block, /pm-field-write-unknown/, S.brief(x));
      S.assertWithinHook(x);
      const at = x.calls.findIndex((c) => c.mutation);
      assert.ok(at >= 0, `no PM field mutation: ${S.brief(x)}`);
      const mut = x.calls[at];
      assert.strictEqual(mut.outcome, "ETIMEDOUT", S.brief(x));
      assert.ok(mut.timeout <= B.WRITE_MUTATION_MS, S.brief(x));
      const reread = x.calls.slice(at + 1).filter((c) => c.kind === "graphql" && !isInbox(S, c));
      assert.strictEqual(reread.length, 1, `one re-read of the unknown write: ${S.brief(x)}`);
      // writeWindow() is taken just before the mutation spawns, so its reread end is at most this.
      const rereadEnd = Math.min(mut.start + B.WRITE_MUTATION_MS + B.WRITE_REREAD_MS, x.hd - B.INBOX_MS);
      assert.ok(reread[0].start + reread[0].timeout <= rereadEnd + slackMs, `the re-read runs past writeWindow().reread ${Math.round(rereadEnd - x.V0)}: ${S.brief(x)}`);
      assert.notStrictEqual(G.pmStore()[S.itemOf(31642)], me.tag, S.brief(x));
    } finally { cleanup([me.sid]); }
  });
}

function origin(S) {
  test("W3 createHookBudget with no startedAt counts from the process start (performance.timeOrigin), as the hook entry calls it", () => {
    const B = S.budgetMod();
    const start = Math.round(performance.timeOrigin);
    const want = start + B.HOOK_TIMEOUT_MS - B.SAFETY_MARGIN_MS;
    assert.strictEqual(B.createHookBudget().hookDeadlineAt, want);
    let t = Date.now();
    const b = B.createHookBudget({ now: () => t });
    assert.strictEqual(b.hookDeadlineAt, want);
    t = start;
    assert.strictEqual(b.left(), B.HOOK_TIMEOUT_MS - B.SAFETY_MARGIN_MS);
  });
}

function writerDefault(S, cleanup) {
  const { P } = S;
  test("W4 runPmWriter with no deps.budget builds a limited budget: a held PM lock is waited for only its left()", () => {
    const B = S.budgetMod();
    const L = P.load("hooks/pm-session/pm-lock.js");
    const W = P.load("hooks/pm-session/writer.js");
    const LEFT_MS = 300;
    const file = L.lockPath();
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify({ pid: process.pid, token: "held-by-test", host: os.hostname(), at: new Date().toISOString() }));
    const me = S.seed({ issues: [31651] });
    // Date.now runs LEFT_MS short of the hook deadline's distance behind while runPmWriter makes its budget;
    // deps.now (read after the budget, before the lock) puts it back, so the made budget has LEFT_MS left.
    const saved = Date.now;
    let shift = -(B.HOOK_TIMEOUT_MS - B.SAFETY_MARGIN_MS - LEFT_MS);
    const spawns = [];
    const deps = {
      now: () => { shift = 0; return Date.now(); },
      spawnSync: (cmd, args) => { spawns.push([cmd].concat(args || []).join(" ")); return { status: 1, stdout: "", stderr: "", error: new Error("no spawn in W4") }; },
    };
    let r;
    let ran;
    try {
      Date.now = () => saved() + shift;
      const p0 = performance.now();
      r = W.runPmWriter({ session_id: me.sid, hook_event_name: "UserPromptSubmit", prompt: P.wrapped("pm-add", "#31652"), cwd: S.cwd }, deps) || {};
      ran = performance.now() - p0;
    } finally {
      Date.now = saved;
      fs.rmSync(file, { force: true });
      cleanup([me.sid]);
    }
    assert.ok(typeof r.block === "string" && /pm-lock-busy/.test(r.block), `expected a pm-lock-busy refusal: ${JSON.stringify(r)}`);
    assert.ok(ran < L.PM_LOCK_WAIT_MS - 500, `waited ${Math.round(ran)} ms with ${LEFT_MS} ms left (PM_LOCK_WAIT_MS ${L.PM_LOCK_WAIT_MS})`);
    assert.deepStrictEqual(spawns, [], "nothing is spawned before the lock");
  });
}

module.exports = { postWrite, origin, writerDefault };
