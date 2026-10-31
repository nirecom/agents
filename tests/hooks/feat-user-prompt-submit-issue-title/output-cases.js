"use strict";
// Output cases of tests/hooks/feat-user-prompt-submit-issue-title.js (#299): fail-open in run and
// in the hook process, title formatting, cwd normalization and the record caps. No case markers.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");

// H9 — run never throws, and the hook process always exits 0 with JSON on stdout.
function failOpen(F) {
  test("H9 fetchTitle throwing: run does not throw and emits no title", () => {
    const sid = F.newSid("h9"); F.seed(sid);
    const r = F.call(sid, "/wf-init #12", F.deps({ "#12": () => { throw new Error("boom"); } }));
    assert.ok(F.quiet(r), JSON.stringify(r));
  });
  test("H9 control dir is a file: no emit", () => {
    const sid = F.newSid("h9c"); F.seed(sid);
    fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.control`), "not a dir");
    const r = F.call(sid, "/wf-init #12", F.deps());
    assert.ok(F.quiet(r), JSON.stringify(r));
  });
  for (const [label, stdin] of [["garbage stdin", () => "not json"], ["empty stdin", () => ""], ["non-target prompt", () => JSON.stringify(F.input(F.newSid("h9t"), "hello"))]]) {
    test(`H9 TL2 ${label}: exit 0 and {}`, () => {
      const r = F.runHook(stdin());
      assert.strictEqual(r.code, 0, `out=${r.out} err=${r.err}`);
      assert.strictEqual(r.out, "{}", r.err);
    });
  }
  test("H9 TL2 cached title is emitted as hookSpecificOutput.sessionTitle", () => {
    const sid = F.newSid("h9e"); F.seed(sid);
    fs.mkdirSync(path.dirname(F.recordPath(sid)), { recursive: true });
    fs.writeFileSync(F.recordPath(sid), JSON.stringify({ v: 1, last_emitted: null, titles: { "#12": { title: "Cached" } }, failures: {} }));
    const r = F.runHook(JSON.stringify(F.input(sid, "/wf-init #12")));
    assert.strictEqual(r.code, 0, `out=${r.out} err=${r.err}`);
    let out = null; try { out = JSON.parse(r.out); } catch (_) { /* compared below */ }
    assert.deepStrictEqual(out, { hookSpecificOutput: { hookEventName: "UserPromptSubmit", sessionTitle: "#12 Cached" } }, `out=${r.out} err=${r.err}`);
  });
}

// H10 — "<refs> <title>", control characters and space runs collapsed, cut near 200 characters.
function formatting(F) {
  const one = (prompt, titles) => { const sid = F.newSid("h10"); F.seed(sid); return F.call(sid, prompt, F.deps(titles)); };
  test("H10 #12 Title", () => assert.strictEqual(one("/wf-init #12", { "#12": "Title" }), "#12 Title"));
  test("H10 #12 #34 Title", () => assert.strictEqual(one("/wf-init #12 #34", { "#12": "Title" }), "#12 #34 Title"));
  test("H10 cross-repo other#5 Title", () => assert.strictEqual(one("/wf-init other#5", { "other#5": "Title" }), "other#5 Title"));
  test("H10 newlines / control chars / runs of space collapse to one space", () => assert.strictEqual(one("/wf-init #12", { "#12": "a\nb\t\u0007c   d" }), "#12 a b c d"));
  // The plan says both "title cut at 200" and "whole cut at 200": accept either, never more.
  test("H10 long title is cut at 200 characters", () => {
    const long = one("/wf-init #12", { "#12": "x".repeat(500) });
    assert.strictEqual(typeof long, "string", JSON.stringify(long));
    assert.ok(long.startsWith("#12 x") && long.length >= 200 && long.length <= 204, String(long.length));
  });
}

// H13 — a POSIX drive-letter stdin cwd is normalized before git runs.
function posixCwd(F) {
  test("H13 git runs in the native neutral dir for a POSIX drive-letter stdin cwd", () => {
    const m = F.neutral.match(/^([A-Za-z]):(.*)$/);
    const posix = process.platform === "win32" && m ? `/${m[1].toLowerCase()}${m[2].replace(/\\/g, "/")}` : F.neutral;
    const d = F.realPath("https://example.com/o/r.git");
    const sid = F.newSid("h13"); F.seed(sid);
    F.call(sid, "/wf-init #12", d, posix);
    const git = d.spawnCalls.find((x) => x.cmd === "git");
    const at = git ? ((git.args || []).includes("-C") ? git.args[git.args.indexOf("-C") + 1] : git.opts && git.opts.cwd) : undefined;
    assert.strictEqual(at, F.neutral, `stdin cwd ${posix}: ${JSON.stringify(git)}`);
  });
}

// H14 — failures and titles keep the newest 20 keys; a success clears the key's failure.
function recordCaps(F) {
  test("H14 a failed fetch records failures[#12]; a later success caches and clears it", () => {
    const sid = F.newSid("h14"); F.seed(sid);
    F.call(sid, "/wf-init #12", F.deps({ "#12": null }, F.T0));
    assert.ok(((F.readRecord(sid) || {}).failures || {})["#12"], JSON.stringify(F.readRecord(sid)));
    F.call(sid, "/wf-init #12", F.deps({ "#12": "Back" }, F.T0 + 10 * F.MIN + 1));
    const rec = F.readRecord(sid) || {};
    assert.strictEqual(((rec.titles || {})["#12"] || {}).title, "Back", JSON.stringify(rec));
    assert.ok(!(rec.failures || {})["#12"], JSON.stringify(rec));
  });
  for (const [label, val] of [["titles", undefined], ["failures", null]]) {
    test(`H14 ${label}: 25 keys -> the newest 20 kept`, () => {
      const s = F.newSid("h14c"); F.seed(s);
      for (let i = 1; i <= 25; i++) F.call(s, `/wf-init #${i}`, F.deps({ [`#${i}`]: val }, F.T0 + i * 1000));
      const keys = Object.keys((F.readRecord(s) || {})[label] || {});
      assert.strictEqual(keys.length, 20, JSON.stringify(keys));
      assert.ok(keys.includes("#25") && !keys.includes("#1"), JSON.stringify(keys));
    });
  }
}

module.exports = { failOpen, formatting, posixCwd, recordCaps };
