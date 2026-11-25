"use strict";
// Time-budget and retry cases of tests/hooks/feat-user-prompt-submit-issue-title.js (#299): the
// spawn path stays inside the 10 s hook timeout, and failed fetches cool down. No case markers.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");
const { test } = require("node:test");

// load(F, rel) -> the module's exports, or {} when it does not load (the asserts name what is missing).
const load = (F, rel) => { try { return require(path.join(F.ROOT, rel)); } catch (_) { return {}; } };
// #3152: the origin read has one timeout, owned by forge-kind.js; title.js keeps no copy of its own.
const originTimeout = (F) => load(F, "bin/lib/pm-field/forge-kind.js").ORIGIN_TIMEOUT_MS;

// H4 — the constants, the settings.json registration and the real spawn path under a sleeping child.
function budget(F) {
  test("H4 ORIGIN_TIMEOUT_MS = 1000 comes from forge-kind.js, TRACKER_TIMEOUT_MS = 3000, their sum < 5000", () => {
    const c = F.constants();
    const origin = originTimeout(F);
    assert.strictEqual(origin, 1000, "bin/lib/pm-field/forge-kind.js does not export ORIGIN_TIMEOUT_MS = 1000");
    assert.ok(c.ORIGIN_TIMEOUT_MS === undefined || c.ORIGIN_TIMEOUT_MS === origin, `title.js holds its own origin timeout ${c.ORIGIN_TIMEOUT_MS}`);
    assert.strictEqual(c.TRACKER_TIMEOUT_MS, 3000);
    assert.ok(origin + c.TRACKER_TIMEOUT_MS < 5000);
  });
  test("H4 MAX_ATTEMPTS = 3, COOLDOWN_MS = 10 min", () => {
    const c = F.constants();
    assert.strictEqual(c.MAX_ATTEMPTS, 3);
    assert.strictEqual(c.COOLDOWN_MS, 10 * F.MIN);
  });
  test("H4 settings.json registers the hook under UserPromptSubmit with timeout 10", () => {
    const s = JSON.parse(fs.readFileSync(path.join(F.ROOT, "settings.json"), "utf8"));
    const hooks = ((s.hooks && s.hooks.UserPromptSubmit) || []).flatMap((g) => g.hooks || []);
    const h = hooks.find((x) => String(x.command).includes("hooks/user-prompt-submit-issue-title.js"));
    assert.ok(h, "no UserPromptSubmit entry runs hooks/user-prompt-submit-issue-title.js");
    assert.strictEqual(h.timeout, 10,JSON.stringify(h));
  });
  for (const variant of ["a: git sleeps", "b: gh sleeps"]) {
    test(`H4 ${variant}: run returns a non-string in < 4500 ms with the budgeted timeouts`, () => {
      const c = F.constants();
      const calls = [];
      const d = F.deps(); delete d.fetchTitle;
      d.spawnSync = (cmd, args, opts) => {
        calls.push({ cmd, timeout: opts && opts.timeout });
        if (variant.startsWith("b") && cmd === "git") return { status: 0, stdout: "https://github.com/o/r.git\n", stderr: "" };
        return cp.spawnSync(process.execPath, ["-e", "setTimeout(()=>{},10000)"], { encoding: "utf8", timeout: opts && opts.timeout });
      };
      const sid = F.newSid("h4"); F.seed(sid);
      const t = Date.now();
      const r = F.call(sid, "/wf-init #12", d);
      const ms = Date.now() - t;
      assert.ok(F.quiet(r), JSON.stringify(r));
      assert.ok(ms < 4500, `${ms} ms`);
      const git = calls.find((x) => x.cmd === "git");
      const origin = originTimeout(F);
      assert.ok(git && origin !== undefined && git.timeout === origin, `git timeout (forge-kind ${origin}): ${JSON.stringify(calls)}`);
      if (variant.startsWith("b")) {
        const gh = calls.find((x) => x.cmd === "gh");
        assert.ok(gh && c.TRACKER_TIMEOUT_MS !== undefined && gh.timeout === c.TRACKER_TIMEOUT_MS, `gh timeout: ${JSON.stringify(calls)}`);
      }
    });
  }
}

// H4b — #3152: respond hands run() the hook's budget as deps.budget. The tracker read runs for
// min(TRACKER_TIMEOUT_MS, budget.left()); under GH_MIN_CALL_MS left it is skipped and not counted as a
// failure, so the next prompt tries again. The writer's origin cache (input.__origin) spares a second git read.
const GH_ORIGIN = "https://github.com/o/r.git";
const GH_OK = { gh: { status: 0, stdout: "GH title\n", stderr: "" } };
// budgetAt(F, leftOf) -> {B, b, left}: a real budget on a frozen clock, set so that leftOf(B) ms remain
// (leftOf null: the clock stays at the start). left is what b.left() reports, the value run() sees.
function budgetAt(F, leftOf) {
  const B = load(F, "hooks/pm-session/budget.js");
  assert.strictEqual(typeof B.createHookBudget, "function", "hooks/pm-session/budget.js does not export createHookBudget");
  let t = 0;
  const b = B.createHookBudget({ startedAt: 0, now: () => t });
  if (leftOf) t = b.hookDeadlineAt - leftOf(B);
  return { B, b, left: b.left() };
}
function hookBudget(F) {
  test("H4b under GH_MIN_CALL_MS left: no tracker read, no failure counted; the next prompt with time reads it", () => {
    const sid = F.newSid("h4s"); F.seed(sid);
    const short = budgetAt(F, (B) => B.GH_MIN_CALL_MS - 1);
    assert.ok(short.left < short.B.GH_MIN_CALL_MS, `precondition: left ${short.left}`);
    const d = F.realPath(GH_ORIGIN, GH_OK); d.budget = short.b;
    const r = F.call(sid, "/wf-init #12", d);
    assert.ok(F.quiet(r), JSON.stringify(r));
    assert.strictEqual(F.spawned(d, "gh").length, 0, F.cmds(d));
    const rec = F.readRecord(sid);
    assert.ok(!(rec && rec.failures && Object.keys(rec.failures).length > 0), `a skip was counted: ${JSON.stringify(rec)}`);
    const full = budgetAt(F, null);
    const d2 = F.realPath(GH_ORIGIN, GH_OK); d2.budget = full.b;
    assert.strictEqual(F.call(sid, "/wf-init #12", d2), "#12 GH title", F.cmds(d2));
    const gh = F.spawned(d2, "gh");
    assert.strictEqual(gh.length, 1, F.cmds(d2));
    assert.strictEqual(gh[0].opts && gh[0].opts.timeout, Math.min(F.constants().TRACKER_TIMEOUT_MS, full.left), F.cmds(d2));
  });
  test("H4b a budget with less than TRACKER_TIMEOUT_MS left caps the tracker read at what is left", () => {
    const sid = F.newSid("h4c"); F.seed(sid);
    const tracker = F.constants().TRACKER_TIMEOUT_MS;
    const mid = budgetAt(F, (B) => Math.max(B.GH_MIN_CALL_MS, tracker - 500));
    assert.ok(mid.left >= mid.B.GH_MIN_CALL_MS && mid.left < tracker, `precondition: left ${mid.left}`);
    const d = F.realPath(GH_ORIGIN, GH_OK); d.budget = mid.b;
    assert.strictEqual(F.call(sid, "/wf-init #12", d), "#12 GH title", F.cmds(d));
    const gh = F.spawned(d, "gh");
    assert.ok(gh.length === 1 && gh[0].opts && gh[0].opts.timeout === mid.left, `want timeout ${mid.left}: ${JSON.stringify(gh.map((x) => x.opts))}`);
  });
  test("H4b the writer's cached origin (input.__origin) is reused: run() reads no git origin again", () => {
    const sid = F.newSid("h4o"); F.seed(sid);
    const d = F.realPath(GH_ORIGIN, GH_OK);
    const inp = F.input(sid, "/wf-init #12");
    Object.defineProperty(inp, "__origin", { value: GH_ORIGIN, enumerable: false });
    let r;
    try { r = require(F.ENTRY).run(inp, d); } catch (e) { r = { threw: e.message }; }
    assert.strictEqual(r, "#12 GH title", F.cmds(d));
    assert.strictEqual(F.spawned(d, "git").length, 0, `origin read again: ${F.cmds(d)}`);
  });
}

// H5 — failed fetches cool down for COOLDOWN_MS and give up after MAX_ATTEMPTS; a failed or skipped
// fetch emits no title.
function cooldown(F) {
  test("H5 failure, cooldown, retry and give-up: fetch counts and no title emitted", () => {
    const sid = F.newSid("h5"); F.seed(sid);
    const attempt = (at, prompt = "/wf-init #12") => { const d = F.deps({ "#12": null }, at); const r = F.call(sid, prompt, d); return { n: d.fetchCalls.length, r }; };
    // [label, now, prompt, fetches, emitted (null: no title)]
    const steps = [
      ["first failure fetches once", F.T0, undefined, 1, null],
      ["right after a failure: 0 fetch", F.T0 + 1000, undefined, 0, null],
      ["after 10 minutes: 1 fetch", F.T0 + 10 * F.MIN + 1, undefined, 1, null],
      ["third attempt after another 10 minutes: 1 fetch", F.T0 + 20 * F.MIN + 2, undefined, 1, null],
      ["after 3 failures: 0 fetch even much later", F.T0 + 600 * F.MIN, undefined, 0, null],
      ["a new issue set is a new key: 1 fetch", F.T0 + 600 * F.MIN, "/wf-init #77", 1, "#77 Title77"],
    ];
    for (const [label, at, prompt, want, emitted] of steps) {
      const { n, r } = attempt(at, prompt);
      assert.strictEqual(n, want, `H5 ${label}`);
      if (emitted === null) assert.ok(F.quiet(r), `H5 ${label}: emitted ${JSON.stringify(r)}`);
      else assert.strictEqual(r, emitted, `H5 ${label}`);
    }
  });
}

module.exports = { budget, hookBudget, cooldown };
