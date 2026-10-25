"use strict";
// Tests: hooks/lib/plans-artifact-registry.js, hooks/lib/plans-artifact-registry.json
// Tags: TL2, plans-dir, registry, review-tests, fallback-raw, continuing-marker, recovery, scope:issue-specific
// #2664 work unit 5-4 / 5-2a — the review_tests recovery reads two names the registry must know:
// the exit-3 fallback output <sid>-test-review-fallback-raw.md (an artifact kind already in the JSON
// table but with no path builder), and the exit-1/5 evidence test-review-continuing.txt (a new
// review-round-state control file beside test-review-terminal.txt).
// TL3 gap: none — the registry is a pure table; the readers are covered by
// tests/hooks/feature-2664-review-tests-recovery.js and the wrapper by
// tests/skills/feature-2664-review-tests-continuing-marker.sh.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2664r-"));
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const ROOT = path.resolve(__dirname, "..", "..");
const REG = require(path.join(ROOT, "hooks", "lib", "plans-artifact-registry.js"));
const SID = "0f3c2a1b-4d5e-4f60-8a7b-9c0d1e2f3a4b";
const PLANS = path.join(TMP, "plans");

caseBegin("fallback-raw-path-builder", "hooks/lib/plans-artifact-registry.js");
test("getPlansArtifactPath builds <plansDir>/<sid>-test-review-fallback-raw.md", () => {
  let got;
  try {
    got = REG.getPlansArtifactPath(SID, "test-review-fallback-raw", { plansDir: PLANS });
  } catch (e) {
    got = `threw: ${e.message}`;
  }
  assert.strictEqual(got, path.join(PLANS, `${SID}-test-review-fallback-raw.md`));
});
test("the built name still parses as the test-review-fallback-raw artifact", () => {
  const p = REG.parsePlansEntry(`${SID}-test-review-fallback-raw.md`);
  assert.deepStrictEqual(p && { sid: p.sid, kind: p.kind, verdict: p.verdict },
    { sid: SID, kind: "test-review-fallback-raw", verdict: "artifact" });
});
test("control: the neighbouring test-review builder is unchanged", () => {
  assert.strictEqual(REG.getPlansArtifactPath(SID, "test-review", { plansDir: PLANS }),
    path.join(PLANS, `${SID}-test-review.md`));
});
caseEnd();

caseBegin("continuing-marker-control-kind", "hooks/lib/plans-artifact-registry.json");
test("test-review-continuing.txt is a review-round-state control file", () => {
  const p = REG.parsePlansEntry(`${SID}-test-review-continuing.txt`);
  assert.deepStrictEqual(p && { sid: p.sid, kind: p.kind, verdict: p.verdict },
    { sid: SID, kind: "review-round-state", verdict: "control" });
});
test("and it is migratable like the terminal marker", () => {
  const re = (REG.MIGRATABLE_KINDS.find((k) => k.kind === "review-round-state") || {}).re;
  assert.ok(re, "review-round-state is a migratable kind");
  assert.ok(re.test("test-review-terminal.txt"), "terminal marker matches (control)");
  assert.ok(re.test("test-review-continuing.txt"), "continuing marker matches");
});
test("every review format gets the continuing name (the regex is format-generic)", () => {
  for (const fmt of REG.FORMAT_TOKENS) {
    assert.strictEqual(REG.classifyPlansEntry(`${SID}-${fmt}-continuing.txt`), "control", fmt);
  }
});
test("control: an unrelated suffix stays out of review-round-state", () => {
  const p = REG.parsePlansEntry(`${SID}-test-review-continuation.txt`);
  assert.ok(!p || p.kind !== "review-round-state", JSON.stringify(p));
});
caseEnd();
