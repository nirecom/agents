"use strict";
// Scenarios of tests/hooks/feat-pm-hook-budget.js (#3152): one UserPromptSubmit run of title.js respond under
// ./world.js (virtual clock, fake spawnSync), the budget made with createHookBudget({startedAt, now}) and handed
// in as deps.budget. No case markers. Requires ./world.js to be loaded first (the caller does).
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after } = require("node:test");
const P = require("../../lib/pm-state-fixture");
const { ghEnv } = require("../../bin/feature-2941-pm-state-cli/gh-env");
const { createWorld } = require("./world");

const G = ghEnv("pm-hook-budget-gh-");
const cwd = fs.mkdtempSync(path.join(os.tmpdir(), "pm-hook-budget-cwd-"));
after(() => { G.restore(); try { fs.rmSync(cwd, { recursive: true, force: true }); } catch (_) { /* held by the OS */ } });

const GH_KINDS = new Set(["graphql", "gh-other", "resolve-board", "ensure-card"]);
const INBOX_QUERY = "subIssues(first:50)";
let n = 0;
const nextSid = () => P.uuid(0x31520000 + (++n));
const nextTag = (base) => `${base || "PM-hb"}${++n}`;
const R = (num) => ({ number: num, repo: "o/r" });
const itemOf = (num) => `PVTI_o_r_${num}`;

const budgetMod = () => P.load("hooks/pm-session/budget.js");
const failureMod = () => P.load("bin/lib/forge-failure.js");

// slow(ms) -> a delay that makes every forge-side spawn (gh, the board scripts) take ms; git is instant.
const slow = (ms) => (c) => (GH_KINDS.has(c.kind) ? ms : 0);

// seed(o) -> {sid, tag}: a PM (o.issues stored with repo o/r) whose PM field values sit in the fake store when o.owned.
function seed(o) {
  const sid = nextSid();
  const tag = nextTag(o.base);
  P.seedPm(sid, P.pm({ tag, issues: (o.issues || []).map(R) }));
  if (o.owned) G.setPmStore(Object.assign(G.pmStore(), Object.fromEntries(o.issues.map((x) => [itemOf(x), tag]))));
  return { sid, tag };
}
function archive(sid) {
  const st = P.raw(sid);
  if (st && st.pm) { st.pm.archived_at = "2026-11-25T00:00:00.000Z"; P.writeRaw(sid, st); }
}

// respond(sid, prompt, o) -> {r, V0, end, hd, calls, strays, W}: one hook run; o.lateMs starts the hook that
// long before now (a budget already spent), o.delay / o.fail / o.onEnsure go to the world.
function respond(sid, prompt, o = {}) {
  const B = budgetMod();
  assert.strictEqual(typeof B.createHookBudget, "function", "hooks/pm-session/budget.js does not export createHookBudget");
  const W = createWorld({ G, delay: o.delay || slow(400), fail: o.fail, onEnsure: o.onEnsure });
  const T = P.load("hooks/user-prompt-submit-issue-title/title.js");
  return W.run(() => {
    const V0 = W.now() - (o.lateMs || 0);
    const budget = B.createHookBudget({ startedAt: V0, now: () => W.now() });
    let r;
    try {
      r = T.respond({ session_id: sid, hook_event_name: "UserPromptSubmit", prompt, cwd }, { now: () => Math.floor(W.now()), spawnSync: W.spawnSync, budget }) || {};
    } catch (e) { r = { threw: e.message }; }
    const end = W.now();
    return { r, V0, end, hd: V0 + B.HOOK_TIMEOUT_MS - B.SAFETY_MARGIN_MS, calls: W.calls, W, B };
  });
}

const brief = (x) => JSON.stringify({ r: x.r, calls: x.calls.map((c) => `${c.kind}${c.mutation ? "(mutation)" : ""}@${Math.round(c.start - x.V0)}+${c.timeout}:${c.outcome}`) });
const ghStrays = (x) => x.W.strays().filter((s) => GH_KINDS.has(s.kind)).map((s) => s.line);
const reads = (x) => x.calls.filter((c) => c.kind === "graphql" && !c.mutation);
const mutations = (x) => x.calls.filter((c) => c.kind === "graphql" && c.mutation);

// assertWithinHook(x) — the run plus the margin the budget keeps for node start-up and exit fits the hook timeout.
function assertWithinHook(x) {
  const used = x.end - x.V0;
  assert.ok(used + x.B.SAFETY_MARGIN_MS <= x.B.HOOK_TIMEOUT_MS, `elapsed ${Math.round(used)} ms + margin ${x.B.SAFETY_MARGIN_MS} > ${x.B.HOOK_TIMEOUT_MS}: ${brief(x)}`);
  assert.deepStrictEqual(ghStrays(x), [], `a forge spawn bypassed deps.spawnSync: ${brief(x)}`);
}
function assertAccepted(x, op, tag) {
  assert.ok(!x.r.block && !x.r.threw, `expected acceptance, got ${brief(x)}`);
  const first = String(x.r.context || "").split(/\r?\n/)[0];
  if (op) assert.strictEqual(first, `[pm-session] op=${op} tag=${tag}`, brief(x));
  else assert.match(first, /^\[pm-session\] op=\S+ tag=/, brief(x));
}
// assertRefusedWith(x, reason) — a refusal whose next action is the one forge-failure.js gives for reason.
function assertRefusedWith(x, reason) {
  const F = failureMod();
  assert.strictEqual(typeof F.nextActionOf, "function", "bin/lib/forge-failure.js does not export nextActionOf");
  assert.ok(typeof x.r.block === "string" && x.r.block.length > 0, `expected a refusal, got ${brief(x)}`);
  const want = F.nextActionOf(reason);
  assert.ok(typeof want === "string" && want.length > 0, `nextActionOf(${reason}) is empty`);
  assert.ok(x.r.block.includes(want), `refusal lacks nextActionOf(${reason}) "${want}": ${brief(x)}`);
}

module.exports = {
  P, G, cwd, R, itemOf, INBOX_QUERY, nextSid, nextTag, slow, seed, archive, respond, brief, ghStrays, reads, mutations,
  assertWithinHook, assertAccepted, assertRefusedWith, budgetMod, failureMod,
};
