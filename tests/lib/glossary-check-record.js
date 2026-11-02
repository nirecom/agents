"use strict";
// tests/lib/glossary-check-record.js — JS twin of glossary-check-record.sh (#2529).
// recordGlossaryCheck(sid, step, cwd): runs the checkout's own
// `bin/check-glossary-drift --session <sid> --step <step> --record` from `cwd` (the fixture
// repo whose index and glossary the record binds to), as a session does before completing a
// glossary-gated step. A failed record never throws: the completion that follows is the judge,
// where a record that did not land shows as a glossary-check-missing refusal.
// Call harness isolate() first: the child inherits the pinned WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR.

const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const ROOT = path.resolve(__dirname, "..", "..");
const GLOSSARY_STEPS = ["clarify_intent", "outline", "detail", "review_tests", "review_security", "review_docs"];
// Legacy stage name of each glossary step (pre-#2820 records and --stage); callers that only need
// the set of glossary steps read its keys, which equal GLOSSARY_STEPS.
const STAGE_OF_STEP = {
  clarify_intent: "intent", outline: "outline", detail: "detail",
  review_tests: "tests", review_security: "code", review_docs: "docs",
};

// -> { code, out, err } of the CLI run; code is null for a step without a glossary check.
function recordGlossaryCheck(sid, step, cwd) {
  if (!GLOSSARY_STEPS.includes(step)) return { code: null, out: "", err: `no glossary check for ${step}` };
  const dir = cwd || os.tmpdir();
  const r = spawnSync(process.execPath, [path.join(ROOT, "bin", "check-glossary-drift"),
    "--session", sid, "--step", step, "--record"], {
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

module.exports = { GLOSSARY_STEPS, STAGE_OF_STEP, recordGlossaryCheck, completeWithRecord };
