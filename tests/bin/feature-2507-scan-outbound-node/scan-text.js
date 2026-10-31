"use strict";
// Cases 7-9 (TL1): scanText line handling against the CLI golden, the fail-closed path for an
// ERE bash accepts but JS cannot express (rc 4, nothing scanned), and the D5 result shape with
// the CLI rc 0-4 mapping.

const assert = require("node:assert");
const path = require("node:path");
const { MOD, load, golden, unb64, parseLists } = require("./common");
const SB = require("./sandbox");
const C = require("./corpus");
const P = require("./probe-corpus");

const LINE_RE = /^(.*?):(\d+): \[([^\]]+)\] (.*)$/;
const HIDDEN = new Set(["zero-width", "bidi-override"]);

function goldenFindings(name) {
  return unb64(golden("cli").cases[name].stdoutB64).split("\n").map((l) => LINE_RE.exec(l)).filter(Boolean)
    .map(([, file, line, kind, matched]) => ({ file, line: Number(line), kind, matched }));
}

const shape = (f) => ({ file: f.file, line: f.line, kind: f.kind, matched: HIDDEN.has(f.kind) ? null : f.matched });

// The stdin cases whose golden pins line splitting, CR, the last line, UTF-8 and hidden chars.
const LINE_CASES = ["stdin-crlf", "stdin-no-trailing-newline", "stdin-blocklist-corpus", "stdin-zero-width-and-bidi", "stdin-builtin-patterns", "stdin-hard-and-warn"];

function runLines() {
  const { scanText } = load("scanText");
  const lists = parseLists(C.LISTS.main);
  for (const name of LINE_CASES) {
    const c = C.CLI_CASES.find((x) => x.name === name);
    const res = scanText(c.stdin.toString("utf8"), { file: c.argv[1], lists });
    assert.deepStrictEqual(res.details.findings.map(shape), goldenFindings(name).map(shape), `${name}: findings equal the bash golden`);
  }
  // Each hidden range bound and its outside neighbour.
  const ZW = [0x200b, 0x200c, 0x200d, 0xfeff];
  const BIDI = [0x202d, 0x202e, 0x2066, 0x2067, 0x2068, 0x2069];
  const NONE = [0x200a, 0x200e, 0xfefe, 0x202c, 0x202f, 0x2065, 0x206a];
  for (const cp of [...ZW, ...BIDI, ...NONE]) {
    const want = ZW.includes(cp) ? ["zero-width"] : BIDI.includes(cp) ? ["bidi-override"] : [];
    const res = scanText(`a${String.fromCodePoint(cp)}b`, { file: "h.txt", lists: { allow: [], blockHard: [], blockWarn: [] } });
    assert.deepStrictEqual(res.details.findings.map((f) => f.kind), want, `U+${cp.toString(16)}: want ${JSON.stringify(want)}`);
  }
}

const UNTRANSLATABLE_LISTS = { blocklist: `${C.LISTS.main.blocklist}\n${P.UNTRANSLATABLE[0]}\n`, allowlist: C.LISTS.main.allowlist };
const UNTRANSLATABLE_INPUT = Buffer.from(`fixture-term-alpha-bad\n${C.SECRETS.github}\n`, "utf8");

function runFailClosedCli(root) {
  SB.setLists(root, UNTRANSLATABLE_LISTS);
  const r = SB.runCli(root, { argv: ["--stdin", "fc.txt"], stdin: UNTRANSLATABLE_INPUT });
  assert.strictEqual(r.rc, 4, `untranslatable ERE: rc 4 (bash today scans and says rc ${r.rc}); stdout=${r.stdout}`);
  assert.strictEqual(r.stdout, "", "no line is scanned, so no finding line is printed");
  assert.ok(r.stderr.trim().length > 0, "stderr names the reason");
  const res = load("scanText").scanText(UNTRANSLATABLE_INPUT.toString("utf8"), { file: "fc.txt", lists: parseLists(UNTRANSLATABLE_LISTS) });
  assert.deepStrictEqual(res.details.findings, [], "scanText scans no line");
  assert.ok(res.details.incomplete && typeof res.details.incomplete.reason === "string" && res.details.incomplete.reason.length > 0, "incomplete carries the reason");
}

const RC4_WORDING = "pre-commit: private-info blocklist unresolved (rc=4) — cannot scan, commit blocked";

function runFailClosedPrecommit() {
  const { scanStaged } = load("precommitCheck");
  const res = scanStaged({ files: [{ path: "a.txt", mode: "100644", content: UNTRANSLATABLE_INPUT }], lists: parseLists(UNTRANSLATABLE_LISTS) });
  assert.strictEqual(res.verdict, "block", "the outbound-scan check blocks");
  const err = res.messages.filter((m) => m.stream === "stderr").map((m) => m.text).join("");
  assert.ok(err.includes(RC4_WORDING), `stderr keeps today's rc 4 wording; got ${JSON.stringify(err)}`);
}

function runResultShape() {
  const { scanText } = load("scanText");
  const lists = parseLists(C.LISTS.main);
  const verdictOf = (t) => scanText(t, { file: "v.txt", lists });
  assert.strictEqual(verdictOf(C.TEXT.clean).verdict, "pass", "clean -> pass");
  assert.strictEqual(verdictOf(C.TEXT.warnOnly).verdict, "warn", "warn only -> warn");
  const mixed = verdictOf(C.TEXT.mixed);
  assert.strictEqual(mixed.verdict, "block", "hard present -> block");
  for (const m of mixed.messages) {
    assert.ok(["stdout", "stderr"].includes(m.stream) && typeof m.text === "string", `message shape ${JSON.stringify(m)}`);
  }
  assert.strictEqual(mixed.details.incomplete, null, "a complete scan has incomplete null");
  for (const f of mixed.details.findings) {
    assert.deepStrictEqual(Object.keys(f).sort(), ["file", "group", "kind", "line", "matched", "severity"], `finding keys ${JSON.stringify(f)}`);
    assert.strictEqual(f.severity, f.kind === "blocklist-warn" ? "warn" : "hard", `severity of ${f.kind}`);
  }
}

// rc 0-4 from the in-process CLI adapter (the sandbox copy, so its lists are the fixture ones).
const RC_CASES = ["stdin-clean", "stdin-blocklist-corpus", "stdin-warn-only", "usage-no-arguments", "blocklist-missing"];

async function runRcMapping(root) {
  const g = golden("cli").cases;
  for (const name of RC_CASES) {
    const c = C.CLI_CASES.find((x) => x.name === name);
    SB.setLists(root, C.LISTS[c.lists]);
    const cliPath = path.join(root, MOD.cli);
    delete require.cache[cliPath];
    const { run } = require(cliPath);
    const out = [];
    const err = [];
    const rc = await run({ argv: c.argv, stdin: c.stdin || Buffer.alloc(0), cwd: root, env: SB.baseEnv(), stdout: { write: (s) => out.push(String(s)) }, stderr: { write: (s) => err.push(String(s)) } });
    assert.strictEqual(rc, g[name].rc, `${name}: rc`);
    assert.strictEqual(SB.normalize(root, Buffer.from(out.join(""))), unb64(g[name].stdoutB64), `${name}: stdout`);
  }
}

module.exports = { runLines, runFailClosedCli, runFailClosedPrecommit, runResultShape, runRcMapping };
