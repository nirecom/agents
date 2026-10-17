"use strict";
// Tests: hooks/block-clearance-token-write/placement-guard.js, hooks/lib/plans-artifact-registry.json
// Tags: TL2, hooks, jev, placement-guard, plans-unregistered, registry, classifier, scope:issue-specific
// #2677: the Jev two-stage answer file (<sid>-jev-<16hex>-answer.txt) the backup subagent writes
// is a registered plans artifact, so the placement guard lets the Write through; the snapshot and
// a non-ticket-shaped name stay unregistered (the kind regex is no wider than the ticket shape).
// TL3 gap (what this test does NOT catch):
// - a real subagent Write going through the PreToolUse hook on a live session
// Closest-to-action mitigation: tests/bin/feature-2460-jev-judge.sh drives the CLI answer path.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { after, test } = require("node:test");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..");
const GUARD_JS = path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "block-clearance-token-write", "placement-guard.js");
const REGISTRY_JSON = path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "plans-artifact-registry.json");
const SID = "aa000000-0000-4000-8000-000000002677";
const TID = "0123456789abcdef";

// Both workflow dirs pinned into a temp tree before the guard module loads (fixture isolation).
const restore = isolate();
after(restore);
const PLANS = process.env.WORKFLOW_PLANS_DIR;
fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, `${SID}.json`), "{}");
const { classifyPlacement } = require(GUARD_JS);
// wsid given explicitly, so the guard never spawns git to resolve one.
const CTX = { sid: SID, wsid: SID };
const verdict = (name) => classifyPlacement(path.join(PLANS, name), CTX);

caseBegin("answer-file-allowed-in-plans-dir", "hooks/block-clearance-token-write/placement-guard.js");
test("the ticket answer file <sid>-jev-<16hex>-answer.txt is allowed (null)", () => {
  assert.strictEqual(verdict(`${SID}-jev-${TID}-answer.txt`), null);
});
caseEnd();

caseBegin("answer-file-controls-stay-blocked", "hooks/block-clearance-token-write/placement-guard.js");
test("control: a non-16-hex ticket in the answer name stays plans-unregistered", () => {
  assert.strictEqual(verdict(`${SID}-jev-XYZ-answer.txt`), "plans-unregistered");
});
test("control: a 15-hex ticket stays plans-unregistered", () => {
  assert.strictEqual(verdict(`${SID}-jev-${TID.slice(1)}-answer.txt`), "plans-unregistered");
});
test("control: the ticket snapshot stays plans-unregistered", () => {
  assert.strictEqual(verdict(`${SID}-jev-${TID}-snapshot.md`), "plans-unregistered");
});
test("control: the answer name with an extra suffix stays plans-unregistered", () => {
  assert.strictEqual(verdict(`${SID}-jev-${TID}-answer.txt.bak`), "plans-unregistered");
});
caseEnd();

caseBegin("registry-declares-jev-answer-artifact", "hooks/lib/plans-artifact-registry.json");
test("artifactKinds has kind jev-answer, retention non-plan, and no control kind claims it", () => {
  const reg = JSON.parse(fs.readFileSync(REGISTRY_JSON, "utf8"));
  const hits = (reg.artifactKinds || []).filter((k) => k.kind === "jev-answer");
  assert.strictEqual(hits.length, 1, "exactly one jev-answer artifact kind");
  assert.strictEqual(hits[0].retention, "non-plan");
  const re = new RegExp(`^(?:${hits[0].source})$`);
  assert.strictEqual(re.test(`jev-${TID}-answer.txt`), true, "source matches the ticket answer name");
  assert.strictEqual(re.test(`jev-${TID}-snapshot.md`), false, "source does not match the snapshot");
  assert.strictEqual((reg.controlKinds || []).some((k) => k.kind === "jev-answer"), false);
});
caseEnd();
