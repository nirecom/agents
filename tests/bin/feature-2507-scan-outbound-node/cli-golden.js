"use strict";
// Cases 10-11 (TL2): bin/scan-outbound.sh run as a process in the sandbox. Case 10 replays the
// whole golden corpus (green on today's bash, and must stay green once the file is a thin
// adapter in front of Node); case 11 takes node off PATH and wants the adapter's rc 4.

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { golden, unb64 } = require("./common");
const SB = require("./sandbox");
const C = require("./corpus");

function runGolden(root) {
  const g = golden("cli");
  assert.strictEqual(Object.keys(g.cases).length, C.CLI_CASES.length, "golden covers the whole CLI corpus (regenerate after editing it)");
  for (const c of C.CLI_CASES) {
    const want = g.cases[c.name];
    assert.ok(want, `${c.name}: present in the golden`);
    SB.setLists(root, C.LISTS[c.lists]);
    const r = SB.runCli(root, c);
    assert.strictEqual(r.error, undefined, `${c.name}: spawn error ${r.error}`);
    assert.strictEqual(r.stdout, unb64(want.stdoutB64), `${c.name}: stdout`);
    assert.strictEqual(r.stderr, unb64(want.stderrB64), `${c.name}: stderr`);
    assert.strictEqual(r.rc, want.rc, `${c.name}: rc`);
  }
}

// PATH with every directory holding a node executable removed; bash is launched by its own path.
function pathWithoutNode(env) {
  const key = Object.keys(env).find((k) => k.toUpperCase() === "PATH");
  const kept = env[key].split(path.delimiter).filter((d) => !["node", "node.exe"].some((n) => fs.existsSync(path.join(d, n))));
  return { ...env, [key]: kept.join(path.delimiter) };
}

function runNoNode(root) {
  SB.setLists(root, C.LISTS.main);
  const env = pathWithoutNode(SB.baseEnv());
  const r = SB.runCli(root, { argv: ["--stdin", "nn.txt"], stdin: Buffer.from("fixture-term-alpha-bad\n", "utf8"), env });
  assert.strictEqual(r.rc, 4, `no node on PATH: the adapter fails closed with rc 4 (got rc ${r.rc}); stdout=${r.stdout}`);
  assert.strictEqual(r.stdout, "", "nothing is scanned");
  assert.ok(r.stderr.trim().length > 0, "stderr gives the reason");
}

module.exports = { runGolden, runNoNode };
