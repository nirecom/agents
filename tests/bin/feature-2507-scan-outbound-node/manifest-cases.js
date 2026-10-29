"use strict";
// Case 12 (TL2, review gap C2): malformed --manifest streams through bin/scan-outbound.sh.
// golden/manifest.json records what bash did for every row, matched text kept only as a sha256.
// expect "golden" rows must equal that record; expect "rc4" rows must stop with rc 4 (the port's
// fail-closed rule), whatever bash recorded, so they stay red until the port lands.

const assert = require("node:assert");
const crypto = require("node:crypto");
const { golden } = require("./common");
const SB = require("./sandbox");
const C = require("./corpus");
const M = require("./manifest-corpus");

const sha = (s) => crypto.createHash("sha256").update(s, "utf8").digest("hex");
const LINE_RE = /^(.*?):(\d+): \[([^\]]+)\] (.*)$/;

// stdout -> findings with the matched text hashed; non-finding lines (the summary) are dropped.
function record(r) {
  const findings = [];
  for (const l of r.stdout.split("\n")) {
    const m = LINE_RE.exec(l);
    if (m) findings.push({ file: m[1], line: Number(m[2]), kind: m[3], matchedSha256: sha(m[4]) });
  }
  return { rc: r.rc, stderrSha256: sha(r.stderr), findings };
}

function runOne(root, c) {
  SB.setLists(root, C.LISTS.empty);
  return SB.runCli(root, { argv: ["--manifest"], stdin: c.stdin });
}

function runRows(root, expect) {
  const g = golden("manifest").cases;
  assert.strictEqual(Object.keys(g).length, M.MANIFEST_CASES.length, "golden records every stream (regenerate after editing)");
  const rows = M.MANIFEST_CASES.filter((c) => c.expect === expect);
  assert.ok(rows.length > 0, `rows with expect ${expect} exist`);
  const failures = [];
  for (const c of rows) {
    const want = g[c.name];
    assert.ok(want, `${c.name}: recorded in the golden`);
    const r = runOne(root, c);
    assert.strictEqual(r.error, undefined, `${c.name}: spawn error ${r.error}`);
    const got = record(r);
    try {
      if (c.expect === "rc4") {
        assert.strictEqual(got.rc, 4, `${c.name}: a broken frame stops the scan with rc 4 (bash recorded rc ${want.rc})`);
      } else {
        assert.strictEqual(got.rc, want.rc, `${c.name}: rc`);
        assert.deepStrictEqual(got.findings, want.findings, `${c.name}: findings (file, line, kind, sha256 of the match)`);
        assert.ok(got.findings.some((f) => f.matchedSha256 === sha(M.AFTER) && f.file === "after.txt"), `${c.name}: after.txt secret reported`);
        assert.strictEqual(got.stderrSha256, want.stderrSha256, `${c.name}: stderr`);
      }
    } catch (e) {
      failures.push(e.message.split("\n")[0]);
    }
  }
  assert.deepStrictEqual(failures, [], `every expect-${expect} stream meets its expectation`);
}

const runManifestGolden = (root) => runRows(root, "golden");
const runManifestFailClosed = (root) => runRows(root, "rc4");

module.exports = { runManifestGolden, runManifestFailClosed, record, runOne };
