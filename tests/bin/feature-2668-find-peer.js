"use strict";
// Tests: bin/find-peer, bin/find-peer.d/main.js, bin/find-peer.d/destination-policy.js, bin/find-peer.d/agents-list.js, bin/find-peer.d/holder.js, bin/find-peer.d/origin.js
// Tags: TL1, TL2, scope:issue-specific, issue-2668, find-peer, cross-session, sendmessage
// #2668: find-peer resolves the SendMessage destination of an issue's working (WIP holder) or
// origin session, or of a session id, and never guesses. Assumed API: bin/find-peer.d/main.js
// run(argv, deps) -> {code, stdout}; deps = {policy (overrides the destination-policy constant),
// readHolder(issue, repo) -> id | "" (throws on failure), readIssueBody(issue, repo) -> string |
// null (throws on failure), resolveSelf() -> id}; destination-policy.js exports DESTINATION_KIND.
// Exit codes: the detail plan's find-peer contract. FP6 feeds the output of
// bin/github-issues/lib/origin-session.sh to origin.js to pin one marker format.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");
const { agentsListText, realAgentsListText, REAL_OWN_LINE, REAL_OWN_LINE_NO_SUFFIX, uuid, parseKv, makeFixtures, load, tmpRoot } = require("./feature-2668-find-peer/fixtures");

// TL3 gap: the real ListAgents dump and a real SendMessage delivery to the returned destination
// are not exercised (ListAgents and SendMessage are model tools; FP10 feeds a hand-built dump in the
// row format observed on Claude Code 2.1.319, fixtures.realAgentsListText), nor real
// gh / glab against a live forge. Closest-to-action mitigation: verification (a)(b) of the detail
// plan, run by hand before release and recorded in docs/architecture/cross-session-messaging.md.

const restore = isolate();
const tmp = tmpRoot();
const P = makeFixtures(tmp);
after(() => { fs.rmSync(tmp, { recursive: true, force: true }); restore(); });

const main = load("bin/find-peer.d/main.js");
const U = uuid("1a2b3c4d");
const U_TWIN = uuid("1a2b3c4d");
const OTHER = uuid("9f8e7d6c");
const sfx = (sid) => ` [${sid.slice(0, 8)}]`;

// run(argv, o) -> {code, kv, out, holderCalls, bodyCalls}; o.holder / o.body are a value or a
// function (a function may throw); o.list writes an --agents-file from entries (or raw text).
function run(argv, o = {}) {
  const calls = { holder: [], body: [] };
  const answer = (v, args) => (typeof v === "function" ? v(...args) : v);
  const deps = {
    policy: o.policy || "session-id",
    readHolder: (...a) => { calls.holder.push(a); return answer(o.holder === undefined ? "" : o.holder, a); },
    readIssueBody: (...a) => { calls.body.push(a); return answer(o.body === undefined ? null : o.body, a); },
    resolveSelf: () => answer(o.self === undefined ? U : o.self, []),
  };
  const args = argv.slice();
  if (o.list !== undefined) args.push("--agents-file", P.writeFile("agents.txt", typeof o.list === "string" ? o.list : agentsListText(o.list)));
  const r = main.run(args, deps);
  return { code: r.code, out: r.stdout, kv: parseKv(r.stdout), holderCalls: calls.holder, bodyCalls: calls.body };
}
const ok = (r, want) => {
  assert.strictEqual(r.code, 0, r.out);
  for (const [k, v] of Object.entries(want)) assert.strictEqual(r.kv[k], v, `${k} in ${r.out}`);
  assert.strictEqual((r.kv.SESSION_ID_all || []).length, 1, r.out);
};
const failed = (r, code, reason) => {
  assert.strictEqual(r.code, code, r.out);
  assert.strictEqual(r.kv.REASON, reason, r.out);
  assert.strictEqual(r.kv.DESTINATION, undefined, `a guessed destination: ${r.out}`);
};

caseBegin("FP1 the destination policy is one of the three kinds and branch 1 needs no list", "bin/find-peer.d/destination-policy.js");
test("FP1 DESTINATION_KIND is session-id, ref or name", () => {
  const { DESTINATION_KIND } = require(path.join(P.ROOT, "bin", "find-peer.d", "destination-policy.js"));
  assert.ok(["session-id", "ref", "name"].includes(DESTINATION_KIND), String(DESTINATION_KIND));
});
test("FP1 branch 1 (session-id): the holder id is the destination, no list read", () => {
  ok(run(["--issue", "42"], { holder: U }), { ROLE: "working", SESSION_ID: U, DESTINATION: U, DESTINATION_KIND: "session-id" });
});
caseEnd();

caseBegin("FP2 branch 2 (ref) resolves the [ref] the list maps to the session id", "bin/find-peer.d/agents-list.js");
test("FP2 ref: found", () => {
  const r = run(["--issue", "42"], { policy: "ref", holder: U, list: [{ ref: "r9", name: "x", sessionId: OTHER }, { ref: "r1", name: "y", sessionId: U }] });
  ok(r, { ROLE: "working", SESSION_ID: U, DESTINATION_KIND: "ref" });
  assert.ok(["r1", "[r1]"].includes(r.kv.DESTINATION), r.out);
});
test("FP2 ref: the session is not in the list -> 5 not-in-list", () => {
  failed(run(["--issue", "42"], { policy: "ref", holder: U, list: [{ ref: "r9", name: "x", sessionId: OTHER }] }), 5, "not-in-list");
});
test("FP2 ref: two entries for the session -> 6 ambiguous", () => {
  failed(run(["--issue", "42"], { policy: "ref", holder: U, list: [{ ref: "r1", name: "x", sessionId: U }, { ref: "r2", name: "y", sessionId: U }] }), 6, "ambiguous");
});
caseEnd();

caseBegin("FP3 branch 3 (name) accepts only a name whose suffix is the first 8 hex digits of the session", "bin/find-peer.d/agents-list.js");
test("FP3 name: found by the suffix", () => {
  const name = `#42 Fix it${sfx(U)}`;
  ok(run(["--issue", "42"], { policy: "name", holder: U, list: [{ ref: "r9", name: `#7 Other${sfx(OTHER)}` }, { ref: "r1", name }] }), { SESSION_ID: U, DESTINATION: `${name} [r1]`, DESTINATION_KIND: "name" });
});
for (const [label, list, code, reason] of [
  ["the suffix was removed by /rename (the title still matches)", [{ ref: "r1", name: "#42 Fix it" }], 5, "not-in-list"],
  ["two names carry the same 8 digits", [{ ref: "r1", name: `#42 Fix it${sfx(U)}` }, { ref: "r2", name: `#43 Twin${sfx(U_TWIN)}` }], 6, "ambiguous"],
  ["an upper-case suffix", [{ ref: "r1", name: `#42 Fix it [${U.slice(0, 8).toUpperCase()}]` }], 5, "not-in-list"],
  ["another session's suffix", [{ ref: "r1", name: `#42 Fix it${sfx(OTHER)}` }], 5, "not-in-list"],
  ["the suffix not at the end", [{ ref: "r1", name: `#42${sfx(U)} Fix it` }], 5, "not-in-list"],
]) {
  test(`FP3 name: ${label} -> ${code} ${reason}`, () => failed(run(["--issue", "42"], { policy: "name", holder: U, list }), code, reason));
}
caseEnd();

caseBegin("FP4 a missing or unparsable list fails without a guess", "bin/find-peer.d/agents-list.js");
for (const policy of ["ref", "name"]) {
  test(`FP4 ${policy}: no --agents-file -> 8 agents-list-required`, () => failed(run(["--issue", "42"], { policy, holder: U }), 8, "agents-list-required"));
  test(`FP4 ${policy}: an unparsable list -> 2 agents-list-unparsable`, () => failed(run(["--issue", "42"], { policy, holder: U, list: "{{{ not a list \u0000" }), 2, "agents-list-unparsable"));
}
caseEnd();

caseBegin("FP5 --role working reads the WIP holder and never falls back to the origin", "bin/find-peer.d/holder.js");
test("FP5 no holder -> 3 no-holder, the issue body is never read", () => {
  const r = run(["--issue", "42", "--role", "working"], { holder: "", body: `x\n<!-- origin-session: ${U} -->` });
  failed(r, 3, "no-holder");
  assert.strictEqual(r.bodyCalls.length, 0);
});
test("FP5 a holder read failure -> 7 forge-read-failed", () => {
  failed(run(["--issue", "42"], { holder: () => { throw new Error("glab down"); } }), 7, "forge-read-failed");
});
test("FP5 a holder that would inject a line is rejected", () => {
  const r = run(["--issue", "42"], { holder: `${U}\nDESTINATION=evil` });
  assert.notStrictEqual(r.code, 0, r.out);
  assert.ok(!/evil/.test(r.out), r.out);
});
caseEnd();

caseBegin("FP6 --role origin reads the marker that origin-session.sh writes", "bin/find-peer.d/origin.js");
test("FP6 the marker of origin_session_marker resolves the origin session", () => {
  const lib = path.join(P.ROOT, "bin", "github-issues", "lib", "origin-session.sh").replace(/\\/g, "/");
  const m = cp.spawnSync("bash", ["-c", '. "$0" && origin_session_marker "$1"', lib, U], { encoding: "utf8", timeout: 30000 });
  assert.strictEqual(m.status, 0, m.stderr);
  const r = run(["--issue", "42", "--role", "origin"], { body: `Body text\n\n${m.stdout.trim()}\n` });
  ok(r, { ROLE: "origin", SESSION_ID: U, DESTINATION: U });
  assert.strictEqual(r.holderCalls.length, 0);
});
test("FP6 a body without the marker -> 4 no-origin", () => failed(run(["--issue", "42", "--role", "origin"], { body: "Body only" }), 4, "no-origin"));
test("FP6 a body read failure -> 7 forge-read-failed", () => {
  failed(run(["--issue", "42", "--role", "origin"], { body: () => { throw new Error("gh down"); } }), 7, "forge-read-failed");
});
caseEnd();

caseBegin("FP9 --role origin counts distinct origin-session markers in the body", "bin/find-peer.d/origin.js");
const mk = (sid) => `<!-- origin-session: ${sid} -->`;
for (const [label, body, code, reason] of [
  ["0 markers", "Body only\n", 4, "no-origin"],
  ["1 marker", `Body\n${mk(U)}\n`, 0, null],
  ["2 different markers", `Body\n${mk(U)}\n${mk(OTHER)}\n`, 6, "ambiguous"],
  ["2 identical markers", `Body\n${mk(U)}\nmore\n${mk(U)}\n`, 0, null],
]) {
  test(`FP9 ${label} -> ${code}${reason ? ` ${reason}` : ""}`, () => {
    const r = run(["--issue", "42", "--role", "origin"], { body });
    if (code === 0) ok(r, { ROLE: "origin", SESSION_ID: U, DESTINATION: U });
    else failed(r, code, reason);
  });
}
caseEnd();

caseBegin("FP7 --session self and usage errors", "bin/find-peer.d/main.js");
test("FP7 --session self resolves this session", () => ok(run(["--session", "self"], { self: U }), { ROLE: "self", SESSION_ID: U, DESTINATION: U }));
test("FP7 a name with quotes is returned exactly", () => {
  const name = `#42 "quoted" 'x' $HOME${sfx(U)}`;
  ok(run(["--session", U], { policy: "name", list: [{ ref: "r1", name }] }), { SESSION_ID: U, DESTINATION: `${name} [r1]` });
});
for (const [label, argv] of [
  ["no arguments", []],
  ["both --issue and --session", ["--issue", "42", "--session", U]],
  ["a non-numeric issue", ["--issue", "abc"]],
  ["a negative issue", ["--issue", "-1"]],
  ["an unknown role", ["--issue", "42", "--role", "boss"]],
  ["a traversal session id", ["--session", "../x"]],
  ["a session id with a control character", ["--session", "ab\u0007cd"]],
  ["an unknown flag", ["--issue", "42", "--bogus"]],
  ["a bad --repo slug", ["--issue", "42", "--repo", "a/b/c;rm"]],
  ["--issue without a value", ["--issue"]],
]) {
  test(`FP7 usage: ${label} -> 2`, () => {
    const r = run(argv, { holder: U });
    assert.strictEqual(r.code, 2, r.out);
    assert.ok(r.kv.REASON, r.out);
  });
}
caseEnd();

caseBegin("FP8 the bin/find-peer CLI: usage, an unknown forge and a GitLab holder", "bin/find-peer");
test("FP8 CLI without arguments: exit 2 with a REASON line", () => {
  const r = P.runBin("bin/find-peer", []);
  assert.strictEqual(r.code, 2, `${r.out}${r.err}`);
  assert.ok(r.kv.REASON, r.out);
});
test("FP8 CLI on a bitbucket origin: the holder cannot be read -> 7, not 3", () => {
  const repo = P.gitRepo("git@bitbucket.org:acme/widgets.git");
  const list = P.writeFile("agents.txt", agentsListText([{ ref: "r1", name: `#42 T${sfx(U)}`, sessionId: U }]));
  const r = P.runBin("bin/find-peer", ["--issue", "42", "--agents-file", list], { cwd: repo });
  assert.strictEqual(r.code, 7, `${r.out}${r.err}`);
  assert.strictEqual(r.kv.REASON, "forge-read-failed", r.out);
});
test("FP8 CLI on a GitLab origin: the wip-fp label holder is the working session, no gh", () => {
  const repo = P.gitRepo("git@gitlab.com:acme/widgets.git");
  const glabLog = P.mockGlab([`wip-fp:${U}`, "status:wip"]);
  const before = P.cliCalls("gh").length;
  const list = P.writeFile("agents.txt", agentsListText([{ ref: "r1", name: `#42 T${sfx(U)}`, sessionId: U }]));
  const r = P.runBin("bin/find-peer", ["--issue", "42", "--agents-file", list], { cwd: repo });
  assert.strictEqual(r.code, 0, `${r.out}${r.err} glab=${fs.readFileSync(glabLog, "utf8")}`);
  assert.strictEqual(r.kv.ROLE, "working", r.out);
  assert.strictEqual(r.kv.SESSION_ID, U, r.out);
  assert.strictEqual(P.cliCalls("gh").length - before, 0, "gh was called on a GitLab origin");
});
caseEnd();

caseBegin("FP10 the real ListAgents row format resolves the name kind to the name plus the [ref6]", "bin/find-peer.d/agents-list.js");
const peer = { ref: "9f9f9f", name: `#7 Other${sfx(OTHER)}`, kind: "interactive", state: "busy" };
for (const [label, entries, code, reason, want] of [
  ["found by the suffix: the name with the trailing [ref6]", [peer, { ref: "a1b2c3", name: `#42 Fix it${sfx(U)}` }], 0, null, `#42 Fix it${sfx(U)} [a1b2c3]`],
  ["the suffix is absent", [peer, { ref: "a1b2c3", name: "#42 Fix it" }], 5, "not-in-list"],
  ["two rows carry the same 8 digits", [{ ref: "a1b2c3", name: `#42 Fix it${sfx(U)}` }, { ref: "d4e5f6", name: `#43 Twin${sfx(U_TWIN)}` }], 6, "ambiguous"],
  ["a row without the middle-dot part", [peer, { raw: `  #42 Fix it${sfx(U)} [a1b2c3]  interactive  idle` }], 2, "agents-list-unparsable"],
  ["a row without the [ref6]", [peer, { raw: `  #42 Fix it${sfx(U)}  ·  interactive  ·  idle` }], 2, "agents-list-unparsable"],
  ["a title with [ brackets", [peer, { ref: "a1b2c3", name: `#42 [WIP] fix [a] b${sfx(U)}` }], 0, null, `#42 [WIP] fix [a] b${sfx(U)} [a1b2c3]`],
  ["a title with a 6-hex [ ] inside", [peer, { ref: "a1b2c3", name: `#42 fix [abc123] b${sfx(U)}` }], 0, null, `#42 fix [abc123] b${sfx(U)} [a1b2c3]`],
  ...["-", "*", "x", "✓"].map((pre) => [`a title starting with the status prefix ${pre}`, [peer, { ref: "a1b2c3", name: `${pre} #42 Fix it${sfx(U)}` }], 0, null, `${pre} #42 Fix it${sfx(U)} [a1b2c3]`]),
]) {
  test(`FP10 real format: ${label} -> ${code}${reason ? ` ${reason}` : ""}`, () => {
    const r = run(["--issue", "42"], { policy: "name", holder: U, list: realAgentsListText(entries) });
    if (code === 0) ok(r, { ROLE: "working", SESSION_ID: U, DESTINATION: want, DESTINATION_KIND: "name" });
    else failed(r, code, reason);
  });
}
// The own session is listed only on the "This session is" header line, never as a row.
const own = { name: `#42 Self${sfx(U)}`, ref: "c0ffee" };
test("FP10 real format: --session self resolves from the header line (name policy)", () => {
  const r = run(["--session", "self"], { policy: "name", self: U, list: realAgentsListText([peer], own) });
  ok(r, { ROLE: "self", SESSION_ID: U, DESTINATION: `${own.name} [${own.ref}]`, DESTINATION_KIND: "name" });
});
test("FP10 real format: --session self on a ref policy -> 5 not-in-list (no row carries a session id)", () => {
  failed(run(["--session", "self"], { policy: "ref", self: U, list: realAgentsListText([peer], own) }), 5, "not-in-list");
});

// Own-session line forms (real, legacy quoted, malformed). Each row: [id, label, text, code, reason|null, want?, self?].
const REAL_SID = uuid("4f6187e3");
const REAL_NAME = "[PM] #2728 #2927 PM infra / sentinel issues [4f6187e3]";
const dumpWith = (o) => realAgentsListText([peer], o);
const base = { name: `#42 Self${sfx(U)}`, ref: "c0ffee" };
const CASES = [
  ["N1 verbatim real own line", `${REAL_OWN_LINE}\nPeer sessions (1):\n  #7 Other${sfx(OTHER)} [9f9f9f]  ·  interactive  ·  busy  ·  started 7h ago\n`, 0, null, `${REAL_NAME} [42d2bd]`, REAL_SID],
  ["N2 real format, default shape", dumpWith(base), 0, null, `${base.name} [c0ffee]`],
  ["N3 legacy quoted format", dumpWith({ ...base, quoted: true }), 0, null, `${base.name} [c0ffee]`],
  ["N4 legacy quoted format without the trailing period", dumpWith({ raw: `This session is "${base.name}" [c0ffee]` }), 0, null, `${base.name} [c0ffee]`],
  ["N5 name with [WIP] and [a] brackets", dumpWith({ name: `#42 [WIP] fix [a] b${sfx(U)}`, ref: "c0ffee" }), 0, null, `#42 [WIP] fix [a] b${sfx(U)} [c0ffee]`],
  ["N6 name containing ' [abcdef] — '", dumpWith({ name: `#42 fix [abcdef] — x${sfx(U)}`, ref: "c0ffee" }), 0, null, `#42 fix [abcdef] — x${sfx(U)} [c0ffee]`],
  ["N7 CRLF line ends", dumpWith(base).replace(/\n/g, "\r\n"), 0, null, `${base.name} [c0ffee]`],
  ["N8 name with an inner double quote (only a leading quote is refused)", dumpWith({ name: `#42 "q" 'x'${sfx(U)}`, ref: "c0ffee" }), 0, null, `#42 "q" 'x'${sfx(U)} [c0ffee]`],
  ["N9 empty clause is accepted ([^\\[\\]]* matches nothing)", `This session is ${base.name} [c0ffee] — \nPeer sessions (0):\n`, 0, null, `${base.name} [c0ffee]`],
  ["A1 own line and a peer row share the 8-digit suffix -> ambiguous", realAgentsListText([{ ref: "a1b2c3", name: `#43 Twin${sfx(U)}` }], base), 6, "ambiguous"],
  ["A2 two readable own lines with the same suffix -> both listed -> ambiguous", `${realAgentsListText([], base)}${realAgentsListText([], { name: `#44 Again${sfx(U)}`, ref: "d4e5f6" })}`, 6, "ambiguous"],
  ["A3 two own lines, only one carries this session's suffix -> that one", `${realAgentsListText([], base)}${realAgentsListText([], { name: `#44 Again${sfx(OTHER)}`, ref: "d4e5f6" })}`, 0, null, `${base.name} [c0ffee]`],
  ["A4 a readable own line plus an unreadable one -> unparsable", `${realAgentsListText([], base)}This session is [PM] x [42d2bd]\n`, 2, "agents-list-unparsable"],
  ["X8 upper-case hex ref is refused", dumpWith({ raw: `This session is ${base.name} [C0FFEE] — clause` }), 2, "agents-list-unparsable"],
  ["E1 real own line without the 8-digit suffix stays not-in-list", dumpWith({ raw: REAL_OWN_LINE_NO_SUFFIX }), 5, "not-in-list", null, REAL_SID],
  ["E3 zero peers with a real own line", `This session is ${base.name} [c0ffee] — clause.\nPeer sessions (0):\n`, 0, null, `${base.name} [c0ffee]`],
  ["X1 no clause, no quotes", dumpWith({ raw: "This session is [PM] x [42d2bd]" }), 2, "agents-list-unparsable"],
  ["X2 clause with brackets", dumpWith({ raw: "This session is [PM] x [42d2bd] — the name (see [ref])." }), 2, "agents-list-unparsable"],
  ["X3 quoted name plus clause", dumpWith({ raw: 'This session is "x" [42d2bd] — clause' }), 2, "agents-list-unparsable"],
  ["X4 5-digit ref", dumpWith({ raw: "This session is [PM] x [42d2b] — clause" }), 2, "agents-list-unparsable"],
  ["X5 no body", dumpWith({ raw: "This session is" }), 2, "agents-list-unparsable"],
  ["X6 ASCII hyphen instead of em dash", dumpWith({ raw: "This session is [PM] x [42d2bd] - clause" }), 2, "agents-list-unparsable"],
  ["X7 control character", dumpWith({ raw: REAL_OWN_LINE.replace("PM infra", "PM \u0007infra") }), 2, "agents-list-unparsable"],
];
for (const [name, list, code, reason, want, self] of CASES) {
  test(`FP10 real format: ${name} -> ${code}${reason ? ` ${reason}` : ""}`, () => {
    const r = run(["--session", "self"], { policy: "name", self: self || U, list });
    if (code === 0) ok(r, { ROLE: "self", SESSION_ID: self || U, DESTINATION: want, DESTINATION_KIND: "name" });
    else failed(r, code, reason);
  });
}
test("FP10 real format: E2 a real own line on a ref policy -> 5 not-in-list", () => {
  failed(run(["--session", "self"], { policy: "ref", self: U, list: dumpWith(base) }), 5, "not-in-list");
});
caseEnd();
