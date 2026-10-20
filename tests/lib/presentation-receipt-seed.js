"use strict";
// tests/lib/presentation-receipt-seed.js
// Tests: tests/lib/presentation-receipt-seed.js
// Tags: test-infrastructure, shared-lib, presentation-receipt, confirm-checkpoint, fixture, scope:common
// #2729: confirm-checkpoint reaches the dialog only through a presentation receipt the Stop hook
// wrote. A test whose subject is the dialog itself seeds that receipt here, in the same env the
// hook runs in (state dir, plans dir, publish stub), instead of relying on a fail-open path.
// CLI: node presentation-receipt-seed.js <sid> <stage>  -> prints the receipt path, or NONE.
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const ROOT = path.resolve(__dirname, "..", "..");
// The reasons for which no URL can be made, so the Stop hook writes a path receipt (spec: UNPUBLISHABLE_REASONS).
const UNPUBLISHABLE = new Set(["plan-sync-off", "not-provisioned", "host-mismatch", "no-project-host", "unknown-forge"]);

function stateDir(sid) {
  return require(path.join(ROOT, "hooks/workflow-state")).getSessionStateDir(sid);
}

function receiptPath(sid, stage) {
  return path.join(stateDir(sid), `${sid}.confirm-plan-receipt-${stage}.json`);
}

// canonicalPlan(sid, stage) -> <plans>/<sid>-<stage>.md, the only artifact the judge accepts.
function canonicalPlan(sid, stage) {
  const { toWindowsPath } = require(path.join(ROOT, "hooks/lib/branch-diff"));
  const dir = require(path.join(ROOT, "hooks/lib/workflow-plans-dir")).getWorkflowPlansDir();
  return path.resolve(toWindowsPath(path.join(dir, `${sid}-${stage}.md`)));
}

// receiptLinkFor(absPath) -> {kind, value} as the Stop hook records it, or null when the plan
// could have a URL but is not published (the Stop hook writes no receipt then).
function receiptLinkFor(absPath) {
  const link = require(path.join(ROOT, "hooks/lib/plan-link")).linkForFile(absPath);
  if (link && typeof link.url === "string" && /^https?:\/\//.test(link.url)) return { kind: "url", value: link.url };
  if (link && UNPUBLISHABLE.has(link.reason)) return { kind: "path", value: absPath };
  return null;
}

// seedReceipt(sid, stage, {link}) -> the receipt path, or null when the plan is missing or unpublished.
function seedReceipt(sid, stage, opts) {
  const absPath = canonicalPlan(sid, stage);
  if (!fs.existsSync(absPath)) return null;
  const link = (opts && opts.link) || receiptLinkFor(absPath);
  if (!link) return null;
  const body = {
    absPath, link,
    contentSha: crypto.createHash("sha256").update(fs.readFileSync(absPath)).digest("hex"),
    anchorUuid: "a-seeded", writtenAt: new Date().toISOString(),
  };
  const p = receiptPath(sid, stage);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(body));
  return p;
}

const receiptExists = (sid, stage) => fs.existsSync(receiptPath(sid, stage));

module.exports = { UNPUBLISHABLE, receiptPath, canonicalPlan, receiptLinkFor, seedReceipt, receiptExists };

if (require.main === module) {
  const [sid, stage] = process.argv.slice(2);
  let out = null;
  try { out = seedReceipt(sid, stage); } catch (_) { out = null; }
  process.stdout.write(out || "NONE");
}
