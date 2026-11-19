"use strict";
// Session-name cases of tests/hooks/feat-user-prompt-submit-issue-title.js (#2668): the name a
// session gets for find-peer to look it up — work "#A[ #B] <title of #A> sid-xxxxxxxx", pm (#2941)
// "[PM] <tag>: #A #B <title of #A | objective when 0 refs> sid-xxxxxxxx", none "<repo> sid-xxxxxxxx".
// Assumed API of hooks/lib/session-name.js: composeSessionName({kind, tag, refs, title, repo, sessionId})
// -> string (pure; refs are {number, repo?}); sessionSuffix(id); splitLeadingRefs(text) -> {refs, rest};
// parsePmInitArgs(args) -> {tag, refs, objective}; parsePmAssignArgs(args) -> {refs, reason};
// SESSION_NAME_SUFFIX_RE, PM_NAME_PREFIX_RE. The bin/session-name cases: ./session-name-cli-cases.js.
// No case markers.
const assert = require("node:assert");
const { test } = require("node:test");
const crypto = require("node:crypto");
const path = require("node:path");

const sfx = (sid) => ` sid-${sid.slice(0, 8).toLowerCase()}`;
const refStr = (refs) => (refs || []).map((r) => `${r.repo || ""}#${r.number}`);
const lib = (F) => require(path.join(F.ROOT, "hooks", "lib", "session-name.js"));
const fn = (F, name) => {
  const f = lib(F)[name];
  assert.strictEqual(typeof f, "function", `session-name.${name} is missing`);
  return f;
};

// N1 — composeSessionName renders every kind; the issue numbers and the suffix are never cut.
function compose(F) {
  const U = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d";
  const rows = [
    ["work, two refs", { kind: "work", refs: [{ number: 12 }, { number: 34 }], title: "Fix it", sessionId: U }, "#12 #34 Fix it sid-1a2b3c4d"],
    ["work, a ref of another repo", { kind: "work", refs: [{ repo: "other", number: 5 }], title: "T", sessionId: U }, "other#5 T sid-1a2b3c4d"],
    ["pm, tag and three refs", { kind: "pm", tag: "PM-infra", refs: [{ number: 123 }, { number: 456 }, { number: 789 }], title: "Objective", sessionId: U }, "[PM] PM-infra: #123 #456 #789 Objective sid-1a2b3c4d"],
    ["pm, tag and zero refs (objective as title)", { kind: "pm", tag: "PM-infra", refs: [], title: "theme", sessionId: U }, "[PM] PM-infra: theme sid-1a2b3c4d"],
    ["none", { kind: "none", repo: "agents", sessionId: U }, "agents sid-1a2b3c4d"],
    ["a non-UUID session id gets no suffix", { kind: "work", refs: [{ number: 12 }], title: "Fix it", sessionId: "it-x-1" }, "#12 Fix it"],
    ["no session id gets no suffix", { kind: "none", repo: "agents" }, "agents"],
    ["an upper-case UUID gives a lower-case suffix", { kind: "work", refs: [{ number: 12 }], title: "Fix it", sessionId: U.toUpperCase() }, "#12 Fix it sid-1a2b3c4d"],
    ["control characters in the title collapse to one space", { kind: "work", refs: [{ number: 12 }], title: "a\tb\n\nc\u0007d", sessionId: U }, "#12 a b c d sid-1a2b3c4d"],
  ];
  for (const [label, input, want] of rows) {
    test(`N1 composeSessionName ${label}`, () => assert.strictEqual(lib(F).composeSessionName(input), want));
  }
  test("N1 composeSessionName cuts a 500-char title at 200 and keeps the number and the suffix", () => {
    const r = lib(F).composeSessionName({ kind: "work", refs: [{ number: 12 }], title: "x".repeat(500), sessionId: U });
    assert.strictEqual(r, `#12 ${"x".repeat(200)} sid-1a2b3c4d`);
  });
  test("N1 composeSessionName is pure: the input is not mutated and two calls agree", () => {
    const input = Object.freeze({ kind: "pm", tag: "PM-a", refs:Object.freeze([Object.freeze({ number: 1 })]), title: "T", sessionId: U });
    const a = lib(F).composeSessionName(input);
    assert.strictEqual(lib(F).composeSessionName(input), a);
  });
  for (const [label, id, want] of [["a UUID", U, " sid-1a2b3c4d"], ["an upper-case UUID", U.toUpperCase(), " sid-1a2b3c4d"], ["a non-UUID id", "it-x-1", ""], ["no id", undefined, ""]]) {
    test(`N1 sessionSuffix of ${label} is ${JSON.stringify(want)}`, () => assert.strictEqual(lib(F).sessionSuffix(id), want));
  }
}

// N2 — the suffix and the PM prefix regexes accept exactly the composed shapes.
function regexes(F) {
  for (const [label, s, want] of [
    ["a composed name", "#12 Fix it sid-1a2b3c4d", "1a2b3c4d"],
    ["the retired bracket form", "#12 Fix it [1a2b3c4d]", null],
    ["the retired bracket form, digits only", "x [12345678]", null],
    ["upper-case hex", "x sid-1A2B3C4D", null],
    ["an upper-case SID-", "x SID-1a2b3c4d", null],
    ["no space before sid-", "xsid-1a2b3c4d", null],
    ["7 hex digits", "x sid-1a2b3c4", null],
    ["9 hex digits", "x sid-1a2b3c4d5", null],
    ["a trailing space", "x sid-1a2b3c4d ", null],
    ["a trailing newline", "x sid-1a2b3c4d\n", null],
    ["a non-hex digit", "x sid-1a2b3c4g", null],
    ["not at the end", "x sid-1a2b3c4d more", null],
  ]) {
    test(`N2 SESSION_NAME_SUFFIX_RE ${label}`, () => {
      const m = String(s).match(lib(F).SESSION_NAME_SUFFIX_RE);
      assert.strictEqual(m ? m[1] : null, want);
    });
  }
  for (const [label, s, want] of [
    ["[PM] + space", "[PM] #1 T", true],
    ["the #2941 tagged shape", "[PM] PM-infra: #1 T sid-1a2b3c4d", true],
    ["lower-case [pm]", "[pm] #1 T", false],
    ["no space after [PM]", "[PM]#1 T", false],
    ["a leading space", " [PM] #1 T", false],
    ["[PM] alone", "[PM]", false],
  ]) {
    test(`N2 PM_NAME_PREFIX_RE ${label}`, () => assert.strictEqual(lib(F).PM_NAME_PREFIX_RE.test(s), want));
  }
}

// N3 — the argument split (#2941 Steps 3): only the refs at the head are assigned; the rest stays
// verbatim (its #N included) as the theme or the reason. Empty theme / reason = falsy.
function pmArgs(F) {
  for (const [label, args, tag, refs, objective] of [
    ["tag, two refs and a theme", "PM-infra #2728 #2927 theme", "PM-infra", ["#2728", "#2927"], "theme"],
    ["tag and refs only", "PM-infra #2728 #2927", "PM-infra", ["#2728", "#2927"], undefined],
    ["tag only", "PM-infra", "PM-infra", [], undefined],
    ["tag and a theme only", "PM-infra theme only", "PM-infra", [], "theme only"],
    ["tag and comma-separated refs", "PM-a #123,#456", "PM-a", ["#123", "#456"], undefined],
    ["tag and a ref of another repo", "PM-a other#5", "PM-a", ["other#5"], undefined],
    ["an array of words (the CLI form)", ["PM-a", "#1", "Ship", "it"], "PM-a", ["#1"], "Ship it"],
    ["a #N inside the theme stays in the theme", "PM-x groundwork, migration #12", "PM-x", [], "groundwork, migration #12"],
    ["a #N after the theme is not a ref", "PM-x theme #12", "PM-x", [], "theme #12"],
    ["refs with a comma and a theme with an em dash", "PM-x #1, #2 theme—continued", "PM-x", ["#1", "#2"], "theme—continued"],
  ]) {
    test(`N3 parsePmInitArgs ${label}`, () => {
      const r = lib(F).parsePmInitArgs(args);
      assert.strictEqual(r.tag, tag, JSON.stringify(r));
      assert.deepStrictEqual(refStr(r.refs), refs);
      if (objective === undefined) assert.ok(!r.objective, JSON.stringify(r));
      else assert.strictEqual(r.objective, objective);
    });
  }
  const why = "PM and EM work closely together—merged for the same reason as #2927, as agreed";
  for (const [label, text, refs, rest] of [
    ["refs then words", "#1 #2 reason", ["#1", "#2"], "reason"],
    ["comma-separated refs then words", "#1, #2 reason", ["#1", "#2"], "reason"],
    ["refs only", "#1,#2", ["#1", "#2"], ""],
    ["a word first", "reason #3", [], "reason #3"],
    ["a reason holding a #N, an em dash and a comma", `#123 ${why}`, ["#123"], why],
    ["inner spacing kept, ends trimmed", "  #1   a,  b  ", ["#1"], "a,  b"],
    ["an owner/repo ref", "o/r#5 x", ["o/r#5"], "x"],
    ["empty text", "", [], ""],
  ]) {
    test(`N3 splitLeadingRefs ${label}`, () => {
      const r = fn(F, "splitLeadingRefs")(text);
      assert.deepStrictEqual(refStr(r.refs), refs, JSON.stringify(r));
      if (rest === "") assert.ok(!r.rest, JSON.stringify(r));
      else assert.strictEqual(r.rest, rest);
    });
  }
  for (const [label, args, refs, reason] of [
    ["a reason kept verbatim", `#123 ${why}`, ["#123"], why],
    ["two refs and a reason", "#1, #2 reason", ["#1", "#2"], "reason"],
    ["no reason", "#1", ["#1"], ""],
    ["no argument", "", [], ""],
  ]) {
    test(`N3 parsePmAssignArgs ${label}`, () => {
      const r = fn(F, "parsePmAssignArgs")(args);
      assert.deepStrictEqual(refStr(r.refs), refs, JSON.stringify(r));
      if (reason === "") assert.ok(!r.reason, JSON.stringify(r));
      else assert.strictEqual(r.reason, reason);
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

module.exports = { compose, regexes, pmArgs, hookNames, sfx };
