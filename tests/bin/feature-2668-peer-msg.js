"use strict";
// Tests: hooks/lib/peer-msg.js, bin/peer-msg
// Tags: TL1, TL2, scope:issue-specific, issue-2668, peer-msg, cross-session, ack
// #2668: the [peer-msg v1] header and [peer-ack v1] ack of cross-session messages, and the
// header / verify / timer verbs of bin/peer-msg. Assumed API of hooks/lib/peer-msg.js:
// formatHeader({fromSession, msgId, replyTo, replyKind, role?, pmIssues?}) -> string,
// parseHeader(text) -> that object | null, formatAck({ackOf, session}) -> string,
// parseAck(text) -> that object | null. Header shape and exit codes: the detail plan's Ack header.
// PM2 fixes the branch as input: a checkout copy's bin/find-peer.d/destination-policy.js is rewritten
// to {DESTINATION_KIND, FROM_REPLY_VERIFIED} (the latter name is assumed; the plan leaves it open).

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");
const { agentsListText, uuid, makeFixtures, load, tmpRoot } = require("./feature-2668-find-peer/fixtures");

// TL3 gap: a real SendMessage carrying the header to a peer and the peer's real ack are not
// exercised (model tools). Closest-to-action mitigation: verification (a)(b) of the detail plan,
// run by hand before release and recorded in docs/architecture/cross-session-messaging.md.
// The ListAgents text of selfList() is a placeholder shape until verification (b) saves real output (C1).

const restore = isolate();
const tmp = tmpRoot();
const P = makeFixtures(tmp);
after(() => { fs.rmSync(tmp, { recursive: true, force: true }); restore(); });

const lib = load("hooks/lib/peer-msg.js");
const SELF = uuid("5e1f5e1f");
const PEER = uuid("bee71234");
const MSG = "0d9c8b7a-6f5e-4d3c-8b2a-1f0e9d8c7b6a";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const SELF_NAME = `#2668 Peer [${SELF.slice(0, 8)}]`;
const selfList = () => P.writeFile("agents.txt", agentsListText([{ ref: "r7", name: SELF_NAME, sessionId: SELF }, { ref: "r8", name: `#1 Other [${PEER.slice(0, 8)}]`, sessionId: PEER }]));
const asSelf = { CLAUDE_CODE_SESSION_ID: SELF };
const headerLine = (out) => (String(out).split(/\r?\n/).find((l) => l.startsWith("[peer-msg v1] ")) || null);

caseBegin("PM1 the header and ack formats round-trip and reject malformed text", "hooks/lib/peer-msg.js");
for (const [label, h] of [
  ["reply-kind session-id", { fromSession: SELF, msgId: MSG, replyTo: SELF, replyKind: "session-id" }],
  ["reply-kind ref", { fromSession: SELF, msgId: MSG, replyTo: "r7", replyKind: "ref" }],
  ["reply-kind from", { fromSession: SELF, msgId: MSG, replyTo: "from", replyKind: "from" }],
  ["a PM header", { fromSession: SELF, msgId: MSG, replyTo: SELF, replyKind: "session-id", role: "pm", pmIssues: "#1,#2" }],
]) {
  test(`PM1 header ${label}: format then parse gives the fields back`, () => {
    const text = lib.formatHeader(h);
    assert.ok(text.startsWith(`[peer-msg v1] from-session=${SELF} msg-id=${MSG} reply-to=`), text);
    if (h.role) assert.ok(text.endsWith(" role=pm pm-issues=#1,#2"), text);
    const back = lib.parseHeader(`${text}\n\nbody`);
    for (const [k, v] of Object.entries(h)) assert.strictEqual(back && back[k], v, `${k}: ${JSON.stringify(back)}`);
  });
}
for (const [label, text] of [
  ["another version", `[peer-msg v2] from-session=${SELF} msg-id=${MSG} reply-to=${SELF} reply-kind=session-id`],
  ["no from-session", `[peer-msg v1] msg-id=${MSG} reply-to=${SELF} reply-kind=session-id`],
  ["a msg-id that is not a UUID", `[peer-msg v1] from-session=${SELF} msg-id=nope reply-to=${SELF} reply-kind=session-id`],
  ["an unknown reply-kind", `[peer-msg v1] from-session=${SELF} msg-id=${MSG} reply-to=${SELF} reply-kind=email`],
  ["a header not on the first line", `hello\n[peer-msg v1] from-session=${SELF} msg-id=${MSG} reply-to=${SELF} reply-kind=session-id`],
]) {
  test(`PM1 parseHeader rejects ${label}`, () => assert.strictEqual(lib.parseHeader(text), null));
}
test("PM1 ack: format then parse gives the fields back", () => {
  const text = lib.formatAck({ ackOf: MSG, session: PEER });
  assert.strictEqual(text, `[peer-ack v1] ack-of=${MSG} session=${PEER}`);
  assert.deepStrictEqual(lib.parseAck(text), { ackOf: MSG, session: PEER });
});
for (const [label, text] of [
  ["no session", `[peer-ack v1] ack-of=${MSG}`],
  ["another version", `[peer-ack v2] ack-of=${MSG} session=${PEER}`],
  ["a line break inside the session", `[peer-ack v1] ack-of=${MSG} session=${PEER}\nsession=evil`],
]) {
  test(`PM1 parseAck rejects ${label}`, () => assert.strictEqual(lib.parseAck(text), null));
}
caseEnd();

caseBegin("PM2 bin/peer-msg header builds the header from find-peer --session self", "bin/peer-msg");
// withPolicy(kind, fromVerified) — one copy of bin/ and hooks/ (untracked new files included) whose
// destination-policy.js is rewritten, so the branch is an input of the case, not a value it reads.
const CO = path.join(tmp, "co");
function withPolicy(kind, fromVerified) {
  if (!fs.existsSync(CO)) {
    for (const d of ["bin", "hooks"]) fs.cpSync(path.join(P.ROOT, d), path.join(CO, d), { recursive: true, filter: (s) => !/[\\/](node_modules|\.git)([\\/]|$)/.test(s) });
  }
  const f = path.join(CO, "bin", "find-peer.d", "destination-policy.js");
  fs.mkdirSync(path.dirname(f), { recursive: true });
  fs.writeFileSync(f, `"use strict";\nmodule.exports = { DESTINATION_KIND: ${JSON.stringify(kind)}, FROM_REPLY_VERIFIED: ${fromVerified} };\n`);
}
function headerAt(args) {
  const file = path.join(CO, "bin", "peer-msg").replace(/\\/g, "/");
  const r = cp.spawnSync("bash", ["-c", '"$0" "$@"', file, "header", ...args], { cwd: tmp, env: P.childEnv(asSelf), encoding: "utf8", timeout: 60000 });
  return { code: r.status, out: r.stdout || "", err: `${r.stderr || ""}${r.error ? String(r.error) : ""}` };
}
const HEADER_RE = /^\[peer-msg v1\] from-session=(\S+) msg-id=(\S+) reply-to=(.*) reply-kind=(\S+)$/;
// [branch, from-replies verified, with a list, exit, reply-to, reply-kind] — the detail plan's header contract.
for (const [kind, fromVerified, withList, code, replyTo, replyKind] of [
  ["session-id", false, true, 0, SELF, "session-id"],
  ["ref", false, true, 0, "r7", "ref"],
  ["name", false, true, 0, SELF_NAME, "name"],
  ["session-id", false, false, 0, SELF, "session-id"],
  ["session-id", true, false, 0, SELF, "session-id"],
  ["ref", false, false, 8, null, null],
  ["name", false, false, 8, null, null],
  ["ref", true, false, 0, "from", "from"],
  ["name", true, false, 0, "from", "from"],
]) {
  const label = `branch ${kind}, from-replies ${fromVerified ? "verified" : "unverified"}, ${withList ? "with" : "without"} a list`;
  test(`PM2 header on ${label} -> exit ${code}${replyKind ? ` reply-to=${replyTo} reply-kind=${replyKind}` : ", REASON=agents-list-required, no header"}`, () => {
    withPolicy(kind, fromVerified);
    const r = headerAt(withList ? ["--agents-file", selfList()] : []);
    assert.strictEqual(r.code, code, `${r.out}${r.err}`);
    const line = headerLine(r.out);
    if (replyKind === null) {
      assert.ok(/^REASON=agents-list-required$/m.test(r.out), r.out);
      assert.strictEqual(line, null, r.out);
      return;
    }
    const m = line && line.match(HEADER_RE);
    assert.ok(m, r.out);
    assert.strictEqual(m[1], SELF);
    assert.ok(UUID_RE.test(m[2]), m[2]);
    assert.strictEqual(m[3], replyTo);
    assert.strictEqual(m[4], replyKind);
  });
}
test("PM2 header --role pm --pm-issues adds the PM suffix", () => {
  const r = P.runBin("bin/peer-msg", ["header", "--agents-file", selfList(), "--role", "pm", "--pm-issues", "#1,#2"], { env: asSelf });
  assert.strictEqual(r.code, 0, `${r.out}${r.err}`);
  assert.ok((headerLine(r.out) || "").endsWith(" role=pm pm-issues=#1,#2"), r.out);
});
for (const [label, args] of [["--role pm without --pm-issues", ["--role", "pm"]], ["--pm-issues that are not refs", ["--role", "pm", "--pm-issues", "abc;rm"]]]) {
  test(`PM2 header ${label} -> 2 and no header`, () => {
    const r = P.runBin("bin/peer-msg", ["header", "--agents-file", selfList(), ...args], { env: asSelf });
    assert.strictEqual(r.code, 2, `${r.out}${r.err}`);
    assert.strictEqual(headerLine(r.out), null, r.out);
  });
}
test("PM2 two headers carry two different msg-ids", () => {
  const ids = [0, 1].map(() => {
    const line = headerLine(P.runBin("bin/peer-msg", ["header", "--agents-file", selfList()], { env: asSelf }).out) || "";
    return (line.match(/msg-id=(\S+)/) || [])[1];
  });
  assert.ok(ids[0] && ids[1] && ids[0] !== ids[1], JSON.stringify(ids));
});
caseEnd();

caseBegin("PM3 bin/peer-msg verify and timer", "bin/peer-msg");
const ackFile = (text) => P.writeFile("ack.txt", text);
const verify = (args) => P.runBin("bin/peer-msg", ["verify", ...args]);
test("PM3 verify: the matching ack -> 0", () => {
  const r = verify(["--msg-id", MSG, "--expect-session", PEER, "--ack-file", ackFile(`thanks\n[peer-ack v1] ack-of=${MSG} session=${PEER}\n`)]);
  assert.strictEqual(r.code, 0, `${r.out}${r.err}`);
});
for (const [label, file] of [
  ["no ack line", () => ackFile("just a reply\n")],
  ["an ack of another msg-id", () => ackFile(`[peer-ack v1] ack-of=${uuid("00000000")} session=${PEER}\n`)],
  ["a missing ack file", () => path.join(tmp, "no-such-ack.txt")],
]) {
  test(`PM3 verify: ${label} -> 3`, () => assert.strictEqual(verify(["--msg-id", MSG, "--expect-session", PEER, "--ack-file", file()]).code, 3));
}
test("PM3 verify: a session that differs only after the first 8 digits -> 4", () => {
  const near = uuid(PEER.slice(0, 8), "999999999999");
  assert.notStrictEqual(near, PEER);
  const r = verify(["--msg-id", MSG, "--expect-session", PEER, "--ack-file", ackFile(`[peer-ack v1] ack-of=${MSG} session=${near}\n`)]);
  assert.strictEqual(r.code, 4, `${r.out}${r.err}`);
});
test("PM3 verify without --msg-id -> 2", () => {
  assert.strictEqual(verify(["--expect-session", PEER, "--ack-file", ackFile("x\n")]).code, 2);
});
test("PM3 timer --seconds 1 exits 0 and names the msg-id", () => {
  const r = P.runBin("bin/peer-msg", ["timer", "--msg-id", MSG, "--seconds", "1"], { timeout: 30000 });
  assert.strictEqual(r.code, 0, `${r.out}${r.err}`);
  assert.ok(r.out.includes(MSG), r.out);
});
for (const s of ["0", "-1", "abc"]) {
  test(`PM3 timer --seconds ${s} -> 2`, () => {
    assert.ok(fs.existsSync(path.join(P.ROOT, "bin", "peer-msg")), "bin/peer-msg is missing");
    assert.strictEqual(P.runBin("bin/peer-msg", ["timer", "--msg-id", MSG, "--seconds", s]).code, 2);
  });
}
caseEnd();
