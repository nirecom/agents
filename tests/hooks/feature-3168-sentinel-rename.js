"use strict";
// Tests: hooks/lib/sentinel-patterns.js, hooks/workflow-mark/conventional-audit-chosen-handler.js, hooks/workflow-mark.js
// Tags: TL2, scope:issue-specific, issue-3168, pm-session, pre-confirm-audit, sentinel, workflow-mark
// #3168: the user's choice of the conventional supervisor audit is WORKFLOW_CONVENTIONAL_AUDIT_CHOSEN. Its plan form
// names the gate's step (clarify_intent / outline / detail), the stage set is derived from the pre-confirm rows of
// audit-triggers TRIGGERS, and sentinel-patterns owns the name that the handler and the gate hint read.
// TL3 gap (what this test does NOT catch):
// - the settings.json ask row putting a live echo through the permission dialog;
// - a live model choosing the sentinel from the gate's ask hint.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

delete process.env.CLAUDE_CODE_SESSION_ID;
const restore = isolate();
const D = require("./feature-2853-pre-confirm-audit/driver");
const PR = require("./feature-2853-pre-confirm-audit/pm-route-cases");
after(() => { restore(); });

const { X, ROOT } = D;
const NAME = "WORKFLOW_CONVENTIONAL_AUDIT_CHOSEN";
const SP = () => require(path.join(ROOT, "hooks", "lib", "sentinel-patterns.js"));
const TRIGGERS = () => require(path.join(ROOT, "hooks", "lib", "audit-triggers.js")).TRIGGERS;
const HANDLER = path.join(ROOT, "hooks", "workflow-mark", "conventional-audit-chosen-handler.js");
const echo = (target) => `echo "<<${NAME}: ${target} r>>"`;
const preConfirmSteps = () => TRIGGERS().filter((t) => t.kind === "pre-confirm").map((t) => t.step).sort();

caseBegin("plan-form-arms-clarify-intent", "hooks/workflow-mark/conventional-audit-chosen-handler.js");
test("T8 at the intent stage, the clarify_intent plan form arms a clarify_intent fallback run", () => {
  PR.fx();
  const s = X.sessionAt("intent", { audit: false });
  const out = PR.mark(s.sid, echo("clarify_intent"));
  const a = D.audit(s.sid);
  const runId = a.audit_run_id || "";
  assert.ok(runId !== "", `nothing armed: ${D.show(a)} / ${out}`);
  const entry = D.runEntry(s.sid, runId) || {};
  assert.strictEqual(String(entry.cause || a.audit_cause || ""), "pre-confirm:clarify_intent", D.show(entry));
  assert.strictEqual(PR.findingsOf(s.sid, "user:pm-review-fallback", runId).length, 1, `the fallback finding names ${runId}: ${D.show(a.findings)}`);
});
test("T9 the old-notation (intent) plan form is malformed, the guidance FORM names clarify_intent, and nothing is armed", () => {
  const s = X.sessionAt("intent", { audit: false });
  const out = PR.mark(s.sid, echo("intent"));
  assert.match(out, /malformed/i, out);
  assert.ok(out.includes(NAME) && out.includes("clarify_intent"), `the FORM names the sentinel and clarify_intent: ${out}`);
  assert.strictEqual(D.audit(s.sid).audit_run_id || "", "", D.show(D.audit(s.sid)));
});
caseEnd();

caseBegin("stage-set-and-name-ssot", "hooks/lib/sentinel-patterns.js");
test("T10 PLAN_AUDIT_STAGES equals the set of pre-confirm steps in audit-triggers TRIGGERS", () => {
  const stages = SP().PLAN_AUDIT_STAGES;
  assert.ok(stages && typeof stages[Symbol.iterator] === "function", `PLAN_AUDIT_STAGES is not exported: ${D.show(stages)}`);
  assert.deepStrictEqual([...stages].sort(), preConfirmSteps());
});
test("T10 CONVENTIONAL_AUDIT_CHOSEN_RE_DQ accepts the gate's step names and PR#<n>; old stage notation matches only LOOKSLIKE", () => {
  const sp = SP();
  assert.strictEqual(sp.CONVENTIONAL_AUDIT_CHOSEN_NAME, NAME);
  const re = sp.CONVENTIONAL_AUDIT_CHOSEN_RE_DQ;
  const like = sp.CONVENTIONAL_AUDIT_CHOSEN_LOOKSLIKE_RE;
  assert.ok(re instanceof RegExp && like instanceof RegExp, "RE_DQ / LOOKSLIKE_RE are not exported");
  for (const target of preConfirmSteps().concat(["PR#12"])) {
    const m = re.exec(echo(target));
    assert.ok(m && m[1] === target && m[2].trim() === "r", `${target}: ${D.show(m)}`);
  }
  for (const bad of ["intent", "write_code", "PR#", "PR#x"]) {
    assert.ok(!re.test(echo(bad)), `${bad} is accepted`);
    assert.ok(like.test(echo(bad)), `${bad} is not recognized as malformed`);
  }
});
test("T10 the handler and gate hint read the name from sentinel-patterns (holding no literal of the name)", () => {
  assert.ok(fs.existsSync(HANDLER), `${HANDLER} is missing`);
  const files = [HANDLER, path.join(ROOT, "bin", "workflow", "lib", "next-step", "pm-audit-route.js"), path.join(ROOT, "hooks", "workflow-gate", "user-verified-pm-review.js")];
  // A copy counts with or without quotes: the name itself must not appear in any string, template literal, identifier or comment.
  // The referenced constant CONVENTIONAL_AUDIT_CHOSEN_NAME does not start with WORKFLOW_, so this substring check does not hit it.
  const copyAt = (code) => code.split("\n").map((l, i) => [i + 1, l]).filter(([, l]) => l.includes(NAME));
  for (const f of files) {
    const code = fs.readFileSync(f, "utf8");
    assert.match(code, /CONVENTIONAL_AUDIT_CHOSEN_NAME/, `${path.basename(f)} does not read the name from sentinel-patterns`);
    assert.deepStrictEqual(copyAt(code), [], `${path.basename(f)} keeps its own copy of the name`);
  }
  // Check the check itself: it also detects unquoted copies (template literal, comment, part of an identifier).
  for (const sample of [`const h = \`<<${NAME}: x>>\`;`, `// emits ${NAME}`, `const K_${NAME} = 1;`]) {
    assert.strictEqual(copyAt(sample).length, 1, `the copy check misses: ${sample}`);
  }
});
caseEnd();
