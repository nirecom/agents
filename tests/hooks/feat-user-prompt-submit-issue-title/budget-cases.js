"use strict";
// Time-budget and retry cases of tests/hooks/feat-user-prompt-submit-issue-title.js (#299): the
// spawn path stays inside the 5 s hook timeout, and failed fetches cool down. No case markers.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");
const { test } = require("node:test");

// H4 — the constants, the settings.json registration and the real spawn path under a sleeping child.
function budget(F) {
  test("H4 ORIGIN_TIMEOUT_MS = 1000, TRACKER_TIMEOUT_MS = 3000, their sum < 5000", () => {
    const c = F.constants();
    assert.strictEqual(c.ORIGIN_TIMEOUT_MS, 1000);
    assert.strictEqual(c.TRACKER_TIMEOUT_MS, 3000);
    assert.ok(c.ORIGIN_TIMEOUT_MS + c.TRACKER_TIMEOUT_MS < 5000);
  });
  test("H4 MAX_ATTEMPTS = 3, COOLDOWN_MS = 10 min", () => {
    const c = F.constants();
    assert.strictEqual(c.MAX_ATTEMPTS, 3);
    assert.strictEqual(c.COOLDOWN_MS, 10 * F.MIN);
  });
  test("H4 settings.json registers the hook under UserPromptSubmit with timeout 5", () => {
    const s = JSON.parse(fs.readFileSync(path.join(F.ROOT, "settings.json"), "utf8"));
    const hooks = ((s.hooks && s.hooks.UserPromptSubmit) || []).flatMap((g) => g.hooks || []);
    const h = hooks.find((x) => String(x.command).includes("hooks/user-prompt-submit-issue-title.js"));
    assert.ok(h, "no UserPromptSubmit entry runs hooks/user-prompt-submit-issue-title.js");
    assert.strictEqual(h.timeout, 5, JSON.stringify(h));
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
      assert.ok(git && c.ORIGIN_TIMEOUT_MS !== undefined && git.timeout === c.ORIGIN_TIMEOUT_MS, `git timeout: ${JSON.stringify(calls)}`);
      if (variant.startsWith("b")) {
        const gh = calls.find((x) => x.cmd === "gh");
        assert.ok(gh && c.TRACKER_TIMEOUT_MS !== undefined && gh.timeout === c.TRACKER_TIMEOUT_MS, `gh timeout: ${JSON.stringify(calls)}`);
      }
    });
  }
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

module.exports = { budget, cooldown };
