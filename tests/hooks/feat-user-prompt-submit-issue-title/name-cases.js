"use strict";
// Session-name cases of tests/hooks/feat-user-prompt-submit-issue-title.js (#2668): the name a
// session gets for find-peer to look it up — work "#A[ #B] <title of #A> [xxxxxxxx]", pm
// "[PM] #A #B #C <objective | title of #A> [xxxxxxxx]", none "<repo> [xxxxxxxx]".
// Assumed API of hooks/lib/session-name.js: composeSessionName({kind, refs, title, repo, sessionId})
// -> string (pure; refs are {number, repo?}); parsePmInitArgs(args) -> {refs, objective};
// SESSION_NAME_SUFFIX_RE, PM_NAME_PREFIX_RE. CLI: bin/session-name --kind work|pm|none
// [--session <sid>] -- <args>, the name on stdout. No case markers.
const assert = require("node:assert");
const { test } = require("node:test");
const crypto = require("node:crypto");
const path = require("node:path");

const sfx = (sid) => ` [${sid.slice(0, 8).toLowerCase()}]`;
const refStr = (refs) => (refs || []).map((r) => `${r.repo || ""}#${r.number}`);
const lib = (F) => require(path.join(F.ROOT, "hooks", "lib", "session-name.js"));

// N1 — composeSessionName renders every kind; the issue numbers and the suffix are never cut.
function compose(F) {
  const U = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d";
  const rows = [
    ["work, two refs", { kind: "work", refs: [{ number: 12 }, { number: 34 }], title: "Fix it", sessionId: U }, "#12 #34 Fix it [1a2b3c4d]"],
    ["work, a ref of another repo", { kind: "work", refs: [{ repo: "other", number: 5 }], title: "T", sessionId: U }, "other#5 T [1a2b3c4d]"],
    ["pm, three refs", { kind: "pm", refs: [{ number: 123 }, { number: 456 }, { number: 789 }], title: "Objective", sessionId: U }, "[PM] #123 #456 #789 Objective [1a2b3c4d]"],
    ["none", { kind: "none", repo: "agents", sessionId: U }, "agents [1a2b3c4d]"],
    ["a non-UUID session id gets no suffix", { kind: "work", refs: [{ number: 12 }], title: "Fix it", sessionId: "it-x-1" }, "#12 Fix it"],
    ["no session id gets no suffix", { kind: "none", repo: "agents" }, "agents"],
    ["an upper-case UUID gives a lower-case suffix", { kind: "work", refs: [{ number: 12 }], title: "Fix it", sessionId: U.toUpperCase() }, "#12 Fix it [1a2b3c4d]"],
    ["control characters in the title collapse to one space", { kind: "work", refs: [{ number: 12 }], title: "a\tb\n\nc\u0007d", sessionId: U }, "#12 a b c d [1a2b3c4d]"],
  ];
  for (const [label, input, want] of rows) {
    test(`N1 composeSessionName ${label}`, () => assert.strictEqual(lib(F).composeSessionName(input), want));
  }
  test("N1 composeSessionName cuts a 500-char title at 200 and keeps the number and the suffix", () => {
    const r = lib(F).composeSessionName({ kind: "work", refs: [{ number: 12 }], title: "x".repeat(500), sessionId: U });
    assert.strictEqual(r, `#12 ${"x".repeat(200)} [1a2b3c4d]`);
  });
  test("N1 composeSessionName is pure: the input is not mutated and two calls agree", () => {
    const input = Object.freeze({ kind: "pm", refs: Object.freeze([Object.freeze({ number: 1 })]), title: "T", sessionId: U });
    const a = lib(F).composeSessionName(input);
    assert.strictEqual(lib(F).composeSessionName(input), a);
  });
}

// N2 — the suffix and the PM prefix regexes accept exactly the composed shapes.
function regexes(F) {
  for (const [label, s, want] of [
    ["a composed name", "#12 Fix it [1a2b3c4d]", "1a2b3c4d"],
    ["upper-case hex", "x [1A2B3C4D]", null],
    ["no space before the bracket", "x[1a2b3c4d]", null],
    ["7 hex digits", "x [1a2b3c4]", null],
    ["9 hex digits", "x [1a2b3c4d5]", null],
    ["a trailing space", "x [1a2b3c4d] ", null],
    ["a trailing newline", "x [1a2b3c4d]\n", null],
    ["a non-hex digit", "x [1a2b3c4g]", null],
    ["not at the end", "x [1a2b3c4d] more", null],
  ]) {
    test(`N2 SESSION_NAME_SUFFIX_RE ${label}`, () => {
      const m = String(s).match(lib(F).SESSION_NAME_SUFFIX_RE);
      assert.strictEqual(m ? m[1] : null, want);
    });
  }
  for (const [label, s, want] of [
    ["[PM] + space", "[PM] #1 T", true],
    ["lower-case [pm]", "[pm] #1 T", false],
    ["no space after [PM]", "[PM]#1 T", false],
    ["a leading space", " [PM] #1 T", false],
    ["[PM] alone", "[PM]", false],
  ]) {
    test(`N2 PM_NAME_PREFIX_RE ${label}`, () => assert.strictEqual(lib(F).PM_NAME_PREFIX_RE.test(s), want));
  }
}

// N3 — /pm-init arguments split into refs and an objective.
function pmArgs(F) {
  for (const [label, args, refs, objective] of [
    ["an objective only", "Ship the thing", [], "Ship the thing"],
    ["refs only", "#123 #456", ["#123", "#456"], undefined],
    ["comma-separated refs", "#123,#456", ["#123", "#456"], undefined],
    ["a ref of another repo", "other#5", ["other#5"], undefined],
    ["refs and words", "#123 Ship it", ["#123"], null],
  ]) {
    test(`N3 parsePmInitArgs ${label}`, () => {
      const r = lib(F).parsePmInitArgs(args);
      assert.deepStrictEqual(refStr(r.refs), refs);
      if (objective === undefined) assert.ok(!r.objective, JSON.stringify(r));
      else if (objective !== null) assert.strictEqual(r.objective, objective);
    });
  }
}

// N4 — the hook gives a UUID session its name, the none name once, and never overwrites a name.
function hookNames(F) {
  const seeded = () => { const sid = crypto.randomUUID(); F.seed(sid); return sid; };
  test("N4 /wf-init #12 on a UUID session emits the work name with the suffix", () => {
    const sid = seeded();
    assert.strictEqual(F.call(sid, "/wf-init #12", F.deps()), `#12 Title12${sfx(sid)}`);
  });
  for (const [origin, repo] of [["https://github.com/o/myrepo.git", "myrepo"], ["https://gitlab.com/g/sub/proj.git", "proj"], ["git@github.com:o/r2.git", "r2"]]) {
    test(`N4 no refs: the none name from origin ${origin}, git within 1000 ms, no gh / glab`, () => {
      const sid = seeded();
      const d = F.realPath(origin);
      assert.strictEqual(F.call(sid, "hello", d), `${repo}${sfx(sid)}`);
      const git = F.spawned(d, "git");
      assert.ok(git.length >= 1 && git.every((g) => g.opts && g.opts.timeout === 1000), JSON.stringify(git.map((g) => g.opts)));
      assert.strictEqual(F.spawned(d, "gh").length + F.spawned(d, "glab").length, 0, F.cmds(d));
    });
  }
  test("N4 the none name is emitted once", () => {
    const sid = seeded();
    assert.strictEqual(F.call(sid, "hello", F.deps()), `neutral${sfx(sid)}`);
    const r = F.call(sid, "hello again", F.deps());
    assert.ok(F.quiet(r), JSON.stringify(r));
  });
  test("N4 the none name never overwrites an emitted name (a /rename stays)", () => {
    const sid = seeded();
    F.call(sid, "/wf-init #12", F.deps());
    const r = F.call(sid, "hello", F.deps());
    assert.ok(F.quiet(r), JSON.stringify(r));
    assert.strictEqual((F.readRecord(sid) || {}).last_emitted, `#12 Title12${sfx(sid)}`);
  });
  test("N4 a later /wf-init #12 replaces the none name with the work name", () => {
    const sid = seeded();
    F.call(sid, "hello", F.deps());
    assert.strictEqual(F.call(sid, "/wf-init #12", F.deps()), `#12 Title12${sfx(sid)}`);
  });
  test("N4 a session without state gets the none name once, recorded in its own control dir", () => {
    const sid = crypto.randomUUID();
    assert.strictEqual(F.call(sid, "hello", F.deps()), `neutral${sfx(sid)}`);
    assert.strictEqual((F.readRecord(sid) || {}).last_emitted, `neutral${sfx(sid)}`, JSON.stringify(F.readRecord(sid)));
    assert.ok(F.quiet(F.call(sid, "hello", F.deps())));
  });
  test("N4 a session without state that sends /workflow-init #12 gets the work name", () => {
    const sid = crypto.randomUUID();
    assert.strictEqual(F.call(sid, "/workflow-init #12", F.deps()), `#12 Title12${sfx(sid)}`);
  });
  test("N4 /wf-init #12 #34 fetches #12 only", () => {
    const sid = seeded();
    const d = F.deps();
    assert.strictEqual(F.call(sid, "/wf-init #12 #34", d), `#12 #34 Title12${sfx(sid)}`);
    assert.deepStrictEqual(d.fetchCalls.map((r) => r.number), [12]);
  });
}

// N5 — bin/session-name: pm fetches the title of #A only, an objective fetches nothing.
function cli(F, P) {
  const issueViews = () => P.cliCalls("gh").filter((c) => c.args[0] === "issue" && c.args[1] === "view");
  test("N5 bin/session-name --kind pm with three refs fetches #123 only", () => {
    const repo = P.gitRepo("https://github.com/o/r.git");
    const before = issueViews().length;
    const r = P.runBin("bin/session-name", ["--kind", "pm", "--", "#123", "#456", "#789"], { cwd: repo });
    assert.strictEqual(r.code, 0, r.err);
    assert.strictEqual(r.out.trim(), "[PM] #123 #456 #789 Fake title 123", r.err);
    const views = issueViews().slice(before);
    assert.deepStrictEqual(views.map((c) => c.args[2]), ["123"], JSON.stringify(views));
  });
  test("N5 bin/session-name --kind pm with an objective fetches nothing", () => {
    const repo = P.gitRepo("https://github.com/o/r.git");
    const before = issueViews().length;
    const sid = crypto.randomUUID();
    const r = P.runBin("bin/session-name", ["--kind", "pm", "--session", sid, "--", "#123", "Ship", "it"], { cwd: repo });
    assert.strictEqual(r.code, 0, r.err);
    assert.strictEqual(r.out.trim(), `[PM] #123 Ship it${sfx(sid)}`, r.err);
    assert.strictEqual(issueViews().length - before, 0);
  });
  test("N5 bin/session-name --kind bogus exits non-zero", () => {
    assert.ok(require("node:fs").existsSync(path.join(F.ROOT, "bin", "session-name")), "bin/session-name is missing");
    const r = P.runBin("bin/session-name", ["--kind", "bogus", "--", "x"]);
    assert.ok(r.code !== 0 && r.code !== null && r.code !== 127, `code=${r.code} out=${r.out}`);
  });
}

module.exports = { compose, regexes, pmArgs, hookNames, cli };
