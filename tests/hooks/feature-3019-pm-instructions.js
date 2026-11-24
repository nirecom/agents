#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/pm-instructions.js, hooks/lib/pm-instructions/sections.js, hooks/lib/pm-instructions/role.js, hooks/lib/pm-instructions/render.js, bin/pm-instructions, bin/lib/pm-instructions/cli.js, hooks/session-start.js, hooks/post-compact.js, skills/_shared/pm-supervisor-duties.md, skills/workflow-init/SKILL.md, skills/clarify-intent/SKILL.md, skills/resume-session/SKILL.md, skills/session-close/SKILL.md, skills/pm-init/SKILL.md, skills/pm-add/SKILL.md, skills/pm-remove/SKILL.md, skills/_shared/pm-pre-pr-contact.md
// Tags: TL2, scope:issue-specific, hooks, pm-session, pm-instructions, session-start, post-compact, cli, fail-open, truncation, utf8, pm-field, issue-2942, pm-review
// #3019: PM supervisor duties are read from one SSOT md and injected by role (PM state; a workflow's owner from the #2942 PM field) at
// SessionStart / PostCompact and through bin/pm-instructions at the skill-step timings.
// Dispatch only; the cases live in ./feature-3019-pm-instructions/ (Pattern A).
// TL3 gap (what this test does NOT catch):
// - a real Claude Code host injecting the SessionStart / PostCompact additionalContext into the model
// - the LLM actually running bin/pm-instructions from the skill steps and following its output
// - hook-registration is not a gap here: no hook is registered or re-registered by #3019

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after } = require("node:test");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { makeShared } = require("./feature-3019-pm-instructions/world");
const C = require("./feature-3019-pm-instructions/contract-cases");
const R = require("./feature-3019-pm-instructions/role-cases");
const RR = require("./feature-3019-pm-instructions/role-repo-cases");
const D = require("./feature-3019-pm-instructions/render-cases");
const L = require("./feature-3019-pm-instructions/cli-cases");
const H = require("./feature-3019-pm-instructions/hook-cases");
const PR = require("./feature-3019-pm-instructions/pm-review-cases");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "pm-instr-3019-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true });
});
// isolate() pins WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR and drops CLAUDE_CODE_SESSION_ID; every child
// gets its own world's pins and an empty transcript base from world.js.
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts-top");
fs.mkdirSync(process.env.CLAUDE_TRANSCRIPT_BASE_DIR);
const S = makeShared(TMP);

caseBegin("section-contract-real-md", "skills/_shared/pm-supervisor-duties.md");
C.realMd(S);
caseEnd();

caseBegin("section-duties-real-md", "skills/_shared/pm-supervisor-duties.md");
C.realDuties(S);
caseEnd();

caseBegin("skill-cli-calls", "skills/workflow-init/SKILL.md");
C.skillCalls();
caseEnd();

caseBegin("missing-heading-null", "hooks/lib/pm-instructions/sections.js");
D.missingHeading(S);
caseEnd();

caseBegin("role-pm", "hooks/lib/pm-instructions/role.js");
R.pmRole(S);
caseEnd();

caseBegin("role-workflow-direct", "hooks/lib/pm-instructions/role.js");
R.workflowDirect(S);
caseEnd();

caseBegin("role-workflow-pm-field-decides", "hooks/lib/pm-instructions/role.js");
R.fieldDecides(S);
caseEnd();

caseBegin("role-meta-routed-deadline", "hooks/lib/pm-instructions/role.js");
R.metaRouted(S);
caseEnd();

caseBegin("role-hook-slow-forge-budget", "hooks/lib/pm-instructions/role.js");
R.hookSlowForge(S);
caseEnd();

caseBegin("role-ignores-peer-msg", "hooks/lib/pm-instructions/role.js");
R.peerOnly(S);
caseEnd();

caseBegin("role-current-generation", "hooks/lib/pm-instructions/role.js");
RR.currentGeneration(S);
caseEnd();

caseBegin("role-home-repo", "hooks/lib/pm-instructions/role.js");
RR.homeRepo(S);
caseEnd();

caseBegin("render-cap-utf8", "hooks/lib/pm-instructions/render.js");
D.cap(S);
caseEnd();

caseBegin("cli-arg-errors", "bin/lib/pm-instructions/cli.js");
L.argErrors(S);
caseEnd();

caseBegin("cli-inputs", "bin/lib/pm-instructions/cli.js");
L.inputs(S);
caseEnd();

caseBegin("cli-failures-exit-1", "bin/lib/pm-instructions/cli.js");
L.failures(S);
caseEnd();

caseBegin("cli-issue-bare-number", "bin/lib/pm-instructions/cli.js");
L.bareIssue(S);
caseEnd();

caseBegin("cli-single-timing", "bin/pm-instructions");
L.timings(S);
caseEnd();

caseBegin("hook-session-start", "hooks/session-start.js");
H.sessionStart(S);
caseEnd();

caseBegin("hook-session-start-startup", "hooks/session-start.js");
H.startup(S);
caseEnd();

caseBegin("hook-post-compact", "hooks/post-compact.js");
H.postCompact(S);
caseEnd();

caseBegin("hook-home-repo", "hooks/lib/pm-instructions/inject.js");
H.hookHomeRepo(S);
caseEnd();

caseBegin("3144-review-timings-unbundled", "hooks/lib/pm-instructions/sections.js");
PR.bundle(S);
caseEnd();

caseBegin("3144-duties-review-request", "skills/_shared/pm-supervisor-duties.md");
PR.duties();
caseEnd();

caseBegin("3144-contact-review-request-rr5", "skills/_shared/pm-pre-pr-contact.md");
PR.contact();
caseEnd();
