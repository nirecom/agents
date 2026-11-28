#!/usr/bin/env node
"use strict";
// Tests: skills/_shared/pm-pre-pr-contact.md
// Tags: TL2, scope:issue-specific, skills, pm-session, pm-review, dup-group-keep:time-hard-limit, issue-3168
// #3168: RR-4's conventional-audit choice says who does what. The model runs the echo via Bash and the user only
// approves it in the permission dialog; no RR-4 wording hands the echo to the user to run.
// A file of its own: tests/hooks/feature-3019-pm-instructions.js, which also reads this md, is over its time budget.

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const { caseBegin, caseEnd } = require("../lib/harness");

const ROOT = path.resolve(__dirname, "..", "..");
const CONTACT_MD = path.join(ROOT, "skills", "_shared", "pm-pre-pr-contact.md");
const read = (f) => fs.readFileSync(f, "utf8");
// section(text, re) -> from the heading matching re up to the next heading of the same or a higher level.
function section(text, re) {
  const lines = String(text).split(/\r?\n/);
  const i = lines.findIndex((l) => re.test(l));
  if (i < 0) return null;
  const level = /^#+/.exec(lines[i])[0].length;
  const end = lines.findIndex((l, j) => j > i && /^#+ /.test(l) && /^#+/.exec(l)[0].length <= level);
  return lines.slice(i, end < 0 ? lines.length : end).join("\n");
}
const USER_RUNS_ECHO = /(ask|tell|have) the user to (run|execute|type|paste)|the user (runs|should run|must run|types|pastes)|user to run (the )?`?echo/i;
// rr4Lines() -> the lines of the RR-4 bullet of `## Review request: no answer and findings`, up to the next RR bullet.
function rr4Lines() {
  const sec = section(read(CONTACT_MD), /^## Review request: no answer and findings\s*$/) || "";
  const lines = sec.split(/\r?\n/);
  const i = lines.findIndex((l) => /\*\*RR-4\.\*\*/.test(l));
  const j = lines.findIndex((l, k) => k > i && /^- \*\*RR-\d+\.\*\*/.test(l));
  return i < 0 ? [] : lines.slice(i, j < 0 ? lines.length : j);
}

caseBegin("3168-contact-rr4-model-runs-echo", "skills/_shared/pm-pre-pr-contact.md");
test("3168 C3: RR-4's conventional-audit choice has the model run the echo via Bash and the user approve it in the permission dialog", () => {
  const lines = rr4Lines();
  assert.ok(lines.length > 0, "no RR-4 bullet in ## Review request: no answer and findings");
  const conv = lines.find((l) => /WORKFLOW_CONVENTIONAL_AUDIT_CHOSEN/.test(l));
  assert.ok(conv, `RR-4 has no conventional-audit line: ${lines.join("\n")}`);
  assert.match(conv, /run `echo "<<WORKFLOW_CONVENTIONAL_AUDIT_CHOSEN: [^`]*>>"` via Bash/, conv);
  assert.match(conv, /the user approves it in the permission dialog/, conv);
});
test("3168 C3: no RR-4 line tells the user to run the echo", () => {
  const lines = rr4Lines();
  assert.ok(lines.length > 0, "no RR-4 bullet");
  for (const l of lines) assert.doesNotMatch(l, USER_RUNS_ECHO, l);
  // The guard regex itself rejects the wording #3168 removed, so the negative check is not vacuous.
  assert.match('ask the user to run `echo "<<WORKFLOW_CONVENTIONAL_AUDIT_CHOSEN: outline r>>"` in the permission dialog', USER_RUNS_ECHO);
  assert.match("the user runs the echo", USER_RUNS_ECHO);
});
caseEnd();
