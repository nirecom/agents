"use strict";
// Tests: hooks/lib/test-gates/placement.js
// Tags: TL1, bin, parity, table-driven, test-lang-exception:symmetry, scope:issue-specific
// Placement table and external-runtime launch arguments (#2507 S4 step 2). One table pins the
// case-marker placement; hooks/block-case-markers.js and placement.js must both answer it (the
// bash pre-commit predicates it was first checked against went with #2507). Holds no case markers.
// Assumed contracts: placement.js exports isCaseMarkerTarget(rel) / isReaderlessCaseMarkerTarget(rel)
// like block-case-markers.js; parts/external-runtime.js exports launchSpec(id, kind, { op, file,
// helper }) -> { command, args } for "pester" / "pytest", kind "reader" or "analyzer".
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const F = require("./fixture");

// [rel, target, readerless]
const PLACEMENT = [
  ["tests/bin/a.sh", true, false],
  ["tests/hooks/a.js", true, false],
  ["tests/skills/x.Tests.ps1", true, false],
  ["tests/agents/test_x.py", true, false],
  ["tests/tests/a.js", true, false],
  ["tests/install/a.sh", true, false],
  ["tests/a.sh", true, false],
  ["tests/a.js", true, false],
  ["tests/bin/test_x.txt", false, true],
  ["tests/bin/x.spec.ts", false, true],
  ["tests/install/test_y", false, true],
  ["tests/bin/readme.md", false, false],
  ["tests/bin/x.ps1", false, false],
  ["tests/_archive/a.sh", false, false],
  ["tests/lib/a.sh", false, false],
  ["tests/lib/test_x.txt", false, false],
  ["tests/run-all.sh", false, false],
  ["tests/bin/suite/a.sh", false, false],
  ["tests/bin/suite/test_x.txt", false, false],
  ["tests/other/a.sh", false, false],
  ["bin/a.sh", false, false],
  ["a.sh", false, false],
];

function checkTable(mod, label) {
  for (const [rel, target, readerless] of PLACEMENT) {
    assert.strictEqual(mod.isCaseMarkerTarget(rel), target, `${label}: target ${rel}`);
    assert.strictEqual(mod.isReaderlessCaseMarkerTarget(rel), readerless, `${label}: readerless ${rel}`);
  }
}

const placementHookJs = () => checkTable(require(path.join(F.REPO, "hooks", "block-case-markers.js")), "block-case-markers.js");
const placementNode = () => checkTable(require(path.join(F.REPO, "hooks", "lib", "test-gates", "placement.js")), "placement.js");

// The bash parts' launch lines: the reader is `<launch> <file>`, the analyzer `<launch> <op>
// <file> [helper]` with the helper library path for self-impl only. Paths are native (cygpath -m).
const PARTS = path.join(F.REPO, "bin", "lib", "test-language-parts");
const part = (n) => path.join(PARTS, n).replace(/\\/g, "/");
const LAUNCH = {
  pester: { command: "pwsh", pre: ["-NoProfile", "-NonInteractive", "-File"], reader: "pester-case-reader.ps1", analyzer: "pester-case-analyzer.ps1", sh: ["pester.sh", "pester-case-embed.sh"] },
  pytest: { command: "uv", pre: ["run", "--no-project", "python"], reader: "pytest-case-reader.py", analyzer: "pytest-case-analyzer.py", sh: ["pytest.sh", "pytest-case-embed.sh"] },
};

// Green now: the bash parts still carry the launch lines this table restates.
function launchLinesInBash() {
  for (const [id, l] of Object.entries(LAUNCH)) {
    const want = [l.command, ...l.pre].join(" ");
    for (const n of l.sh) assert.ok(fs.readFileSync(path.join(PARTS, n), "utf8").includes(want), `${n} launches ${want}`);
    for (const n of [l.reader, l.analyzer]) assert.ok(fs.existsSync(path.join(PARTS, n)), `${id}: ${n} exists`);
  }
}

function launchSpecNode() {
  const X = require(path.join(F.REPO, "hooks", "lib", "test-gates", "parts", "external-runtime.js"));
  const file = "C:/wt/tests/bin/x";
  const helper = "C:/rt/tests/lib/harness.x";
  const norm = (s) => ({ command: s.command, args: s.args.map((a) => String(a).replace(/\\/g, "/")) });
  for (const [id, l] of Object.entries(LAUNCH)) {
    assert.deepStrictEqual(norm(X.launchSpec(id, "reader", { file })), { command: l.command, args: [...l.pre, part(l.reader), file] }, `${id} reader`);
    for (const op of ["deps", "case-count", "syntax-check"]) {
      assert.deepStrictEqual(norm(X.launchSpec(id, "analyzer", { op, file, helper })), { command: l.command, args: [...l.pre, part(l.analyzer), op, file] }, `${id} analyzer ${op}`);
    }
    assert.deepStrictEqual(norm(X.launchSpec(id, "analyzer", { op: "self-impl", file, helper })),
      { command: l.command, args: [...l.pre, part(l.analyzer), "self-impl", file, helper] }, `${id} analyzer self-impl takes the helper`);
  }
}

module.exports = { PLACEMENT, placementHookJs, placementNode, launchLinesInBash, launchSpecNode };
