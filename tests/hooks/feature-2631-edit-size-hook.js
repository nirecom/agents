#!/usr/bin/env node
// tests/hooks/feature-2631-edit-size-hook.js
// Tests: hooks/block-post-edit-size.js, hooks/block-post-edit-size/file-size.js, hooks/lib/post-edit-content.js
// Tags: scope:issue-specific, size-limits, hook, pre-tool-use, block, fail-open, layer:TL2, ssot, idempotency, side-effect
// TL3 gap (what this test does NOT catch):
// - the real Claude Code host firing the hook on Write / Edit and refusing the tool call on a block
// Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
// via bin/check-verification-gate.sh category: hook-registration.
"use strict";
// #2631 stage 3, repo files: the renamed PreToolUse hook judges the post-edit size of a code file.
// post > HARD blocks unless the edit shrinks the file; WARN < post <= HARD approves with advice.
// Disabled for WORKFLOW_OFF, an unstarted workflow and an unresolvable sid; COMMENT_BLOCK_ENFORCE=off
// silences only the comment-block check. Plans / progress / multi-file cases: feature-2631-edit-size-hook-plans.js.

const fs = require("fs");
const path = require("path");
const { after, test } = require("node:test");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");

const restore = isolate();
const savedCwd = process.cwd();
const H = require("./feature-2631-edit-size-hook/fixture");
const { F } = H;
const C = H.setup();
process.chdir(C.work);
after(() => {
  process.chdir(savedCwd);
  restore();
});
const HARD = 500;

caseBegin("E1-write-new-file", "hooks/block-post-edit-size/file-size.js");
test("E1", () => noNewFailures(F.failureCount, () => F.run("E1", () => {
  H.advises("new file at exactly HARD approves with WARN advice", H.hook("Write", { file_path: H.repoPath("e1/at-hard.js"), content: F.codeLines(HARD) }), ["at-hard.js", "500"]);
  H.blocks("new file at HARD+1 blocks", H.hook("Write", { file_path: H.repoPath("e1/over.js"), content: F.codeLines(HARD + 1) }), ["over.js", "501", "500"]);
  H.silent("new file at WARN approves without advice", H.hook("Write", { file_path: H.repoPath("e1/warn.js"), content: F.codeLines(300) }));
  H.advises("new file at WARN+1 approves with advice", H.hook("Write", { file_path: H.repoPath("e1/warn1.js"), content: F.codeLines(301) }), ["301"]);
  H.blocks("relative file_path resolves against the repo", H.hook("Write", { file_path: "e1/rel-over.js", content: F.codeLines(HARD + 1) }), ["rel-over.js"]);
  H.approves("a non-code file is out of scope", H.hook("Write", { file_path: H.repoPath("e1/data.txt"), content: F.codeLines(900) }));
})));
caseEnd();

caseBegin("E2-write-overwrite", "hooks/block-post-edit-size/file-size.js");
test("E2", () => noNewFailures(F.failureCount, () => F.run("E2", () => {
  const p = H.put(H.repoPath("e2/big.js"), F.codeLines(HARD + 10));
  H.approves("overwrite HARD+10 -> HARD+5 approves (shrink)", H.hook("Write", { file_path: p, content: F.codeLines(HARD + 5) }));
  const q = H.put(H.repoPath("e2/same.js"), F.codeLines(HARD + 1));
  H.blocks("overwrite HARD+1 -> HARD+1 blocks", H.hook("Write", { file_path: q, content: F.codeLines(HARD + 1, "z") }), ["same.js", "501"]);
  H.blocks("overwrite HARD+1 -> HARD+3 blocks", H.hook("Write", { file_path: q, content: F.codeLines(HARD + 3) }), ["same.js", "503"]);
})));
caseEnd();

caseBegin("E3-edit-and-multiedit-over-hard", "hooks/block-post-edit-size/file-size.js");
test("E3", () => noNewFailures(F.failureCount, () => F.run("E3", () => {
  const p = H.put(H.repoPath("e3/big.js"), F.codeLines(HARD + 10));
  const grow = { old_string: "const a1 = 1;\n", new_string: "const a1 = 1;\nconst extra = 0;\n" };
  const same = { old_string: "const a1 = 1;\n", new_string: "const a1 = 99;\n" };
  const shrink = { old_string: "const a1 = 1;\nconst a2 = 2;\nconst a3 = 3;\n", new_string: "" };
  H.blocks("Edit growing an over-HARD file blocks", H.hook("Edit", Object.assign({ file_path: p }, grow)), ["big.js", "511", "500"]);
  H.blocks("Edit keeping the count of an over-HARD file blocks", H.hook("Edit", Object.assign({ file_path: p }, same)), ["big.js", "510"]);
  H.approves("Edit shrinking an over-HARD file approves", H.hook("Edit", Object.assign({ file_path: p }, shrink)));
  H.blocks("MultiEdit growing blocks", H.hook("MultiEdit", { file_path: p, edits: [same, { old_string: "const a2 = 2;\n", new_string: "const a2 = 2;\nconst y = 1;\n" }] }), ["big.js"]);
  H.approves("MultiEdit whose net effect shrinks approves", H.hook("MultiEdit", { file_path: p, edits: [grow, { old_string: "const a4 = 4;\nconst a5 = 5;\nconst a6 = 6;\n", new_string: "" }] }));
  const small = H.put(H.repoPath("e3/small.js"), F.codeLines(HARD));
  H.blocks("Edit pushing a HARD file to HARD+1 blocks", H.hook("Edit", Object.assign({ file_path: small }, grow)), ["small.js", "501"]);
})));
caseEnd();

caseBegin("E4-unreadable-pre-over-1mb", "hooks/block-post-edit-size/file-size.js");
test("E4", () => noNewFailures(F.failureCount, () => F.run("E4", () => {
  const p = H.put(H.repoPath("e4/huge.js"), H.bigLines(600));
  F.check("fixture premise: huge.js exceeds MAX_BYTES", fs.statSync(p).size > 1000000, fs.statSync(p).size);
  const first = H.bigLines(1);
  H.blocks("Edit with a newline delta of -1 blocks (a dropped final newline looks the same)", H.hook("Edit", { file_path: p, old_string: first + "const b2", new_string: "const b2" }), ["huge.js"]);
  H.approves("Edit with a newline delta of -2 approves", H.hook("Edit", { file_path: p, old_string: H.bigLines(2) + "const b3", new_string: "const b3" }));
  H.blocks("Edit with a zero newline delta blocks", H.hook("Edit", { file_path: p, old_string: "const b1 =", new_string: "const c1 =" }), ["huge.js"]);
  H.blocks("Edit with a positive newline delta blocks", H.hook("Edit", { file_path: p, old_string: "const b1 =", new_string: "const z = 0;\nconst b1 =" }), ["huge.js"]);
  H.blocks("Write over an unreadable pre with post over HARD blocks", H.hook("Write", { file_path: p, content: F.codeLines(HARD + 1) }), ["huge.js"]);
  H.approves("Write over an unreadable pre with post within HARD approves", H.hook("Write", { file_path: p, content: F.codeLines(10) }));
})));
caseEnd();

caseBegin("E5-unrebuildable-and-foreign-tools", "hooks/block-post-edit-size.js");
test("E5", () => noNewFailures(F.failureCount, () => F.run("E5", () => {
  const p = H.put(H.repoPath("e5/big.js"), F.codeLines(HARD + 10));
  H.approves("old_string not found approves", H.hook("Edit", { file_path: p, old_string: "no such text\n", new_string: "a\nb\nc\n" }));
  H.approves("NotebookEdit approves", H.hook("NotebookEdit", { notebook_path: p, new_source: F.codeLines(900) }));
  H.approves("editFiles approves", H.hook("editFiles", { file_path: p, content: F.codeLines(900) }));
  H.blocks("control: the same file grown by Edit blocks", H.hook("Edit", { file_path: p, old_string: "const a1 = 1;\n", new_string: "const a1 = 1;\nconst q = 1;\n" }), ["big.js"]);
})));
caseEnd();

caseBegin("E6-disabling-conditions", "hooks/block-post-edit-size/file-size.js");
test("E6", () => noNewFailures(F.failureCount, () => F.run("E6", () => {
  const write = (rel) => ({ file_path: H.repoPath(rel), content: F.codeLines(HARD + 1) });
  const off = F.newSid();
  F.writeStartedState(off);
  F.writeMarker(off, "workflow-off");
  H.approves("WORKFLOW_OFF session approves", H.hook("Write", write("e6/off.js"), { sid: off }));
  H.approves("session without state (workflow not started) approves", H.hook("Write", write("e6/nostate.js"), { sid: F.newSid() }));
  H.approves("unresolvable session id approves", H.hook("Write", write("e6/nosid.js"), { sid: null }));
  H.blocks("control: started session blocks the same write", H.hook("Write", write("e6/started.js")), ["started.js"]);
  H.blocks("COMMENT_BLOCK_ENFORCE=off keeps the size block", H.hook("Write", write("e6/cb-off.js"), { cfg: C.cfgOff }), ["cb-off.js", "501"]);
  const both = H.commentRun(12) + F.codeLines(10);
  H.approves("COMMENT_BLOCK_ENFORCE=off still disables the comment-block check", H.hook("Write", { file_path: H.repoPath("e6/cb-only.js"), content: both }, { cfg: C.cfgOff }));
  H.blocks("control: comment-block check on blocks the same small file", H.hook("Write", { file_path: H.repoPath("e6/cb-on.js"), content: both }), ["Comment-block size:"]);
  const unstarted = F.newSid();
  H.blocks("comment-block check ignores the session gate (no state)", H.hook("Write", { file_path: H.repoPath("e6/cb-nostate.js"), content: both }, { sid: unstarted }), ["Comment-block size:"]);
})));
caseEnd();

// A copied tree whose size-limits.js says code 50/100 (or 700/900): a hook keeping its own numbers disagrees.
caseBegin("E11-ssot-limit-change-propagates", "hooks/block-post-edit-size/file-size.js");
test("E11", () => noNewFailures(F.failureCount, () => F.run("E11", () => {
  const M = require("./feature-2631-size-limits/mutate-limits");
  const low = M.limitsTree(path.join(C.work, "tree-low"), "code", 50, 100);
  const high = M.limitsTree(path.join(C.work, "tree-high"), "code", 700, 900);
  F.check("fixture premise: the copied SSOT says code 50/100", low.ok, low.detail);
  F.check("fixture premise: the copied SSOT says code 700/900", high.ok, high.detail);
  const w = (rel, n, hookPath) => H.hook("Write", { file_path: H.repoPath(rel), content: F.codeLines(n) }, { hookPath });
  H.blocks("lowered HARD 100: a new 150-line file blocks", w("e11/low.js", 150, low.hook), ["low.js", "150", "100"]);
  H.silent("control: the repo SSOT approves the same 150-line file", w("e11/low.js", 150));
  H.advises("raised HARD 900: a new 750-line file approves with WARN advice", w("e11/high.js", 750, high.hook), ["750"]);
  H.blocks("control: the repo SSOT blocks the same 750-line file", w("e11/high.js", 750), ["high.js", "750"]);
})));
caseEnd();

// The hook only judges: a block must leave the disk as it found it, and a repeated call is judged the same.
caseBegin("E12-block-leaves-files-as-found-and-repeats-stably", "hooks/block-post-edit-size/file-size.js");
test("E12", () => noNewFailures(F.failureCount, () => F.run("E12", () => {
  const fresh = H.repoPath("e12/never.js");
  const w = { file_path: fresh, content: F.codeLines(HARD + 1) };
  H.blocks("Write of a new HARD+1 file blocks", H.hook("Write", w), ["never.js", "501"]);
  F.check("the blocked Write left no file behind", !fs.existsSync(fresh), fresh);
  H.blocks("the same Write repeated blocks again", H.hook("Write", w), ["never.js", "501"]);
  F.check("the repeated blocked Write still left no file", !fs.existsSync(fresh), fresh);
  const p = H.put(H.repoPath("e12/big.js"), F.codeLines(HARD + 10));
  const before = fs.readFileSync(p);
  const grow = { file_path: p, old_string: "const a1 = 1;\n", new_string: "const a1 = 1;\nconst extra = 0;\n" };
  H.blocks("Edit growing an over-HARD file blocks", H.hook("Edit", grow), ["big.js", "511"]);
  F.check("the blocked Edit left the file byte-identical", fs.readFileSync(p).equals(before), p);
  H.blocks("the same Edit repeated blocks with the same numbers", H.hook("Edit", grow), ["big.js", "511", "500"]);
  const shrink = { file_path: p, old_string: "const a1 = 1;\nconst a2 = 2;\n", new_string: "" };
  H.approves("Edit shrinking the over-HARD file approves", H.hook("Edit", shrink));
  H.approves("the same shrink Edit repeated approves again", H.hook("Edit", shrink));
  F.check("judging the shrink twice left the file byte-identical", fs.readFileSync(p).equals(before), p);
})));
caseEnd();

// CODE_FILE_EXTENSIONS in the config root's .env decides which files are code: a listed extension
// is size-checked, an unlisted one is out of scope (classifyRepoPath -> null -> approve).
caseBegin("E13-code-file-extensions-decide-code-scope", "hooks/block-post-edit-size/file-size.js");
test("E13", () => noNewFailures(F.failureCount, () => F.run("E13", () => {
  const extra = H.F.configRoot("edit-ext-extra", ["COMMENT_BLOCK_ENFORCE=on", "COMMENT_BLOCK_MAX_LINES=10", "CODE_FILE_EXTENSIONS=js;sh;py;zzz"]);
  const noJs = H.F.configRoot("edit-ext-no-js", ["COMMENT_BLOCK_ENFORCE=on", "COMMENT_BLOCK_MAX_LINES=10", "CODE_FILE_EXTENSIONS=py;sh"]);
  const w = (rel, cfg) => H.hook("Write", { file_path: H.repoPath(rel), content: F.codeLines(HARD + 1) }, { cfg });
  H.blocks("extra extension zzz listed: a new HARD+1 .zzz file blocks", w("e13/extra.zzz", extra), ["extra.zzz", "501", "500"]);
  H.approves("control: default list (js;sh;py): the same .zzz file is out of scope", w("e13/default.zzz"));
  H.approves("js unlisted (py;sh): a new HARD+1 .js file is out of scope and approves", w("e13/nojs.js", noJs));
  H.blocks("control: py;sh still blocks a HARD+1 .py file", w("e13/nojs.py", noJs), ["nojs.py", "501"]);
  H.blocks("control: default list blocks the same HARD+1 .js file", w("e13/default.js"), ["default.js", "501"]);
})));
caseEnd();
