"use strict";
// tests/hooks/feat-pm-hook-budget.js
// Tests: hooks/pm-session/budget.js, hooks/pm-session/writer.js, hooks/user-prompt-submit-issue-title/title.js, hooks/pm-session/ownership.js, hooks/pm-session/rename.js, hooks/pm-session/inherit.js
// Tags: TL2, scope:common, pm-session, user-prompt-submit, forge, budget
// #3152: one UserPromptSubmit hook run fits its 10 s timeout. budget.js owns the stage limits; the sum is
// checked against settings.json, and every PM command runs end to end through title.js respond with each
// forge call slowed to 400 / 900 ms on a virtual clock (./feat-pm-hook-budget/world.js), no real gh spawned.
// Also: the refusal wording of the three time-outs (budget-exhausted, timeout, spawn-failed) per command, the
// PM lock wait capped by the budget's left(), and the card stage on both sides of ENSURE_CARD_MIN_MS.
// TL3 gap: the real hook process (node start-up, module load, stdout) and the real gh's latency are not
// observed here; SAFETY_MARGIN_MS stands for them, and the Windows run of /pm-add is the user-verified check.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restore = isolate();
const neutral = fs.mkdtempSync(path.join(os.tmpdir(), "pm-hook-budget-"));
const savedCwd = process.cwd();
process.chdir(neutral);
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(neutral, "transcripts");
fs.mkdirSync(process.env.CLAUDE_TRANSCRIPT_BASE_DIR);
after(() => { process.chdir(savedCwd); try { fs.rmSync(neutral, { recursive: true, force: true }); } catch (_) { /* held by the OS */ } restore(); });

// world.js (through scenario.js) wraps child_process before any hook module loads.
const S = require("./feat-pm-hook-budget/scenario");
const { createWorld } = require("./feat-pm-hook-budget/world");
const { P, G } = S;

// The test's own model of one gh call (plan): a typical answer and the spawn overhead around it.
const GH_TYPICAL_MS = 900;
const SPAWN_SLACK_MS = 200;
const windowEnd = (v) => (typeof v === "number" ? v : Math.max(...Object.values(v || {}).filter(Number.isFinite)));

caseBegin("hook-budget-sum-reconciles", "hooks/pm-session/budget.js");
test("H1 settings.json gives the title hook the timeout budget.js plans for", () => {
  const B = S.budgetMod();
  const st = JSON.parse(fs.readFileSync(path.join(P.ROOT, "settings.json"), "utf8"));
  const hooks = [].concat(...(st.hooks.UserPromptSubmit || []).map((g) => g.hooks || []));
  const h = hooks.find((x) => /user-prompt-submit-issue-title\.js/.test(String(x.command)));
  assert.ok(h, "no UserPromptSubmit hook runs user-prompt-submit-issue-title.js");
  assert.strictEqual(h.timeout * 1000, B.HOOK_TIMEOUT_MS);
});
test("H2 the reserved stages plus the check minimum and the margin fit the hook timeout", () => {
  const B = S.budgetMod();
  const { PM_LOCK_WAIT_MS } = P.load("hooks/pm-session/pm-lock.js");
  const { ORIGIN_TIMEOUT_MS } = P.load("bin/lib/pm-field/forge-kind.js");
  for (const [k, v] of Object.entries({ PM_LOCK_WAIT_MS, ORIGIN_TIMEOUT_MS })) assert.ok(Number.isFinite(v) && v > 0, `${k} is not exported as a number`);
  const reserved = B.SAFETY_MARGIN_MS + PM_LOCK_WAIT_MS + ORIGIN_TIMEOUT_MS + B.WRITE_MUTATION_MS + B.WRITE_REREAD_MS + B.INBOX_MS;
  assert.ok(reserved + B.CHECK_MIN_MS <= B.HOOK_TIMEOUT_MS, `reserved ${reserved} + check ${B.CHECK_MIN_MS} > ${B.HOOK_TIMEOUT_MS}`);
  assert.ok(B.CHECK_MIN_MS >= 2 * GH_TYPICAL_MS + 2 * SPAWN_SLACK_MS, "the check stage holds two gh calls");
  assert.ok(B.ENSURE_REREAD_MS >= GH_TYPICAL_MS + SPAWN_SLACK_MS, "the card re-read holds one whole gh call");
  assert.ok(B.ENSURE_CARD_MIN_MS >= B.ENSURE_REREAD_MS + B.GH_MIN_CALL_MS, "the ensure window holds a spawn and the re-read");
});
test("H3 the origin limit has one source: title.js and writer-common.js hold no copy", () => {
  const { ORIGIN_TIMEOUT_MS } = P.load("bin/lib/pm-field/forge-kind.js");
  assert.strictEqual(ORIGIN_TIMEOUT_MS, 1000);
  const T = P.load("hooks/user-prompt-submit-issue-title/title.js");
  if (T.ORIGIN_TIMEOUT_MS !== undefined) assert.strictEqual(T.ORIGIN_TIMEOUT_MS, ORIGIN_TIMEOUT_MS);
  const C = P.load("hooks/pm-session/writer-common.js");
  for (const k of ["WRITER_CHECK_BUDGET_MS", "WRITER_WRITE_BUDGET_MS", "ORIGIN_TIMEOUT_MS"]) assert.strictEqual(C[k], undefined, `writer-common.js still exports ${k}`);
});
caseEnd();

caseBegin("hook-budget-windows", "hooks/pm-session/budget.js");
test("W1 createHookBudget derives every stage deadline from startedAt and now", () => {
  const B = S.budgetMod();
  let t = 1000;
  const b = B.createHookBudget({ startedAt: 1000, now: () => t });
  const W = B.WRITE_MUTATION_MS + B.WRITE_REREAD_MS;
  const hd = 1000 + B.HOOK_TIMEOUT_MS - B.SAFETY_MARGIN_MS;
  assert.strictEqual(b.hookDeadlineAt, hd);
  assert.strictEqual(b.checkDeadline(), hd - W - B.INBOX_MS);
  assert.strictEqual(b.checkDeadline({ write: false }), hd - B.INBOX_MS, "resume-session has no write stage");
  const t0 = hd - B.INBOX_MS - W - B.ENSURE_CARD_MIN_MS;
  t = t0;
  assert.deepStrictEqual(b.ensureWindow(), { spawnMs: B.ENSURE_CARD_MIN_MS - B.ENSURE_REREAD_MS, rereadDeadlineAt: t0 + B.ENSURE_CARD_MIN_MS });
  t = t0 + 1;
  assert.strictEqual(b.ensureWindow(), null, "R one below ENSURE_CARD_MIN_MS starts no card spawn");
  t = 1500;
  assert.strictEqual(windowEnd(b.writeWindow()), 1500 + W, "an early write gets its whole window");
  t = hd - B.INBOX_MS - 100;
  assert.strictEqual(windowEnd(b.writeWindow()), hd - B.INBOX_MS, "a late write never eats the inbox");
  t = 1000;
  assert.strictEqual(b.inboxMs(), B.INBOX_MS);
  t = hd - 500;
  assert.strictEqual(b.inboxMs(), 500);
  assert.strictEqual(b.left(), 500);
  t = hd + 10;
  assert.strictEqual(b.left(), 0, "left() never goes negative");
  assert.strictEqual(b.inboxMs(), 0, "inboxMs() is 0 past the hook deadline");
});
test("W2 createUnlimitedBudget has no limit; budgetOf falls back to it when deps carry no budget", () => {
  const B = S.budgetMod();
  const u = B.createUnlimitedBudget();
  assert.strictEqual(u.limited, false);
  assert.strictEqual(u.hookDeadlineAt, Infinity);
  assert.strictEqual(u.checkDeadline(), Infinity);
  assert.deepStrictEqual(u.ensureWindow(), { spawnMs: Infinity, rereadDeadlineAt: Infinity });
  assert.deepStrictEqual(u.writeWindow(), { mutate: Infinity, reread: Infinity });
  assert.strictEqual(u.inboxMs(), B.INBOX_MS);
  assert.strictEqual(u.left(), Infinity);
  for (const deps of [undefined, null, {}]) assert.strictEqual(B.budgetOf(deps).limited, false, JSON.stringify(deps));
  const limited = B.createHookBudget({ startedAt: 0, now: () => 0 });
  assert.strictEqual(B.budgetOf({ budget: limited }), limited);
});
caseEnd();

caseBegin("hook-budget-title-skips-when-spent", "hooks/user-prompt-submit-issue-title/title.js");
test("T1 a spent budget skips the tracker fetch and counts no failure; a fresh one still fetches", () => {
  const B = S.budgetMod();
  const T = P.load("hooks/user-prompt-submit-issue-title/title.js");
  const fetch = (late) => {
    const W = createWorld({ G, delay: S.slow(0) });
    return W.run(() => {
      const budget = B.createHookBudget({ startedAt: W.now() - late, now: () => W.now() });
      const rec = { titles: {}, failures: {} };
      const title = T.titleFor({ number: 31529, repo: "o/r" }, rec, { spawnSync: W.spawnSync, budget, now: () => Date.now() }, S.cwd, Date.now());
      return { title, rec, gh: W.calls.filter((c) => c.kind !== "git").length };
    });
  };
  const fresh = fetch(0);
  assert.ok(fresh.gh >= 1, `a fresh budget fetches the title: ${JSON.stringify(fresh)}`);
  const spent = fetch(B.HOOK_TIMEOUT_MS);
  assert.strictEqual(spent.title, null);
  assert.strictEqual(spent.gh, 0, `no gh call on a spent budget: ${JSON.stringify(spent)}`);
  assert.deepStrictEqual(spent.rec.failures, {}, "a skipped fetch is retried at the next prompt");
});
caseEnd();

caseBegin("hook-budget-e2e-pm-add", "hooks/pm-session/writer.js");
for (const ms of [400, 900]) {
  test(`E1 /pm-add #2105 #3151 beside another active PM, every forge call ${ms} ms: accepted within the hook`, () => {
    const other = S.seed({ issues: [31501], base: "PM-oth" });
    const me = S.seed({ issues: [31502] });
    try {
      const x = S.respond(me.sid, P.wrapped("pm-add", "#2105 #3151"), { delay: S.slow(ms) });
      S.assertAccepted(x, "add", me.tag);
      S.assertWithinHook(x);
      const firstMut = x.calls.findIndex((c) => c.mutation);
      assert.ok(firstMut >= 0, `no PM field mutation: ${S.brief(x)}`);
      assert.strictEqual(x.calls.slice(0, firstMut).filter((c) => c.kind === "graphql").length, 2, `the checks take two gh calls: ${S.brief(x)}`);
      assert.strictEqual(S.mutations(x).length, 1, `one alias mutation writes both fields: ${S.brief(x)}`);
      const after = x.calls.slice(firstMut + 1).filter((c) => c.kind === "graphql");
      assert.ok(after.length <= 1 && after.every((c) => c.query.includes(S.INBOX_QUERY)), `only the inbox reads after the write: ${S.brief(x)}`);
      assert.ok(x.calls.every((c) => c.outcome !== "ETIMEDOUT"), S.brief(x));
      assert.strictEqual(G.pmStore()[S.itemOf(2105)], me.tag);
      assert.strictEqual(G.pmStore()[S.itemOf(3151)], me.tag);
    } finally {
      S.archive(other.sid);
      S.archive(me.sid);
      G.setPmStore({});
    }
  });
}
caseEnd();

// A small allowance for the real run time of the hook code between two virtual-clock reads.
const CLOCK_SLACK_MS = 150;

// common(x) — what every accepted run under the budget must show.
function common(x) {
  S.assertWithinHook(x);
  assert.ok(x.calls.every((c) => c.outcome !== "ETIMEDOUT"), `a forge call was killed: ${S.brief(x)}`);
}
function cleanup(sids) {
  for (const sid of sids) S.archive(sid);
  G.setPmStore({});
  G.setMap({});
}
// readsBeforeWrite(x) -> the gh GraphQL calls before the first mutation (the confirm reads; seeded cards add none).
function readsBeforeWrite(x) {
  const firstMut = x.calls.findIndex((c) => c.mutation);
  assert.ok(firstMut >= 0, `no PM field mutation: ${S.brief(x)}`);
  return x.calls.slice(0, firstMut).filter((c) => c.kind === "graphql").length;
}

caseBegin("hook-budget-e2e-other-commands", "hooks/pm-session/writer.js");
for (const ms of [400, 900]) {
  test(`C1 /pm-init with another active PM, forge calls ${ms} ms: accepted, the field written, within the hook`, () => {
    const other = S.seed({ issues: [31530], base: "PM-oth" });
    const sid = S.nextSid();
    const tag = S.nextTag("PM-init");
    P.seedState(sid);
    try {
      const x = S.respond(sid, P.wrapped("pm-init", `${tag} #31531 budget theme`), { delay: S.slow(ms) });
      S.assertAccepted(x, "init", tag);
      common(x);
      assert.strictEqual(readsBeforeWrite(x), 2, `the overlap and owner checks take two gh calls: ${S.brief(x)}`);
      assert.strictEqual(S.mutations(x).length, 1, S.brief(x));
      assert.strictEqual(G.pmStore()[S.itemOf(31531)], tag);
    } finally { cleanup([other.sid, sid]); }
  });
  test(`C2 /pm-remove of an owned issue, forge calls ${ms} ms: accepted, the field cleared, within the hook`, () => {
    const me = S.seed({ issues: [31541, 31542], owned: true });
    try {
      const x = S.respond(me.sid, P.wrapped("pm-remove", "#31542 done elsewhere"), { delay: S.slow(ms) });
      S.assertAccepted(x, "remove", me.tag);
      common(x);
      assert.strictEqual(readsBeforeWrite(x), 1, `one read gives the PM fields and the cards: ${S.brief(x)}`);
      assert.strictEqual(S.mutations(x).length, 1, S.brief(x));
      assert.ok(!G.pmStore()[S.itemOf(31542)], `the removed issue keeps its PM field: ${JSON.stringify(G.pmStore())}`);
      assert.strictEqual(G.pmStore()[S.itemOf(31541)], me.tag);
    } finally { cleanup([me.sid]); }
  });
  test(`C3 /pm-rename of a PM that owns its issues, forge calls ${ms} ms: accepted, the fields rewritten, within the hook`, () => {
    const me = S.seed({ issues: [31551, 31552], owned: true });
    const to = S.nextTag("PM-ren");
    try {
      const x = S.respond(me.sid, P.wrapped("pm-rename", to), { delay: S.slow(ms) });
      S.assertAccepted(x, "rename", to);
      common(x);
      assert.strictEqual(readsBeforeWrite(x), 1, `one read gives the PM fields and the cards: ${S.brief(x)}`);
      assert.strictEqual(S.mutations(x).length, 1, `one alias mutation rewrites both fields: ${S.brief(x)}`);
      assert.strictEqual(G.pmStore()[S.itemOf(31551)], to);
      assert.strictEqual(G.pmStore()[S.itemOf(31552)], to);
    } finally { cleanup([me.sid]); }
  });
  test(`C4 /resume-session --from, forge calls ${ms} ms: inherited with no field write, within the hook`, () => {
    const up = S.seed({ issues: [31561] });
    const down = S.nextSid();
    P.seedState(down);
    try {
      const x = S.respond(down, P.wrapped("resume-session", `--from ${up.sid}`), { delay: S.slow(ms) });
      S.assertAccepted(x, "inherit", up.tag);
      common(x);
      assert.deepStrictEqual(S.mutations(x), [], S.brief(x));
    } finally { cleanup([up.sid, down]); }
  });
}
caseEnd();

caseBegin("hook-budget-refusal-wording", "hooks/pm-session/writer.js");
const refusal = (o) => {
  const me = S.seed({ issues: [31571] });
  try {
    return S.respond(me.sid, P.wrapped("pm-add", "#31572"), o);
  } finally { cleanup([me.sid]); }
};
const killFirstRead = (c) => (c.kind === "graphql" && c.kindIndex === 0 ? 999999 : 0);
const noSpawn = (c) => (c.kind === "graphql" ? "ENOENT" : null);
test("F1 a hook that starts with its check stage already spent refuses with budget-exhausted and calls no gh", () => {
  const x = refusal({ lateMs: 8000 });
  S.assertRefusedWith(x, "budget-exhausted");
  assert.strictEqual(x.calls.filter((c) => c.kind === "graphql").length, 0, S.brief(x));
  assert.deepStrictEqual(S.ghStrays(x), [], S.brief(x));
});
test("F2 a gh call killed at its timeout refuses with the timeout wording", () => {
  const x = refusal({ delay: killFirstRead });
  S.assertRefusedWith(x, "timeout");
  assert.ok(x.calls.some((c) => c.outcome === "ETIMEDOUT"), S.brief(x));
  S.assertWithinHook(x);
});
test("F3 a gh that cannot be spawned (ENOENT) refuses with the spawn-failed wording", () => {
  const x = refusal({ fail: noSpawn });
  S.assertRefusedWith(x, "spawn-failed");
  S.assertWithinHook(x);
});
// /pm-remove (owned-only read) and /pm-rename (pending-writes read) word their refusal with nextActionOf too.
for (const [label, cmd, args, o, reason] of [
  ["/pm-remove whose owner read is killed", "pm-remove", "#31602 done", { delay: killFirstRead }, "timeout"],
  ["/pm-rename whose owner read cannot spawn gh", "pm-rename", null, { fail: noSpawn }, "spawn-failed"],
]) {
  test(`F4 ${label} refuses with the ${reason} wording and writes nothing`, () => {
    const me = S.seed({ issues: [31601, 31602], owned: true });
    try {
      const x = S.respond(me.sid, P.wrapped(cmd, args || S.nextTag("PM-ren")), o);
      S.assertRefusedWith(x, reason);
      assert.doesNotMatch(x.r.block, /retry when the forge is back/i, S.brief(x));
      assert.deepStrictEqual(S.mutations(x), [], S.brief(x));
      assert.strictEqual(G.pmStore()[S.itemOf(31602)], me.tag);
      S.assertWithinHook(x);
    } finally { cleanup([me.sid]); }
  });
}
caseEnd();

caseBegin("hook-budget-lock-wait", "hooks/pm-session/writer.js");
test("L1 a held PM lock is waited for only as long as the budget has left, not the full PM_LOCK_WAIT_MS", () => {
  const B = S.budgetMod();
  const L = P.load("hooks/pm-session/pm-lock.js");
  const LEFT_MS = 300;
  // A live holder (this process) with no start_ms: never judged gone, so no start-time spawn; fresh, so not stale.
  const file = L.lockPath();
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify({ pid: process.pid, token: "held-by-test", host: os.hostname(), at: new Date().toISOString() }));
  const me = S.seed({ issues: [31621] });
  try {
    const lateMs = B.HOOK_TIMEOUT_MS - B.SAFETY_MARGIN_MS - LEFT_MS;
    const x = S.respond(me.sid, P.wrapped("pm-add", "#31622"), { lateMs, delay: S.slow(0) });
    assert.ok(typeof x.r.block === "string" && /pm-lock-busy/.test(x.r.block), `expected a pm-lock-busy refusal: ${S.brief(x)}`);
    const ran = x.end - x.V0 - lateMs;
    assert.ok(ran < L.PM_LOCK_WAIT_MS - 500, `waited ${Math.round(ran)} ms with ${LEFT_MS} ms left (PM_LOCK_WAIT_MS ${L.PM_LOCK_WAIT_MS})`);
    assert.deepStrictEqual(S.mutations(x), [], S.brief(x));
  } finally {
    fs.rmSync(file, { force: true });
    cleanup([me.sid]);
  }
});
caseEnd();

caseBegin("hook-budget-card-stage", "hooks/pm-session/writer.js");
test("K1 an issue with no card and less than ENSURE_CARD_MIN_MS left: no card spawn, budget-exhausted naming the issue", () => {
  const me = S.seed({ issues: [31581] });
  G.setMap({ "o/r#31582": { noCard: true } });
  try {
    const delay = (c) => (c.kind === "graphql" ? (c.kindIndex === 0 ? 1500 : 900) : 0);
    const x = S.respond(me.sid, P.wrapped("pm-add", "#31582"), { delay });
    S.assertRefusedWith(x, "budget-exhausted");
    assert.ok(x.r.block.includes("#31582"), `the refusal does not name the card-less issue: ${S.brief(x)}`);
    assert.deepStrictEqual(x.calls.filter((c) => c.kind === "resolve-board" || c.kind === "ensure-card"), [], S.brief(x));
    assert.deepStrictEqual(S.mutations(x), [], S.brief(x));
    S.assertWithinHook(x);
  } finally { cleanup([me.sid]); }
});
test("K2 an issue with no card and room left: the card spawns and its re-read stay in the ensure window, the write keeps its own", () => {
  const me = S.seed({ issues: [31591] });
  G.setMap({ "o/r#31592": { noCard: true } });
  try {
    const x = S.respond(me.sid, P.wrapped("pm-add", "#31592"), { delay: S.slow(400), onEnsure: () => G.setMap({}) });
    const B = x.B;
    const W = B.WRITE_MUTATION_MS + B.WRITE_REREAD_MS;
    S.assertAccepted(x, "add", me.tag);
    common(x);
    const ensureAt = x.calls.findIndex((c) => c.kind === "resolve-board" || c.kind === "ensure-card");
    assert.ok(ensureAt > 0, `no card spawn: ${S.brief(x)}`);
    const t0 = x.calls[ensureAt - 1].end;
    const windowEnd = x.hd - B.INBOX_MS - W;
    const R = windowEnd - t0;
    assert.ok(R >= B.ENSURE_CARD_MIN_MS, `the fixture leaves R=${Math.round(R)}: ${S.brief(x)}`);
    const spawns = x.calls.filter((c) => c.kind === "resolve-board" || c.kind === "ensure-card");
    const spawnSum = spawns.reduce((a, c) => a + (Number.isFinite(c.timeout) ? c.timeout : Infinity), 0);
    assert.ok(spawnSum <= R - B.ENSURE_REREAD_MS + CLOCK_SLACK_MS, `card spawns ${spawnSum} ms > R - ${B.ENSURE_REREAD_MS}: ${S.brief(x)}`);
    const lastSpawn = x.calls.indexOf(spawns[spawns.length - 1]);
    const firstMut = x.calls.findIndex((c) => c.mutation);
    assert.ok(firstMut > lastSpawn, `no write after the card stage: ${S.brief(x)}`);
    const reread = x.calls.slice(lastSpawn + 1, firstMut).filter((c) => c.kind === "graphql");
    assert.strictEqual(reread.length, 1, `one card re-read: ${S.brief(x)}`);
    assert.ok(reread[0].start + reread[0].timeout <= windowEnd + CLOCK_SLACK_MS, `the card re-read runs past t0 + R: ${S.brief(x)}`);
    const mut = x.calls[firstMut];
    assert.ok(mut.start <= windowEnd + CLOCK_SLACK_MS, `the write starts after its window opened late: ${S.brief(x)}`);
    assert.ok(mut.timeout <= B.WRITE_MUTATION_MS, S.brief(x));
    const inWrite = x.calls.slice(firstMut).filter((c) => c.kind === "graphql" && !c.query.includes(S.INBOX_QUERY));
    assert.ok(inWrite.length <= 2, `more than two gh calls in the write window: ${S.brief(x)}`);
    assert.strictEqual(G.pmStore()[S.itemOf(31592)], me.tag);
  } finally { cleanup([me.sid]); }
});
caseEnd();
caseBegin("hook-budget-post-write-stages", "hooks/pm-session/writer.js");
require("./feat-pm-hook-budget/gap-cases").postWrite(S, cleanup, CLOCK_SLACK_MS);
caseEnd();
caseBegin("hook-budget-production-origin", "hooks/pm-session/budget.js");
require("./feat-pm-hook-budget/gap-cases").origin(S);
caseEnd();
caseBegin("hook-budget-writer-default-budget", "hooks/pm-session/writer.js");
require("./feat-pm-hook-budget/gap-cases").writerDefault(S, cleanup);
caseEnd();
