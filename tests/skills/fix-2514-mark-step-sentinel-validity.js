"use strict";
// Tests: hooks/workflow-mark/mark-step-handler.js, hooks/lib/sentinel-patterns.js
// Tags: fix-2514, fix-1981, skills, sentinel, mark-step, static-scan, scope:common, TL1, pwsh-not-required, workflow-mark, refusal, TL2, prototype-key, glossary
// #2514: a skill document told the model to emit a MARK_STEP sentinel that no workflow step
// accepts (l2_findings_surfaced_complete, docs_complete, plan_complete). Every MARK_STEP literal
// under skills/**/*.md must name a VALID_STEPS step, match MARKER_RE_DQ, and not be a step that
// mark-step-handler.js always refuses (REFUSED_MARK_STEPS, read from the export, never copied).
// #1981: detector (d) flags a sentinel echo written into the same Bash call as another command.
// The handler cases (TL2) pin the table's refusal wording and the unchanged state; write_tests
// (refused only without test evidence) and the run_tests skip stay outside the table.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");

const ROOT = path.resolve(__dirname, "..", "..");
const SKILLS = path.join(ROOT, "skills");
const { VALID_STEPS } = require(path.join(ROOT, "hooks", "workflow-state", "state-io", "core.js"));
const { MARKER_RE_DQ } = require(path.join(ROOT, "hooks", "lib", "sentinel-patterns.js"));

const restoreIsolation = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "fix2514-static-"));
// The hook fixture is built on first use, so the static cases never depend on it.
let fixture = null;
const fx = () => fixture || (fixture = require("../hooks/feature-2824-sentinel-refusal-output/fixture").make());
after(() => {
  if (fixture) fixture.cleanup();
  restoreIsolation();
  fs.rmSync(TMP, { recursive: true, force: true });
});

// The refused table comes from the handler; a missing export is "not implemented", not an empty set.
function refusedMarkSteps() {
  const mod = require(path.join(ROOT, "hooks", "workflow-mark", "mark-step-handler.js"));
  const t = mod.REFUSED_MARK_STEPS;
  if (!t || typeof t !== "object") {
    throw new Error("not implemented: mark-step-handler.js does not export REFUSED_MARK_STEPS");
  }
  return t;
}

const LITERAL_RE = /WORKFLOW_MARK_STEP_([A-Za-z0-9_]+?)_(complete|skipped|pending|in_progress)(?![A-Za-z0-9_])/g;
const SENTINEL_ECHO_RE = /echo\s+(["'])<<WORKFLOW_[^>]*>>\1/g;
const FENCE_OPEN_RE = /^\s*```(bash|sh|shell)\s*$/;
const FENCE_CLOSE_RE = /^\s*```\s*$/;
const INLINE_SPAN_RE = /`([^`\n]*<<WORKFLOW_[^`\n]*)`/g;

function walkMd(dir) {
  const out = [];
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) out.push(...walkMd(p));
    else if (ent.isFile() && ent.name.endsWith(".md")) out.push(p);
  }
  return out;
}

// literalsOf(text) -> [{step, status, line}] for every MARK_STEP literal; templates do not match.
function literalsOf(text) {
  const out = [];
  text.split(/\r?\n/).forEach((l, i) => {
    for (const m of l.matchAll(LITERAL_RE)) out.push({ step: m[1], status: m[2], line: i + 1 });
  });
  return out;
}

// literalFaults(lit, refused) -> the reasons a literal is not an accepted MARK_STEP sentinel.
function literalFaults(lit, refused) {
  const faults = [];
  if (!VALID_STEPS.includes(lit.step)) faults.push(`(a) "${lit.step}" is not in VALID_STEPS`);
  if (!MARKER_RE_DQ.test(`echo "<<WORKFLOW_MARK_STEP_${lit.step}_${lit.status}>>"`)) {
    faults.push(`(b) "${lit.step}_${lit.status}" does not match MARKER_RE_DQ`);
  }
  if (refused && Object.prototype.hasOwnProperty.call(refused, lit.step)) {
    faults.push(`(c) "${lit.step}" is always refused by mark-step-handler.js`);
  }
  return faults;
}

// A command line that chains a sentinel echo with `;`, or with a non-sentinel command through `&&`.
// Sentinel echoes are masked first, so a `;` inside a sentinel's reason text is not a boundary.
const MASK = "\u0000S\u0000";
function mixedLine(line) {
  SENTINEL_ECHO_RE.lastIndex = 0;
  const masked = line.replace(SENTINEL_ECHO_RE, MASK).replace(/\s#.*$/, "");
  SENTINEL_ECHO_RE.lastIndex = 0;
  if (!masked.includes(MASK)) return false;
  if (masked.includes(";")) return true;
  const parts = masked.split("&&").map((p) => p.trim());
  return parts.length > 1 && parts.some((p) => p !== "" && p !== MASK);
}

const isSentinelLine = (l) => {
  const t = l.trim();
  SENTINEL_ECHO_RE.lastIndex = 0;
  const hit = t !== "" && t.replace(SENTINEL_ECHO_RE, "").replace(/&&/g, "").trim() === "";
  SENTINEL_ECHO_RE.lastIndex = 0;
  return hit;
};

// mixedCallFaults(text) -> [{line, why}] for detector (d).
function mixedCallFaults(text) {
  const lines = text.split(/\r?\n/);
  const faults = [];
  let block = null;
  lines.forEach((l, i) => {
    if (block === null) {
      if (FENCE_OPEN_RE.test(l)) { block = { start: i + 1, lines: [] }; return; }
      for (const m of l.matchAll(INLINE_SPAN_RE)) {
        if (mixedLine(m[1])) faults.push({ line: i + 1, why: `inline span chains a sentinel: ${m[1]}` });
      }
      return;
    }
    if (FENCE_CLOSE_RE.test(l)) {
      const code = block.lines.filter((x) => x.text.trim() !== "" && !x.text.trim().startsWith("#"));
      const sentinels = code.filter((x) => isSentinelLine(x.text));
      for (const x of code) {
        if (mixedLine(x.text)) faults.push({ line: x.no, why: `line chains a sentinel: ${x.text.trim()}` });
      }
      if (sentinels.length > 0 && code.length > 1) {
        faults.push({ line: block.start, why: `fenced block mixes a sentinel echo with ${code.length - 1} other line(s)` });
      }
      block = null;
      return;
    }
    block.lines.push({ no: i + 1, text: l });
  });
  return faults;
}

const FILES = walkMd(SKILLS);
const rel = (p) => path.relative(ROOT, p).replace(/\\/g, "/");

caseBegin("scan-scope-is-non-empty-and-yields-literals", "hooks/lib/sentinel-patterns.js");
test("scan-scope-is-non-empty-and-yields-literals", () => {
  assert.ok(FILES.length > 0, "skills/**/*.md is empty");
  const n = FILES.reduce((acc, f) => acc + literalsOf(fs.readFileSync(f, "utf8")).length, 0);
  assert.ok(n > 0, "no MARK_STEP literal found under skills/; the extraction regex is broken");
  assert.ok(VALID_STEPS.length > 0 && VALID_STEPS.includes("final_report"), "VALID_STEPS did not load");
});
caseEnd();

caseBegin("every-skill-mark-step-literal-is-accepted", "hooks/workflow-mark/mark-step-handler.js");
test("every-skill-mark-step-literal-is-accepted", () => {
  const refused = refusedMarkSteps();
  const bad = [];
  for (const f of FILES) {
    const text = fs.readFileSync(f, "utf8");
    for (const lit of literalsOf(text)) {
      for (const why of literalFaults(lit, refused)) bad.push(`${rel(f)}:${lit.line} ${why}`);
    }
    for (const d of mixedCallFaults(text)) bad.push(`${rel(f)}:${d.line} (d) ${d.why}`);
  }
  assert.deepStrictEqual(bad, [], `skills/ carries sentinels no step accepts:\n${bad.join("\n")}`);
});
caseEnd();

caseBegin("known-dead-sentinels-are-gone-from-skills", "hooks/lib/sentinel-patterns.js");
test("known-dead-sentinels-are-gone-from-skills", () => {
  const dead = ["l2_findings_surfaced_complete", "WORKFLOW_MARK_STEP_plan_complete", "WORKFLOW_MARK_STEP_docs_complete"];
  // The bare step token (an un-prefixed "emit docs_complete" instruction) is dead too.
  const BARE_DOCS_RE = /(?<![A-Za-z0-9_])docs_complete(?![A-Za-z0-9_])/;
  const bareMatrix = [
    [true, "docs_complete"], [true, "emit `docs_complete` now"], [true, "(docs_complete)"],
    [false, "review_docs_complete"], [false, "WORKFLOW_MARK_STEP_review_docs_complete"], [false, "docs_completed"],
  ];
  const wrong = bareMatrix.filter(([want, s]) => BARE_DOCS_RE.test(s) !== want).map(([want, s]) => `${s}: want ${want}`);
  assert.deepStrictEqual(wrong, [], `bare docs_complete regex is wrong:\n${wrong.join("\n")}`);
  const hits = [];
  for (const f of FILES) {
    fs.readFileSync(f, "utf8").split(/\r?\n/).forEach((l, i) => {
      for (const d of dead) if (l.includes(d)) hits.push(`${rel(f)}:${i + 1} ${d}`);
      if (BARE_DOCS_RE.test(l)) hits.push(`${rel(f)}:${i + 1} bare docs_complete`);
    });
  }
  assert.deepStrictEqual(hits, [], `dead sentinels remain:\n${hits.join("\n")}`);
});
caseEnd();

// Detector matrix: each fixture document is scanned by the same functions as the real tree.
const FENCE = "```";
const MATRIX = [
  ["hit", "step-with-digit", 'echo "<<WORKFLOW_MARK_STEP_l2_x_complete>>"'],
  ["hit", "unknown-step", 'echo "<<WORKFLOW_MARK_STEP_foo_complete>>"'],
  ["hit", "refused-step-docs", 'echo "<<WORKFLOW_MARK_STEP_docs_complete>>"'],
  ["hit", "fenced-block-with-command", `${FENCE}bash\nnode x\necho "<<WORKFLOW_MARK_STEP_final_report_complete>>"\n${FENCE}`],
  ["hit", "semicolon-chain", '`cmd; echo "<<WORKFLOW_MARK_STEP_final_report_complete>>"`'],
  ["hit", "and-chain-with-command", '`cmd && echo "<<WORKFLOW_MARK_STEP_final_report_complete>>"`'],
  ["miss", "standalone-valid", '`echo "<<WORKFLOW_MARK_STEP_final_report_complete>>"`'],
  ["miss", "sentinel-only-and-chain",
    '`echo "<<WORKFLOW_MARK_STEP_research_complete>>" && echo "<<WORKFLOW_MARK_STEP_detail_complete>>"`'],
  ["miss", "template-step", 'echo "<<WORKFLOW_MARK_STEP_<step>_complete>>" and WORKFLOW_MARK_STEP_${step}_complete'],
  ["miss", "fenced-single-sentinel", `${FENCE}bash\n# mark it\necho "<<WORKFLOW_MARK_STEP_final_report_complete>>"\n${FENCE}`],
];

function scanFixture(name, body, refused) {
  const f = path.join(TMP, `${name}.md`);
  fs.writeFileSync(f, `# fixture\n\n${body}\n`);
  const text = fs.readFileSync(f, "utf8");
  const faults = [];
  for (const lit of literalsOf(text)) faults.push(...literalFaults(lit, refused));
  for (const d of mixedCallFaults(text)) faults.push(`(d) ${d.why}`);
  return faults;
}

caseBegin("detector-matrix-hits-and-misses", "hooks/lib/sentinel-patterns.js");
test("detector-matrix-hits-and-misses", () => {
  // docs is the only refused row; it is pinned through the real table (S4 checks the table).
  let refused;
  try { refused = refusedMarkSteps(); } catch (_) { refused = null; }
  const wrong = [];
  for (const [want, name, body] of MATRIX) {
    if (name === "refused-step-docs" && refused === null) {
      wrong.push(`${name}: not implemented: REFUSED_MARK_STEPS export is missing`);
      continue;
    }
    const faults = scanFixture(name, body, refused);
    if (want === "hit" && faults.length === 0) wrong.push(`${name}: expected a fault, got none`);
    if (want === "miss" && faults.length > 0) wrong.push(`${name}: expected no fault, got ${faults.join("; ")}`);
  }
  assert.deepStrictEqual(wrong, [], wrong.join("\n"));
});
caseEnd();

// The wording each always-refused step carries today; the move into the table keeps it verbatim.
const WORDING = {
  user_verification:
    `workflow-mark: user_verification NOT recorded — MARK_STEP sentinel is rejected for this step. ` +
    `Ask the user for commit approval via: echo "<<WORKFLOW_USER_VERIFIED: {reason}>>" ` +
    `(reason: >=3 non-space chars, no '>', not a placeholder)`,
  review_tests:
    `workflow-mark: review_tests NOT recorded — MARK_STEP not accepted for this step. ` +
    `Invoke /review-tests skill (which auto-computes the review-scope fingerprint) ` +
    `OR declare not needed: echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: {reason}>>"`,
  docs:
    `workflow-mark: docs NOT recorded — MARK_STEP not accepted for this step. ` +
    `Run /update-docs, then satisfy either route: ` +
    `(a) stage docs/ or *.md files (git add docs/ ...); or ` +
    `(b) inside a linked worktree, ensure WORKTREE_NOTES.md ` +
    `## History Notes / ## Changelog Notes contain real bullets ` +
    `(not just "- (none)") — staging path introduced by #436 / #484. ` +
    `No MARK_STEP skip path.`,
};

caseBegin("refused-mark-steps-export-has-three-keys", "hooks/workflow-mark/mark-step-handler.js");
test("refused-mark-steps-export-has-three-keys", () => {
  const refused = refusedMarkSteps();
  assert.ok(Object.isFrozen(refused), "REFUSED_MARK_STEPS must be frozen");
  assert.deepStrictEqual(Object.keys(refused).sort(), Object.keys(WORDING).sort());
  for (const k of Object.keys(refused)) {
    assert.ok(VALID_STEPS.includes(k), `${k} is not a VALID_STEPS step`);
    assert.strictEqual(refused[k], WORDING[k], `${k}: table wording differs`);
  }
  assert.ok(!("write_tests" in refused), "write_tests is evidence-gated, not always refused");
  assert.ok(!("run_tests" in refused), "run_tests skip is evidence-gated, not always refused");
});
caseEnd();

// Handler cases: in-process handle() calls and one real hook run through the #2824 fixture.
const HANDLER = path.join(ROOT, "hooks", "workflow-mark", "mark-step-handler.js");
const M = (step, status) => `echo "<<WORKFLOW_MARK_STEP_${step}_${status}>>"`;
const STATUSES = ["complete", "skipped", "pending", "in_progress"];
const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// callHandle(cmd, sid, repoCwd) -> {handled, messages, unapplied} of one in-process handle() call.
function callHandle(cmd, sid, repoCwd) {
  const messages = [];
  const unapplied = [];
  const handled = require(HANDLER).handle({
    cmd, sessionId: sid, repoCwd,
    pushMessage: (m) => messages.push(m), pushUnapplied: (m) => unapplied.push(m),
  });
  return { handled, messages, unapplied };
}

caseBegin("always-refused-steps-keep-their-wording-for-every-status", "hooks/workflow-mark/mark-step-handler.js");
test("always-refused-steps-keep-their-wording-for-every-status", () => {
  const X = fx();
  const sid = X.seedInit("wording");
  for (const step of Object.keys(WORDING)) {
    for (const status of STATUSES) {
      const r = callHandle(M(step, status), sid, X.REPO);
      assert.strictEqual(r.handled, true, `${step}_${status}: not handled`);
      assert.deepStrictEqual(r.unapplied, [WORDING[step]], `${step}_${status}: refusal wording changed`);
      assert.deepStrictEqual(r.messages, [], `${step}_${status}: unexpected INFO`);
    }
  }
});
caseEnd();

caseBegin("always-refused-steps-leave-state-unchanged-through-the-hook", "hooks/workflow-mark/mark-step-handler.js");
test("always-refused-steps-leave-state-unchanged-through-the-hook", () => {
  const X = fx();
  const sid = X.seedInit("state");
  const before = X.F.S.readState(sid);
  for (const step of Object.keys(WORDING)) {
    const head = WORDING[step].slice("workflow-mark: ".length, WORDING[step].indexOf(" — "));
    X.expectUnapplied(`${step}-complete`, sid, M(step, "complete"), escapeRe(head), { projectDir: X.REPO });
    assert.deepStrictEqual(X.F.S.readState(sid).steps[step], before.steps[step], `${step}: step entry changed`);
  }
  X.check();
});
caseEnd();

caseBegin("write-tests-refused-only-without-test-evidence", "hooks/workflow-mark/mark-step-handler.js");
test("write-tests-refused-only-without-test-evidence", () => {
  const X = fx();
  const sid = X.seedInit("wt-none");
  const none = callHandle(M("write_tests", "complete"), sid, X.REPO);
  assert.strictEqual(none.unapplied.length, 1, JSON.stringify(none));
  assert.ok(none.unapplied[0].startsWith("workflow-mark: write_tests NOT recorded — MARK_STEP not accepted"), none.unapplied[0]);
  assert.notStrictEqual(X.F.S.readState(sid).steps.write_tests.status, "complete");

  const repo = path.join(X.TMP, "repo-with-tests");
  gitInit(repo);
  fs.mkdirSync(path.join(repo, "tests", "hooks"), { recursive: true });
  fs.writeFileSync(path.join(repo, "tests", "hooks", "sample-case.js"), "\"use strict\";\n");
  const add = spawnSync("git", ["-C", repo, "add", "tests"], { encoding: "utf8" });
  assert.strictEqual(add.status, 0, add.stderr);
  const sid2 = X.seedInit("wt-staged");
  const staged = callHandle(M("write_tests", "complete"), sid2, repo);
  assert.ok(!staged.unapplied.some((m) => m.includes("write_tests NOT recorded")),
    `staged test evidence must not be refused: ${JSON.stringify(staged.unapplied)}`);
  assert.strictEqual(X.F.S.readState(sid2).steps.write_tests.status, "complete");
});
caseEnd();

// A step named after an Object.prototype key must not hit the refused-table lookup: it gets only
// the unknown-step refusal. `toString` has an upper-case letter, so MARKER_RE_DQ never matches it.
caseBegin("prototype-key-step-names-get-only-the-unknown-step-refusal", "hooks/workflow-mark/mark-step-handler.js");
test("prototype-key-step-names-get-only-the-unknown-step-refusal", () => {
  const X = fx();
  const sid = X.seedInit("proto");
  const before = X.raw(sid);
  for (const step of ["constructor", "__proto__"]) {
    const r = callHandle(M(step, "complete"), sid, X.REPO);
    assert.strictEqual(r.handled, true, `${step}: not handled`);
    assert.deepStrictEqual(r.unapplied, [`workflow-mark: unknown step "${step}" in marker — ignored.`],
      `${step}: expected only the unknown-step refusal`);
    assert.deepStrictEqual(r.messages, [], `${step}: unexpected INFO`);
  }
  const ts = callHandle(M("toString", "complete"), sid, X.REPO);
  assert.deepStrictEqual(ts, { handled: false, messages: [], unapplied: [] }, `toString: ${JSON.stringify(ts)}`);
  assert.strictEqual(X.raw(sid), before, "state must not change");
});
caseEnd();

// #2962: the GLOSSARY_ACCEPTED pattern takes the batch discriminator (`term=* batch=definition-only`);
// the existing shapes keep matching and an unknown discriminator name still does not.
const GA = (body) => `echo "<<WORKFLOW_GLOSSARY_ACCEPTED: ${body} — user accepted the reworded definitions>>"`;
const GLOSSARY_MATRIX = [
  [true, "batch-definition-only", "term=* batch=definition-only", "*", " batch=definition-only"],
  [true, "batch-with-cat", "term=* batch=definition-only cat=user", "*", " batch=definition-only cat=user"],
  [true, "existing-step-form", "term=glossary drift step=review_security", "glossary drift", " step=review_security"],
  [true, "existing-op-cat-form", "term=glossary drift op=redefine cat=user", "glossary drift", " op=redefine cat=user"],
  [false, "unknown-discriminator", "term=* bulk=definition-only", null, null],
  [false, "batch-upper-case-value", "term=* batch=DEFINITION", null, null],
];

caseBegin("glossary-accepted-pattern-takes-the-batch-discriminator", "hooks/lib/sentinel-patterns.js");
test("glossary-accepted-pattern-takes-the-batch-discriminator", () => {
  const SP = require(path.join(ROOT, "hooks", "lib", "sentinel-patterns.js"));
  if (Array.isArray(SP.GLOSSARY_DISCRIMINATOR_NAMES)) {
    assert.ok(SP.GLOSSARY_DISCRIMINATOR_NAMES.includes("batch"), "GLOSSARY_DISCRIMINATOR_NAMES lacks batch");
  }
  const wrong = [];
  for (const [want, name, body, term, discs] of GLOSSARY_MATRIX) {
    const m = SP.GLOSSARY_ACCEPTED_RE_DQ.exec(GA(body));
    if (!!m !== want) { wrong.push(`${name}: want match=${want}, got ${!!m}`); continue; }
    if (m && (m[1] !== term || m[2] !== discs)) wrong.push(`${name}: captured term=${m[1]} discriminators=${m[2]}`);
  }
  assert.deepStrictEqual(wrong, [], wrong.join("\n"));
});
caseEnd();

caseBegin("run-tests-skip-stays-evidence-gated", "hooks/workflow-mark/mark-step-handler.js");
test("run-tests-skip-stays-evidence-gated", () => {
  const X = fx();
  const r = callHandle(M("run_tests", "skipped"), X.seedInit("rt-skip"), X.REPO);
  assert.strictEqual(r.unapplied.length, 1, JSON.stringify(r));
  assert.ok(r.unapplied[0].startsWith("workflow-mark: run_tests NOT skipped"), r.unapplied[0]);
});
caseEnd();
