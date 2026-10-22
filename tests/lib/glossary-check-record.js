"use strict";
// tests/lib/glossary-check-record.js — JS twin of glossary-check-record.sh (#2529).
// recordGlossaryCheck(sid, step, cwd): runs the checkout's own
// `bin/check-glossary-drift --session <sid> --stage <stage> --record` from `cwd` (the fixture
// repo whose index and glossary the record binds to), as a session does before completing a
// glossary-gated step. A failed record never throws: the completion that follows is the judge,
// where a record that did not land shows as a glossary-check-missing refusal.
// Call harness isolate() first: the child inherits the pinned WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR.

const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const ROOT = path.resolve(__dirname, "..", "..");
const STAGE_OF_STEP = {
  clarify_intent: "intent", outline: "outline", detail: "detail",
  review_tests: "tests", review_security: "code", review_docs: "docs",
};

// -> { code, out, err } of the CLI run; code is null for a step without a glossary stage.
function recordGlossaryCheck(sid, step, cwd) {
  const stage = STAGE_OF_STEP[step];
  if (!stage) return { code: null, out: "", err: `no glossary stage for ${step}` };
  const dir = cwd || os.tmpdir();
  const r = spawnSync(process.execPath, [path.join(ROOT, "bin", "check-glossary-drift"),
    "--session", sid, "--stage", stage, "--record"], {
    cwd: dir, encoding: "utf8", timeout: 60000,
    env: Object.assign({}, process.env, { CLAUDE_PROJECT_DIR: dir }),
  });
  return { code: r.status, out: r.stdout || "", err: (r.stderr || "") + (r.error ? String(r.error) : "") };
}

// completeWithRecord(sid, step, repo, markStep): records the step's glossary_check from `repo`,
// then runs markStep(sid, step, "complete") with `repo` as the process cwd — the completion
// boundary recomputes the fingerprint from the cwd git root, so both must see the same repo.
// A refusal is rethrown with the record's exit code and output prefixed to its message.
function completeWithRecord(sid, step, repo, markStep) {
  const rec = recordGlossaryCheck(sid, step, repo);
  const prev = process.cwd();
  process.chdir(repo);
  try {
    markStep(sid, step, "complete");
  } catch (e) {
    if (e && typeof e.message === "string") {
      const detail = String(rec.out + rec.err).replace(/[\r\n]+/g, " ").slice(0, 300);
      e.message = `[glossary record exit=${rec.code} ${detail}] ${e.message}`;
    }
    throw e;
  } finally {
    process.chdir(prev);
  }
}

module.exports = { STAGE_OF_STEP, recordGlossaryCheck, completeWithRecord };
