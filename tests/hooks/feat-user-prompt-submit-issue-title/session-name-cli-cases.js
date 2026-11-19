"use strict";
// bin/session-name cases of tests/hooks/feat-user-prompt-submit-issue-title.js (#2668, #2941 Steps 4).
// pm: `--kind pm [--session <sid>]` (CLAUDE_CODE_SESSION_ID by default; args after `--` exit 2) names
// the session from its state and its issue-title record the way the hook does, and never writes the
// record. work keeps its tag-less refs after `--`. The fake gh answers "Fake title <N>". No case markers.
const assert = require("node:assert");
const { test } = require("node:test");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const PS = require("../../lib/pm-state-fixture");
const { sfx } = require("./name-cases");

function nameOf(r) {
  if (typeof r === "string" || !r || typeof r !== "object") return r;
  if (typeof r.sessionTitle === "string") return r.sessionTitle;
  return r.hookSpecificOutput && r.hookSpecificOutput.sessionTitle;
}

function cli(F, P) {
  const issueViews = () => P.cliCalls("gh").filter((c) => c.args[0] === "issue" && c.args[1] === "view");
  const run = (args, env) => {
    const repo = P.gitRepo("https://github.com/o/r.git");
    const before = issueViews().length;
    const r = P.runBin("bin/session-name", args, { cwd: repo, env });
    return Object.assign(r, { views: issueViews().slice(before).map((c) => c.args[2]) });
  };
  // seedPmState(pmValue, rec, o) -> sid: a PM state (o.transcript as F.seed) and, when rec is given, its record.
  const seedPmState = (pmValue, rec, o = {}) => {
    const sid = crypto.randomUUID();
    F.seed(sid, o);
    const p = F.WS.getStatePath(sid);
    const st = JSON.parse(fs.readFileSync(p, "utf8"));
    st.pm = pmValue;
    fs.writeFileSync(p, JSON.stringify(st));
    if (rec) {
      fs.mkdirSync(path.dirname(F.recordPath(sid)), { recursive: true });
      fs.writeFileSync(F.recordPath(sid), JSON.stringify(Object.assign({ v: 1, last_emitted: null, titles: {}, failures: {} }, rec)));
    }
    return sid;
  };
  const bytes = (sid) => { try { return fs.readFileSync(F.recordPath(sid), "utf8"); } catch (_) { return null; } };

  test("N5 --kind pm --session uses the recorded title, asks no forge, and agrees with the hook", () => {
    const sid = seedPmState(PS.pm({ issues: [123, 456] }), { titles: { "#123": { title: "Rec title" } } });
    const before = bytes(sid);
    const r = run(["--kind", "pm", "--session", sid]);
    assert.strictEqual(r.code, 0, r.err);
    assert.strictEqual(r.out.trim(), `[PM] PM-infra: #123 #456 Rec title${sfx(sid)}`, r.err);
    assert.deepStrictEqual(r.views, []);
    assert.strictEqual(bytes(sid), before, "the CLI wrote the record");
    assert.strictEqual(nameOf(F.call(sid, "hello", F.deps())), r.out.trim(), "the hook names it differently");
  });
  test("N5 --kind pm without a recorded title asks the forge for #A only and leaves the record absent", () => {
    const sid = seedPmState(PS.pm({ issues: [123, 456] }));
    const r = run(["--kind", "pm", "--session", sid]);
    assert.strictEqual(r.code, 0, r.err);
    assert.strictEqual(r.out.trim(), `[PM] PM-infra: #123 #456 Fake title 123${sfx(sid)}`, r.err);
    assert.deepStrictEqual(r.views, ["123"]);
    assert.strictEqual(bytes(sid), null, "the CLI wrote the record");
  });
  test("N5 --kind pm after MAX_ATTEMPTS failures falls back to the objective without a forge call", () => {
    const sid = seedPmState(PS.pm({ issues: [123], objective: "objective" }), { failures: { "#123": { attempts: 3, last_failed_at: Date.now() } } });
    const r = run(["--kind", "pm", "--session", sid]);
    assert.strictEqual(r.code, 0, r.err);
    assert.strictEqual(r.out.trim(), `[PM] PM-infra: objective${sfx(sid)}`, r.err);
    assert.deepStrictEqual(r.views, []);
  });
  test("N5 --kind pm with no fetchable title and no objective exits 1 and prints no name", () => {
    const sid = seedPmState(PS.pm({ issues: [123], objective: null }), { failures: { "#123": { attempts: 3, last_failed_at: Date.now() } } });
    const r = run(["--kind", "pm", "--session", sid]);
    assert.strictEqual(r.code, 1, `out=${r.out} err=${r.err}`);
    assert.strictEqual(r.out, "");
    assert.deepStrictEqual(r.views, []);
  });
  test("N5 --kind pm with neither --session nor CLAUDE_CODE_SESSION_ID exits 2", () => {
    const r = run(["--kind", "pm"], { CLAUDE_CODE_SESSION_ID: null });
    assert.strictEqual(r.code, 2, `out=${r.out} err=${r.err}`);
    assert.strictEqual(r.out, "");
  });
  test("N5 --kind pm without --session takes CLAUDE_CODE_SESSION_ID", () => {
    const sid = seedPmState(PS.pm({ issues: [], objective: "default session" }));
    const r = run(["--kind", "pm"], { CLAUDE_CODE_SESSION_ID: sid });
    assert.strictEqual(r.code, 0, r.err);
    assert.strictEqual(r.out.trim(), `[PM] PM-infra: default session${sfx(sid)}`, r.err);
  });
  for (const [label, make] of [
    ["a session without the PM mark", () => { const s = crypto.randomUUID(); F.seed(s); return s; }],
    ["an unconfirmed root (recordSid null: no transcript)", () => seedPmState(PS.pm({ issues: [], objective: "x" }), null, { transcript: null })],
  ]) {
    test(`N5 --kind pm for ${label} exits 1 and prints no name`, () => {
      const r = run(["--kind", "pm", "--session", make()]);
      assert.strictEqual(r.code, 1, `out=${r.out} err=${r.err}`);
      assert.strictEqual(r.out.trim(), "");
    });
  }
  test("N5 --kind pm with arguments after -- exits 2", () => {
    const sid = seedPmState(PS.pm({ issues: [] }));
    const r = run(["--kind", "pm", "--session", sid, "--", "PM-infra", "#123"]);
    assert.strictEqual(r.code, 2, `out=${r.out} err=${r.err}`);
  });
  test("N5 --kind work -- #123 #456 is unchanged (no tag consumed)", () => {
    const r = run(["--kind", "work", "--", "#123", "#456"]);
    assert.strictEqual(r.code, 0, r.err);
    assert.strictEqual(r.out.trim(), "#123 #456 Fake title 123", r.err);
    assert.deepStrictEqual(r.views, ["123"]);
  });
  test("N5 --kind work with an owner/repo#N ref first is unchanged", () => {
    const r = run(["--kind", "work", "--", "o/r#123", "#456"]);
    assert.strictEqual(r.code, 0, r.err);
    assert.strictEqual(r.out.trim(), "o/r#123 #456 Fake title 123", r.err);
  });
  test("N5 --kind work with zero refs still exits 1", () => {
    const r = run(["--kind", "work", "--", "PM-infra", "words"]);
    assert.strictEqual(r.code, 1, `out=${r.out} err=${r.err}`);
  });
  test("N5 bin/session-name --kind bogus exits 2", () => {
    assert.ok(fs.existsSync(path.join(F.ROOT, "bin", "session-name")), "bin/session-name is missing");
    const r = P.runBin("bin/session-name", ["--kind", "bogus", "--", "x"]);
    assert.strictEqual(r.code, 2, `code=${r.code} out=${r.out} err=${r.err}`);
    assert.strictEqual(r.out, "");
  });
}

module.exports = { cli };
