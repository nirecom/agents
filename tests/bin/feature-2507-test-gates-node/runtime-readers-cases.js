"use strict";
// Tests: bin/check-case-markers/cli.js
// Tags: TL1, TL2, bin, parity, scope:issue-specific
// Conforming pester / pytest runs (#2507 S4, review-tests C4). The pester and pytest readers stay
// external children (detail: parts/external-runtime.js is the one exception), so the Node gate must
// start the real reader child and give the bash CLI's verdict on a correct file. Holds no case
// markers. The bash side runs live (no golden): its output depends on the host's pwsh / uv.
// Skip condition (explicit, per runtime): the runtime is not on PATH; see skipReason().
const assert = require("node:assert");
const cp = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const F = require("./fixture");
const D = require("./driver");

const RUNTIMES = {
  pester: { tool: "pwsh", file: "tests/bin/rt.Tests.ps1", reader: "pester-case-reader.ps1",
    cases: [["alpha", "bin/d.ps1", "4", "6"], ["beta", "bin/g.ps1", "8", "12"]] },
  pytest: { tool: "uv", file: "tests/bin/test_rt.py", reader: "pytest-case-reader.py",
    cases: [["test_alpha", "bin/e.py", "6", "8"], ["TestBeta", "bin/f.py", "11", "14"]] },
};

const PATH_KEY = Object.keys(process.env).find((k) => k.toUpperCase() === "PATH") || "PATH";
const onPath = (name) => String(process.env[PATH_KEY] || "").split(path.delimiter)
  .some((dir) => [name, `${name}.exe`, `${name}.cmd`].some((n) => fs.existsSync(path.join(dir, n))));
// skipReason(id) — false when the runtime is on PATH, else the reason the node:test case skips.
const skipReason = (id) => (onPath(RUNTIMES[id].tool) ? false : `${RUNTIMES[id].tool} not on PATH: the ${id} reader child cannot run on this host`);

// Spawn recorder: patched before any gate module is required (they load lazily inside tests), so a
// destructured import gets the recorder too. Records only while armed, never the test's own spawns.
const NAMES = ["spawn", "spawnSync", "exec", "execSync", "execFile", "execFileSync", "fork"];
let armed = false;
let calls = [];
for (const name of NAMES) {
  const orig = cp[name];
  const wrapped = function recorded(command, ...rest) {
    if (armed) calls.push([command, ...rest.filter(Array.isArray).flat()].map(String).join(" "));
    return orig.call(this, command, ...rest);
  };
  for (const sym of Object.getOwnPropertySymbols(orig)) wrapped[sym] = orig[sym];
  cp[name] = wrapped;
}
async function recording(fn) {
  calls = [];
  armed = true;
  try {
    return { value: await fn(), calls: calls.slice() };
  } finally {
    armed = false;
  }
}

// conforming(id) — the bash CLI passes the file (pinned: rc 0, nothing printed) and crr_read shows
// its two cases; run() of the Node CLI starts the reader child and prints the same bytes and rc,
// and case-records.js answers the same TSV.
async function conforming(id) {
  const rt = RUNTIMES[id];
  const run = { id: `rt-${id}`, cli: "markers", tree: "rt", path: "full", args: [rt.file] };
  const bash = F.bashRun(run);
  assert.ok(!bash.skipped, `${id}: ${bash.skipped}`);
  assert.deepStrictEqual(bash, { rc: 0, stdout: "", stderr: "" }, `${id}: bash check-case-markers passes the conforming file`);
  const abs = path.join(F.tree("rt"), rt.file).replace(/\\/g, "/");
  const answers = D.ask([["crr", abs, rt.file]]);
  assert.ok(answers, `${id}: the full PATH cannot be built on this host`);
  const rows = answers[0].out.split("\n").filter(Boolean).map((l) => l.split("\t"));
  assert.deepStrictEqual(rows[0].slice(0, 2), ["FILE", "conforming"], `${id}: bash crr_read state (${answers[0].out})`);
  assert.deepStrictEqual(rows.slice(1).map((r) => r.slice(0, 5)), rt.cases.map((c) => ["CASE", ...c]), `${id}: bash crr_read cases`);

  const node = await recording(() => F.nodeRun(run));
  assert.deepStrictEqual(node.value, bash, `${id}: Node check-case-markers run() gives the bash verdict`);
  assert.ok(node.calls.some((c) => c.startsWith(rt.tool) || c.includes(`${path.sep}${rt.tool}`) || c.includes(`/${rt.tool}`)),
    `${id}: run() started ${rt.tool}; calls: ${JSON.stringify(node.calls)}`);
  assert.ok(node.calls.some((c) => c.includes(rt.reader)), `${id}: run() handed ${rt.reader} to the child; calls: ${JSON.stringify(node.calls)}`);

  const CR = require(path.join(F.REPO, "hooks", "lib", "test-gates", "case-records.js"));
  assert.strictEqual(await CR.read(abs, rt.file), answers[0].out, `${id}: case-records.js read() answers bash crr_read`);
}

module.exports = { RUNTIMES, skipReason, conforming };
