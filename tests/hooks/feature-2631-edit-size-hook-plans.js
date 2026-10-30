#!/usr/bin/env node
// tests/hooks/feature-2631-edit-size-hook-plans.js
// Tests: hooks/block-post-edit-size.js, hooks/block-post-edit-size/file-size.js, hooks/block-post-edit-size/comment-block.js, hooks/lib/progress-file.js, settings.json
// Tags: scope:issue-specific, size-limits, hook, pre-tool-use, plan-artifact, session-progress, block, layer:TL2, hook-registration
// TL3 gap (what this test does NOT catch):
// - the real Claude Code host loading settings.json and firing the hook on Write / Edit / MultiEdit
// - the host refusing the tool call on the block decision (here the registered command runs in a shell)
// Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
// via bin/check-verification-gate.sh category: hook-registration.
"use strict";
// #2631 stage 3, plans dir and multi-target edits: plan artifacts (intent / outline / detail) and
// <sid>-session-progress.md ("## Current state", in chars) are judged at edit time like repo files;
// <sid>-context.md and paths outside both the repo and the plans dir are ignored. A MultiEdit is
// grouped per target file (relative and absolute spellings merged) and every HARD target is named.

const fs = require("fs");
const path = require("path");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const savedCwd = process.cwd();
const H = require("./feature-2631-edit-size-hook/fixture");
const { F } = H;
const C = H.setup();
process.chdir(C.work);
const PLAN_STAGES = ["intent", "outline", "detail"].map((s) => [s, F.EXPECTED[s][0], F.EXPECTED[s][1]]);

caseBegin("E7-plan-artifacts", "hooks/block-post-edit-size/file-size.js");
F.run("E7", () => {
  for (const [stage, w, h] of PLAN_STAGES) {
    const p = H.planPath(C.sid, stage);
    const base = path.basename(p);
    const w1 = (n) => H.hook("Write", { file_path: p, content: F.proseLines(n) });
    H.silent(`${stage}: WARN (${w}) approves without advice`, w1(w));
    H.advises(`${stage}: WARN+1 approves with advice`, w1(w + 1), [String(w + 1)]);
    H.advises(`${stage}: HARD approves with advice`, w1(h), [String(h)]);
    H.blocks(`${stage}: HARD+1 blocks`, w1(h + 1), [base, String(h + 1), String(h)]);
  }
  H.approves("<sid>-context.md is ignored", H.hook("Write", { file_path: H.planPath(C.sid, "context"), content: F.proseLines(900) }));
  const outside = path.join(C.work, "outside", `${C.sid}-detail.md`);
  H.approves("a path outside the repo and the plans dir is ignored", H.hook("Write", { file_path: outside, content: F.proseLines(900) }));
});
caseEnd();

caseBegin("E7-plan-artifacts-edit", "hooks/block-post-edit-size/file-size.js");
F.run("E7-edit", () => {
  const add = { old_string: "Line 1 of the fixture text.\n", new_string: "Line 1 of the fixture text.\nAdded line of the fixture text.\n" };
  const cut2 = { old_string: "Line 2 of the fixture text.\nLine 3 of the fixture text.\n", new_string: "" };
  for (const [stage, w, h] of PLAN_STAGES) {
    const p = H.planPath(C.sid, stage);
    const edit = (e) => H.hook("Edit", Object.assign({ file_path: p }, e));
    H.put(p, F.proseLines(w));
    H.advises(`${stage}: Edit WARN -> WARN+1 approves with advice`, edit(add), [String(w + 1)]);
    H.put(p, F.proseLines(h));
    H.blocks(`${stage}: Edit HARD -> HARD+1 blocks`, edit(add), [path.basename(p), String(h + 1), String(h)]);
    H.put(p, F.proseLines(h + 5));
    H.approves(`${stage}: Edit shrinking an over-HARD plan (HARD+5 -> HARD+3) approves`, edit(cut2));
  }
});
caseEnd();

caseBegin("E8-session-progress-current-state", "hooks/block-post-edit-size/file-size.js");
F.run("E8", () => {
  const p = H.planPath(C.sid, "session-progress");
  const w = (n) => H.hook("Write", { file_path: p, content: F.progressDoc(n) });
  H.silent("Current state 400 chars approves without advice", w(400));
  H.advises("Current state 401 chars approves with advice", w(401), ["401"]);
  H.advises("Current state 600 chars approves with advice", w(600), ["600"]);
  H.blocks("Current state 601 chars blocks with the rewrite instruction", w(601), [path.basename(p), "601", 'rewrite "Current state"']);
  H.approves("a long file outside Current state does not count", H.hook("Write", { file_path: p, content: F.progressDoc(100, "\n## Facts to carry over\n\n" + "z".repeat(5000) + "\n") }));
  H.put(p, F.progressDoc(610));
  H.approves("Edit shrinking an over-HARD Current state approves", H.hook("Edit", { file_path: p, old_string: "xxxxxxxxxx\n\n## Plan files", new_string: "x\n\n## Plan files" }));
  H.blocks("Edit growing an over-HARD Current state blocks", H.hook("Edit", { file_path: p, old_string: "x\n\n## Plan files", new_string: "xy\n\n## Plan files" }), ['rewrite "Current state"']);
});
caseEnd();

caseBegin("E9-comment-block-and-size-together", "hooks/block-post-edit-size.js");
F.run("E9", () => {
  const r = H.hook("Write", { file_path: H.repoPath("e9/both.js"), content: H.commentRun(12) + F.codeLines(500) });
  H.blocks("both violations are reported in one reason", r, ["Comment-block size:", "both.js", "512", "500"]);
  F.check("the two reasons are separate lines", r.reason.split("\n").length >= 2, r.raw);
});
caseEnd();

caseBegin("E10-multi-file-multiedit", "hooks/block-post-edit-size/file-size.js");
F.run("E10", () => {
  const small = H.put(H.repoPath("e10/small.js"), F.codeLines(3));
  const other = F.newSid();
  const prog = H.put(H.planPath(other, "session-progress"), F.progressDoc(590));
  const harmless = { old_string: "const a1 = 1;", new_string: "const a1 = 2;" };
  const toProgress = { file_path: prog, old_string: "x\n\n## Plan files", new_string: "x" + "y".repeat(11) + "\n\n## Plan files" };
  H.blocks("an element targeting another session-progress.md is judged on its own file",
    H.hook("MultiEdit", { file_path: small, edits: [harmless, toProgress] }), [path.basename(prog), "601"]);
  H.approves("control: the harmless top-level element alone approves", H.hook("MultiEdit", { file_path: small, edits: [harmless] }));

  const t1 = H.put(H.repoPath("e10/t1.js"), F.codeLines(500));
  const t2 = H.put(H.repoPath("e10/t2.js"), F.codeLines(500));
  const grow1 = { old_string: "const a1 = 1;\n", new_string: "const a1 = 1;\nconst g = 1;\n" };
  H.blocks("two HARD targets are both named",
    H.hook("MultiEdit", { file_path: small, edits: [Object.assign({ file_path: t1 }, grow1), Object.assign({ file_path: t2 }, grow1)] }), ["t1.js", "t2.js"]);

  const m = H.put(H.repoPath("e10/m.js"), F.codeLines(510));
  const rel = "e10/m.js";
  const grow2 = { file_path: rel, old_string: "const a1 = 1;\n", new_string: "const a1 = 1;\nconst g1 = 1;\nconst g2 = 2;\n" };
  const cut5 = { file_path: m, old_string: "const a2 = 2;\nconst a3 = 3;\nconst a4 = 4;\nconst a5 = 5;\nconst a6 = 6;\n", new_string: "" };
  const cut1 = { file_path: m, old_string: "const a2 = 2;\n", new_string: "" };
  H.approves("relative + absolute spellings merge; net shrink approves", H.hook("MultiEdit", { file_path: small, edits: [grow2, cut5] }));
  H.blocks("relative + absolute spellings merge; net growth blocks", H.hook("MultiEdit", { file_path: small, edits: [grow2, cut1] }), ["m.js", "511"]);
});
caseEnd();

caseBegin("wiring-settings-registration", "settings.json");
F.run("settings", () => {
  const settings = JSON.parse(fs.readFileSync(path.join(F.ROOT, "settings.json"), "utf8"));
  F.check("settings.json no longer names hooks/block-comment-block-size.js", !JSON.stringify(settings).includes("hooks/block-comment-block-size.js"), "");
  const regs = [];
  for (const entry of ((settings.hooks || {}).PreToolUse || [])) {
    for (const h of entry.hooks || []) {
      if (typeof h.command === "string" && h.command.includes("hooks/block-post-edit-size.js")) regs.push({ matcher: String(entry.matcher || ""), command: h.command });
    }
  }
  F.check("exactly one PreToolUse entry runs hooks/block-post-edit-size.js", regs.length === 1, JSON.stringify(regs));
  if (regs.length !== 1) return;
  const { matcher, command } = regs[0];
  for (const tool of ["Write", "Edit", "MultiEdit"]) F.check(`registered matcher covers ${tool}`, new RegExp(`^(?:${matcher})$`).test(tool), matcher);
  const root = F.ROOT.replace(/\\/g, "/");
  const cmd = command.replace(/\$\{?(AGENTS_MAIN_ROOT|CLAUDE_PROJECT_DIR)\}?/g, root);
  F.check("the registered command has no unresolved variable", !/\$\{?[A-Za-z_]/.test(cmd), cmd);
  H.blocks("the registered command blocks an over-HARD Write", H.hook("Write", { file_path: H.repoPath("reg/over.js"), content: F.codeLines(501) }, { command: cmd }), ["over.js", "501"]);
  H.approves("control: the registered command approves a small Write", H.hook("Write", { file_path: H.repoPath("reg/small.js"), content: F.codeLines(10) }, { command: cmd }));
});
caseEnd();

caseBegin("wiring-reexports-and-comment-block-module", "hooks/block-post-edit-size.js");
F.run("exports", () => {
  const mod = F.load("hooks/block-post-edit-size.js");
  for (const k of ["buildReason", "buildPost", "resolveTargetPath"]) F.check(`re-exports ${k}`, typeof mod[k] === "function", typeof mod[k]);
  F.check("re-exports MAX_BYTES", mod.MAX_BYTES === F.load("hooks/lib/post-edit-content.js").MAX_BYTES, mod.MAX_BYTES);
  const cb = fs.readFileSync(path.join(F.ROOT, "hooks", "block-post-edit-size", "comment-block.js"), "utf8");
  F.check("comment-block.js reads no session marker", !/workflow-off|worktree-off|isWorkflowOff|session-markers/.test(cb), "");
  F.check("file-size.js exists", fs.existsSync(path.join(F.ROOT, "hooks", "block-post-edit-size", "file-size.js")), "");
});
caseEnd();

caseBegin("wiring-current-state-section", "hooks/lib/progress-file.js");
F.run("progress-file", () => {
  const pf = F.load("hooks/lib/progress-file.js");
  F.check('progress-file exports CURRENT_STATE_SECTION = "Current state"', pf.CURRENT_STATE_SECTION === "Current state", pf.CURRENT_STATE_SECTION);
});
caseEnd();

process.chdir(savedCwd);
restore();
process.exitCode = F.failureCount() ? 1 : 0;
