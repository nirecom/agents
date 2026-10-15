"use strict";
// tests/lib/finalized-ticket.js — plants the finalized cli-ticket claim that
// record-skip-judgment's verifyTicket looks for (#2460), for tests that call that CLI
// without running a jev-judge query/finalize first.
// Usage: node finalized-ticket.js <repo-root> <sid> <target> <ticket> <conds-json> <source> [field=json ...]
// The claim fingerprints the stage sources as they are NOW, so plant it after the plan
// artifacts exist. field=json overrides one top-level claim field (finalized=false,
// session_id="other", artifacts_sha256={"intent":"0"} ...) to plant a claim that must be refused.
// Refuses to run unless AGENTS_STATE_DIR is pinned: the claim never lands in a real home.

const fs = require("fs");
const path = require("path");

const [root, sid, target, ticket, condsJson, source, ...overrides] = process.argv.slice(2);

if (!process.env.AGENTS_STATE_DIR) {
  process.stderr.write("finalized-ticket: AGENTS_STATE_DIR is not pinned\n");
  process.exit(2);
}
if (!root || !sid || !target || !ticket || !condsJson || !source) {
  process.stderr.write("finalized-ticket: missing argument\n");
  process.exit(2);
}

const { pendingDir, PENDING_VERSION } = require(path.join(root, "hooks", "lib", "jev", "pending.js"));
const { artifactSha } = require(path.join(root, "hooks", "lib", "jev", "two-stage", "source-fresh.js"));
const { MAX_ARTIFACT_READ_BYTES, artifactPathsFor, readCappedBytes } = require(
  path.join(root, "bin", "workflow", "lib", "jev-request-common.js"));

const stage = target;
const artifacts = {};
for (const art of artifactPathsFor(sid, stage)) {
  artifacts[art.section] = artifactSha(readCappedBytes(art.file, MAX_ARTIFACT_READ_BYTES));
}

const claim = {
  version: PENDING_VERSION, kind: "cli-ticket", finalized: true, session_id: sid, ticket,
  point: `${target}-skip`, stage, target, created_ms: Date.now(), artifacts_sha256: artifacts,
  result: { target, source, conditions: JSON.parse(condsJson) },
};
for (const kv of overrides) {
  const eq = kv.indexOf("=");
  claim[kv.slice(0, eq)] = JSON.parse(kv.slice(eq + 1));
}

const dir = pendingDir(sid);
fs.mkdirSync(dir, { recursive: true });
const file = path.join(dir, `${ticket}.claimed-${process.pid}`);
fs.writeFileSync(file, JSON.stringify(claim));
process.stdout.write(file + "\n");
