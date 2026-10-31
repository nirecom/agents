"use strict";
// Tests: bin/scan-outbound.d/manifest.js
// Tags: TL1, TL2, scan-outbound, manifest, fail-closed, scope:issue-specific
// #2507: a --manifest frame whose declared length runs past EOF swallowed the frames after it.
// The swallowed next header can sit mid-line (the short body had no trailing LF), and the parser
// must still see it and report the stream broken (rc 4) instead of scanning the rest as one body.
// A header-like run inside a body whose length is exact, or a lone RS in a cut-short body, is
// ordinary content and stays a parsed frame. Cases 7-8 keep the declared length inside the stream.
const { isolate } = require("../lib/harness");

const assert = require("node:assert");
const path = require("node:path");
const { after, before, test } = require("node:test");
const SB = require("./feature-2507-scan-outbound-node/sandbox");
const { LISTS, SECRETS } = require("./feature-2507-scan-outbound-node/corpus");

const RS = "\u001e";
const u = (s) => Buffer.from(s, "utf8");
const AFTER = SECRETS.aws;
const BROKEN = SECRETS.github;
const afterBody = `k ${AFTER}\n`;
const afterFrame = Buffer.concat([u(`${RS}after.txt${RS}${u(afterBody).length}\n`), u(afterBody)]);

function frame(p, len, body) {
  return Buffer.concat([u(`${RS}${p}${RS}${len}\n`), u(body)]);
}

// A first frame whose body has no trailing LF and whose length runs past EOF (yet stays under the
// stream size), so the next frame's header follows the body mid-line.
function swallowedMidLine(body) {
  return Buffer.concat([frame("a.txt", u(body).length + afterFrame.length + 5, body), afterFrame]);
}

const BROKEN_STREAMS = {
  "header glued after text without LF": swallowedMidLine(`g ${BROKEN}`),
  "header glued after CR": swallowedMidLine(`g ${BROKEN}\r`),
  "header glued after a lone RS-free word": swallowedMidLine("x"),
};

// Boundaries the parser already stops on: the header at the very start of the short body, or
// right after a LF. Pinned so the mid-line fix keeps them.
const ALREADY_BROKEN = {
  "empty short body, header at body start": Buffer.concat([frame("a.txt", afterFrame.length + 5, ""), afterFrame]),
  "header right after LF": swallowedMidLine(`g ${BROKEN}\n`),
};

// Streams that must parse: header-like bytes inside an exact-length body, a lone RS inside a body
// cut short at EOF, and plain well-formed frames.
const glued = `x${RS}fake.txt${RS}12\ny`;
const SANE = [
  { name: "header-like run inside an exact-length body", stdin: Buffer.concat([frame("h.txt", u(glued).length, glued), afterFrame]), paths: ["h.txt", "after.txt"] },
  { name: "lone RS mid-line in a body cut short at EOF", stdin: Buffer.concat([afterFrame, frame("t.txt", 40, `a${RS}b`)]), paths: ["after.txt", "t.txt"] },
  { name: "two well-formed frames", stdin: Buffer.concat([frame("p.txt", 6, "plain\n"), afterFrame]), paths: ["p.txt", "after.txt"] },
];

const restore = isolate();
let root = null;
before(() => {
  root = SB.createSandbox();
  SB.setLists(root, LISTS.empty);
});
after(() => {
  restore();
  if (root) SB.removeSandbox(root);
});

function parse(buf) {
  const modPath = path.join(SB.REPO, "bin", "scan-outbound.d", "manifest.js");
  delete require.cache[modPath];
  return require(modPath).parseManifest(buf);
}

async function inProcess(stdin) {
  const cliPath = path.join(root, "bin", "scan-outbound.d", "cli.js");
  for (const k of Object.keys(require.cache)) if (k.startsWith(root)) delete require.cache[k];
  const { run } = require(cliPath);
  const out = [];
  const err = [];
  const rc = await run({ argv: ["--manifest"], stdin, cwd: root, env: SB.baseEnv(), stdout: { write: (s) => out.push(String(s)) }, stderr: { write: (s) => err.push(String(s)) } });
  return { rc, stdout: out.join(""), stderr: err.join("") };
}

function assertBroken(name, buf) {
  const r = parse(buf);
  assert.ok(r && typeof r.broken === "string" && r.broken.length > 0, `${name}: parseManifest reports broken (got ${JSON.stringify(r && r.frames ? r.frames.map((f) => f.path) : r)})`);
}

test("1 a next-frame header glued mid-line into a cut-short body is a swallowed frame (parseManifest broken)", () => {
  for (const [name, buf] of Object.entries(BROKEN_STREAMS)) assertBroken(name, buf);
});

test("2 the header at the body start or after LF stays broken", () => {
  for (const [name, buf] of Object.entries(ALREADY_BROKEN)) assertBroken(name, buf);
});

test("3 header-like bytes in an exact body, a lone RS in a short last body, well-formed frames parse", () => {
  for (const c of SANE) {
    const r = parse(c.stdin);
    assert.ok(r && Array.isArray(r.frames), `${c.name}: parses (got ${JSON.stringify(r)})`);
    assert.deepStrictEqual(r.frames.map((f) => f.path), c.paths, `${c.name}: frame paths`);
  }
});

test("4 in-process CLI: a mid-line swallowed header stops with rc 4 and a broken-stream message", async () => {
  for (const [name, buf] of Object.entries(BROKEN_STREAMS)) {
    const r = await inProcess(buf);
    assert.strictEqual(r.rc, 4, `${name}: rc 4 (got ${r.rc}; stdout ${JSON.stringify(r.stdout.slice(0, 200))})`);
    assert.match(r.stderr, /broken --manifest stream/, `${name}: stderr names the broken stream`);
    assert.ok(!r.stdout.includes("after.txt"), `${name}: no finding is attributed to the swallowed frame`);
  }
});

test("5 in-process CLI: the sane streams keep scanning and report the after.txt hard secret (rc 1)", async () => {
  for (const c of SANE) {
    const r = await inProcess(c.stdin);
    assert.notStrictEqual(r.rc, 4, `${c.name}: not stopped as broken (stderr ${JSON.stringify(r.stderr)})`);
    assert.strictEqual(r.rc, 1, `${c.name}: rc 1 from the after.txt hard secret (stdout ${JSON.stringify(r.stdout.slice(0, 200))})`);
    assert.ok(r.stdout.includes("after.txt"), `${c.name}: stdout names after.txt`);
    assert.match(r.stdout, /^after\.txt:1: \[aws-key\] /m, `${c.name}: after.txt line 1 is reported as aws-key`);
  }
  const plain = await inProcess(Buffer.concat([frame("p.txt", 6, "plain\n"), frame("q.txt", 6, "quiet\n")]));
  assert.strictEqual(plain.rc, 0, `clean well-formed frames: rc 0 (stderr ${JSON.stringify(plain.stderr)})`);
});

test("6 bash entry: scan-outbound.sh --manifest stops a mid-line swallowed header with rc 4", () => {
  const r = SB.runCli(root, { argv: ["--manifest"], stdin: BROKEN_STREAMS["header glued after text without LF"] });
  assert.strictEqual(r.error, undefined, `spawn error ${r.error}`);
  assert.strictEqual(r.rc, 4, `rc 4 (got ${r.rc}; stderr ${JSON.stringify(r.stderr)})`);
  assert.match(r.stderr, /broken --manifest stream/);
});

// A well-formed lead frame, then a frame whose declared length fits inside the whole stream (so
// `len > buf.length` cannot fire) but outruns its own remaining bytes, swallowing afterFrame's header.
const LEAD = frame("lead.txt", 6, "plain\n");
function swallowedInBounds(body) {
  const rest = u(body).length + afterFrame.length;
  const buf = Buffer.concat([LEAD, frame("a.txt", rest + 1, body), afterFrame]);
  return { buf, len: rest + 1, rest };
}
async function assertInBoundsBroken(name, body) {
  const { buf, len, rest } = swallowedInBounds(body);
  assert.ok(len <= buf.length && len > rest, `${name}: precondition len ${len} <= stream ${buf.length} and > remaining ${rest}`);
  assertBroken(name, buf);
  const r = await inProcess(buf);
  assert.strictEqual(r.rc, 4, `${name}: rc 4 (got ${r.rc}; stdout ${JSON.stringify(r.stdout.slice(0, 200))})`);
  assert.match(r.stderr, /broken --manifest stream/, `${name}: stderr names the broken stream`);
}

test("7 after a lead frame, an in-bounds declared length that swallows a header right after LF stops with rc 4", async () => {
  await assertInBoundsBroken("swallowed header right after LF", `g ${BROKEN}\n`);
});

test("8 after a lead frame, an in-bounds declared length that swallows a mid-line header (no LF before RS) stops with rc 4", async () => {
  await assertInBoundsBroken("swallowed header mid-line", `g ${BROKEN}`);
});
