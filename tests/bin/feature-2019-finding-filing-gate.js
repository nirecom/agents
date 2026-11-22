"use strict";
// tests/bin/feature-2019-finding-filing-gate.js
// Tests: bin/finding-filing-gate
// Tags: TL2, bin, issue-create, confirm-gate, g0, finding-approval, severity, proposal-sha256, fail-closed, table-driven, scope:issue-specific
// #2019 S4-4: finding-filing-gate prints `g0: pass|confirm|defer` + `reason:` — pass on a consumed
// approval record or the HIGH auto condition (HIGH claim, `## Severity` HIGH — reason, reviewer HIGH,
// matching proposal_sha256); defer on a HIGH claim the reviewer could not judge; confirm otherwise.
// Assumption: the claim JSON carries severity/title/body at the top level and under `proposal`.
// The eval-confirm-gate.sh wiring: tests/skills/feature-2019-finding-filing-gate.sh.
// TL3 gap: the live Phase 3 hand-off (SKILL.md 3f/3g) and a real codex review.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2019g-"));
after(() => { restore(); fs.rmSync(SCRATCH, { recursive: true, force: true }); });
fs.mkdirSync(path.join(SCRATCH, "transcripts"));
fs.mkdirSync(path.join(SCRATCH, "cwd"));

const ROOT = path.resolve(__dirname, "..", "..");
const GATE = path.join(ROOT, "bin", "finding-filing-gate");
const SID = "5e1d2c3b-2019-4e01-8a9b-0c1d2e3f4e01";
const APPROVAL = path.join(process.env.WORKFLOW_STATE_DIR, `${SID}.finding-filing-approval`);
const CLAIM = path.join(SCRATCH, "claim.json");
const REVIEW = path.join(SCRATCH, "review.json");
const HIGH_BODY = "Crash on save.\n\n## Severity\nHIGH — data loss on every save of a CRLF file";
const ZERO_SHA = "0".repeat(64);

// approval(records) — a fresh approval file whose records carry `at` = now.
function approval(records) {
  const at = new Date().toISOString();
  fs.writeFileSync(APPROVAL, JSON.stringify({ version: 1, session_id: SID, pending: [], records: records.map((r) => Object.assign({ at }, r)) }));
}
// claim(severity, body) — the proposal JSON (top level and under `proposal`).
function claim(severity, body) {
  const p = { title: "Save crashes", severity, body };
  fs.writeFileSync(CLAIM, JSON.stringify(Object.assign({ proposal: p }, p)));
}
const sha = (file) => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
// review(status, severity|null, sha|null) — a final-artifact-shaped review; null omits the field.
function review(status, severity, proposalSha) {
  const r = { status };
  if (severity !== null) r.severity = severity;
  if (proposalSha !== null) r.proposal_sha256 = proposalSha;
  fs.writeFileSync(REVIEW, JSON.stringify({ verdict: "none", survey: { verdict: "none" }, review: r }));
}
// g0(args) -> { g0: the verdict word, reasons: count of `reason:` lines }.
function g0(args) {
  const env = Object.assign({}, process.env, { CLAUDE_TRANSCRIPT_BASE_DIR: path.join(SCRATCH, "transcripts") });
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, [GATE, ...args], { env, cwd: path.join(SCRATCH, "cwd"), encoding: "utf8", timeout: 60000 });
  const out = String(r.stdout || "");
  const m = /^g0: (.*)$/m.exec(out);
  return { g0: m ? m[1] : "", reasons: (out.match(/^reason:/gm) || []).length };
}
const gate = (...extra) => g0(["--session", SID, "--review", REVIEW, "--claim", CLAIM, ...extra]);
const hasRecord = (s) => fs.existsSync(APPROVAL) && fs.readFileSync(APPROVAL, "utf8").includes(s);

caseBegin("pass-on-approval-record", "bin/finding-filing-gate");
test("pass-on-approval-record: one record passes once; a keyed answer passes only its key", () => {
  claim("MEDIUM", "Save is slow.");
  review("upheld", "MEDIUM", sha(CLAIM));
  approval([{ type: "typed-command" }]);
  const first = gate();
  assert.strictEqual(first.g0, "pass", "typed-command record: pass");
  assert.strictEqual(first.reasons, 1, "exactly one reason line");
  assert.strictEqual(gate().g0, "confirm", "the record is spent");
  approval([{ type: "askuser-answer", dialog_id: "issue-create.confirm-gate", keys: ["9a9a1b1b"] }]);
  assert.strictEqual(gate("--finding-key", "0f0f0f0f").g0, "confirm", "another key: confirm");
  assert.strictEqual(gate("--finding-key", "9a9a1b1b").g0, "pass", "the answered key: pass");
  assert.strictEqual(gate("--finding-key", "9a9a1b1b").g0, "confirm", "the answer is spent");
  fs.rmSync(APPROVAL, { force: true });
  assert.strictEqual(gate().g0, "confirm", "no approval file: confirm");
});
caseEnd();

caseBegin("typed-command-files-a-low-claim", "bin/finding-filing-gate");
test("typed-command-files-a-low-claim: the typed /issue-create passes a LOW claim once", () => {
  claim("LOW", "Log wording is unclear.");
  review("upheld", "LOW", sha(CLAIM));
  approval([{ type: "typed-command" }]);
  assert.strictEqual(gate().g0, "pass", "LOW claim with a typed-command record: pass");
  assert.ok(!hasRecord("typed-command"), "the typed-command record is consumed");
  assert.strictEqual(gate().g0, "confirm", "second run: confirm");
  fs.rmSync(APPROVAL, { force: true });
});
caseEnd();

caseBegin("high-auto-condition", "bin/finding-filing-gate");
test("high-auto-condition: HIGH claim + evidence + reviewer HIGH + same sha passes without consuming", () => {
  claim("HIGH", HIGH_BODY);
  approval([{ type: "typed-command" }]);
  for (const st of ["upheld", "disputed"]) {
    review(st, "HIGH", sha(CLAIM));
    assert.strictEqual(gate().g0, "pass", `${st}: pass`);
  }
  assert.ok(hasRecord("typed-command"), "auto pass does not consume the approval");
  fs.rmSync(APPROVAL, { force: true });
});
caseEnd();

caseBegin("high-without-evidence-or-same-review-confirms", "bin/finding-filing-gate");
test("high-without-evidence-or-same-review-confirms: each missing leg of the auto condition confirms", () => {
  // [name, body, review severity, sha mode]
  const ROWS = [
    ["no Severity section", "Crash on save.", "HIGH", "match"],
    ["Severity without a reason", "Crash.\n\n## Severity\nHIGH", "HIGH", "match"],
    ["Severity says MEDIUM", "Crash.\n\n## Severity\nMEDIUM — minor", "HIGH", "match"],
    ["reviewer says MEDIUM", "Crash.\n\n## Severity\nHIGH — data loss", "MEDIUM", "match"],
    ["proposal_sha256 differs", "Crash.\n\n## Severity\nHIGH — data loss", "HIGH", "other"],
    ["proposal_sha256 missing", "Crash.\n\n## Severity\nHIGH — data loss", "HIGH", "none"],
  ];
  for (const [name, body, rsev, shaMode] of ROWS) {
    claim("HIGH", body);
    const s = shaMode === "match" ? sha(CLAIM) : shaMode === "other" ? ZERO_SHA : null;
    review("upheld", rsev, s);
    assert.strictEqual(gate().g0, "confirm", `${name}: confirm`);
  }
});
caseEnd();

caseBegin("high-with-reviewer-unavailable-defers", "bin/finding-filing-gate");
test("high-with-reviewer-unavailable-defers: an unjudged HIGH claim defers; MEDIUM confirms", () => {
  claim("HIGH", HIGH_BODY);
  // [name, status, severity] — fallback-shaped (skipped), codex-shaped invalid, out-of-vocabulary, missing.
  const ROWS = [
    ["fallback skipped review", "skipped", null],
    ["codex invalid review", "invalid", null],
    ["out-of-vocabulary severity", "upheld", "SEVERE"],
    ["severity missing", "upheld", null],
  ];
  for (const [name, st, rsev] of ROWS) {
    review(st, rsev, sha(CLAIM));
    assert.strictEqual(gate().g0, "defer", `${name}: defer`);
  }
  claim("MEDIUM", "Slow.");
  review("invalid", null, null);
  assert.strictEqual(gate().g0, "confirm", "MEDIUM claim with an invalid review: confirm");
});
caseEnd();

caseBegin("bad-input-fails-closed", "bin/finding-filing-gate");
test("bad-input-fails-closed: missing review, broken claim, no --session never pass", () => {
  claim("HIGH", HIGH_BODY);
  review("upheld", "HIGH", sha(CLAIM));
  assert.strictEqual(g0(["--session", SID, "--review", path.join(SCRATCH, "no-such.json"), "--claim", CLAIM]).g0, "confirm", "missing review: confirm");
  const broken = path.join(SCRATCH, "broken.json");
  fs.writeFileSync(broken, "{ not json");
  assert.strictEqual(g0(["--session", SID, "--review", REVIEW, "--claim", broken]).g0, "confirm", "broken claim: confirm");
  assert.strictEqual(g0(["--review", REVIEW, "--claim", CLAIM]).g0, "confirm", "no --session: confirm");
});
caseEnd();

caseBegin("high-with-reviewer-unavailable-consumes-approval", "bin/finding-filing-gate");
test("high-with-reviewer-unavailable-consumes-approval: an approval record turns the defer into a pass", () => {
  claim("HIGH", HIGH_BODY);
  review("invalid", null, sha(CLAIM));
  approval([{ type: "typed-command" }]);
  assert.strictEqual(gate().g0, "pass", "HIGH claim, no reviewer severity, approval present: pass");
  assert.ok(!hasRecord("typed-command"), "the approval record is consumed");
  assert.strictEqual(gate().g0, "defer", "record spent: back to defer");
  fs.rmSync(APPROVAL, { force: true });
});
caseEnd();
