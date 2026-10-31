"use strict";
// Cases 3-4 (TL1): the allowlist `file:value` glob against golden/glob.json (bash `[[ f == g ]]`),
// and the pre-commit binary skip against golden/binary.json (`git show | file --mime - | grep binary`).

const assert = require("node:assert");
const { load, golden } = require("./common");
const { BINARY_CASES } = require("./binary-corpus");

function runGlob() {
  const { globMatch } = load("glob");
  for (const [name, c] of Object.entries(golden("glob").cases)) {
    assert.strictEqual(globMatch(c.glob, c.subject), c.match, `${name}: ${JSON.stringify(c.glob)} vs ${JSON.stringify(c.subject)} want ${c.match}`);
  }
}

function runBinary() {
  const { isBinary } = load("binary");
  const g = golden("binary");
  assert.strictEqual(Object.keys(g.cases).length, BINARY_CASES.length, "golden covers the whole binary corpus (regenerate after editing it)");
  for (const c of BINARY_CASES) {
    const want = g.cases[c.name];
    assert.ok(want, `${c.name}: present in the golden`);
    assert.strictEqual(isBinary({ mode: c.mode, content: c.content }), want.binary, `${c.name}: file said ${JSON.stringify(want.mime)}, want binary=${want.binary}`);
  }
}

module.exports = { runGlob, runBinary };
