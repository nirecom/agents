"use strict";
// tests/skills/feature-1076-skill-md-frontmatter.js
// Tests: skills/worktree-end/scripts/detect-restart-skill-md.js
// Tags: scope:issue-specific, TL2, worktree-end, detect-restart, skill-md, frontmatter, unified-diff, table-driven
// #1076: the helper reads a unified diff on stdin and prints yes when any SKILL.md block is added,
// deleted, renamed, or changes a line inside the frontmatter; otherwise no. Errors print no, exit 0.
// TL3 gap: a real `gh pr diff` payload (GitHub's exact header layout) is not exercised here; the
// detect-restart wiring test (tests/skills/feature-2303-1076-detect-restart.sh) covers the stdin seam.

const { caseBegin, caseEnd } = require("../lib/harness");
const { test } = require("node:test");
const assert = require("node:assert");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const ROOT = path.resolve(__dirname, "..", "..");
const HELPER = path.join(ROOT, "skills", "worktree-end", "scripts", "detect-restart-skill-md.js");

function runHelper(input) {
  const done = spawnSync(process.execPath, [HELPER], { input, encoding: "utf8", timeout: 30000 });
  return { status: done.status, out: String(done.stdout || "").trim(), err: String(done.stderr || "") };
}

const lines = (...ls) => ls.join("\n") + "\n";

// fileHeader(p) — the diff --git / index / ---/+++ header of a modified file p.
const fileHeader = (p) => [`diff --git a/${p} b/${p}`, "index 1111111..2222222 100644", `--- a/${p}`, `+++ b/${p}`];

const NEW_SKILL = lines(
  "diff --git a/skills/foo/SKILL.md b/skills/foo/SKILL.md",
  "new file mode 100644",
  "index 0000000..1111111",
  "--- /dev/null",
  "+++ b/skills/foo/SKILL.md",
  "@@ -0,0 +1,4 @@",
  "+---",
  "+name: foo",
  "+---",
  "+body");

const DELETED_SKILL = lines(
  "diff --git a/skills/foo/SKILL.md b/skills/foo/SKILL.md",
  "deleted file mode 100644",
  "index 1111111..0000000",
  "--- a/skills/foo/SKILL.md",
  "+++ /dev/null",
  "@@ -1,4 +0,0 @@",
  "----",
  "-name: foo",
  "----",
  "-body");

const RENAMED_SKILL = lines(
  "diff --git a/skills/foo/SKILL.md b/skills/bar/SKILL.md",
  "similarity index 100%",
  "rename from skills/foo/SKILL.md",
  "rename to skills/bar/SKILL.md");

// A hunk that starts at line 1 and holds the whole frontmatter; the change is inside it.
const FM_CHANGE_LINE1 = lines(
  ...fileHeader("skills/foo/SKILL.md"),
  "@@ -1,6 +1,6 @@",
  " ---",
  " name: foo",
  "-description: old",
  "+description: new",
  " user-invocable: true",
  " ---",
  " ");

// Same hunk shape, but only a frontmatter line is removed (no + line).
const FM_REMOVAL_LINE1 = lines(
  ...fileHeader("skills/foo/SKILL.md"),
  "@@ -1,5 +1,4 @@",
  " ---",
  " name: foo",
  "-user-invocable: false",
  " ---",
  " ");

// The hunk covers line 1 and the closing ---, but the change sits after the closing ---.
const BODY_CHANGE_LINE1 = lines(
  ...fileHeader("skills/foo/SKILL.md"),
  "@@ -1,7 +1,7 @@",
  " ---",
  " name: foo",
  " ---",
  " ",
  "-old body",
  "+new body",
  " more");

// Insertion-only line-1 hunk (old side has no - line): a key is added inside the frontmatter.
const FM_INSERTION_LINE1 = lines(
  ...fileHeader("skills/foo/SKILL.md"),
  "@@ -1,5 +1,6 @@",
  " ---",
  " name: foo",
  "+model: sonnet",
  " description: x",
  " ---",
  " ");

// Insertion-only line-1 hunk whose only + line sits after the closing --- (body).
const BODY_INSERTION_LINE1 = lines(
  ...fileHeader("skills/foo/SKILL.md"),
  "@@ -1,5 +1,6 @@",
  " ---",
  " name: foo",
  " ---",
  " ",
  "+new body line",
  " more");

// A hunk that starts mid-frontmatter: no --- before the change, --- after it.
const FM_CHANGE_MID = lines(
  ...fileHeader("skills/foo/SKILL.md"),
  "@@ -3,7 +3,7 @@",
  " description: x",
  " model: sonnet",
  "-user-invocable: true",
  "+user-invocable: false",
  " ---",
  " ",
  " # Title");

// A hunk that starts at the closing ---: the --- is before the change, so the change is body.
const BODY_CHANGE_MID = lines(
  ...fileHeader("skills/foo/SKILL.md"),
  "@@ -5,6 +5,6 @@",
  " ---",
  " ",
  " # Title",
  "-old line",
  "+new line",
  " tail");

// A body-only hunk far from the top with no --- anywhere.
const BODY_CHANGE_FAR = lines(
  ...fileHeader("skills/foo/SKILL.md"),
  "@@ -20,7 +20,7 @@",
  " context a",
  " context b",
  " context c",
  "-old step",
  "+new step",
  " context d",
  " context e");

// Known residual false positive, kept deliberately (errs toward restart required, the safe side): a
// mid-file body change followed by a markdown horizontal rule `---` context line reads as frontmatter.
const BODY_CHANGE_MID_HRULE_AFTER = lines(
  ...fileHeader("skills/foo/SKILL.md"),
  "@@ -30,6 +30,6 @@",
  " context a",
  " context b",
  "-old step",
  "+new step",
  " ---",
  " context c");

const BODY_CHANGE_FAR_OTHER = BODY_CHANGE_FAR.replace(/skills\/foo\//g, "skills/other/");

// A frontmatter-shaped change in a file that is not SKILL.md.
const DOC_FM_CHANGE = FM_CHANGE_LINE1.replace(/skills\/foo\/SKILL\.md/g, "docs/notes.md");
const README_NEW = NEW_SKILL.replace(/skills\/foo\/SKILL\.md/g, "README.md");
const LOOKALIKE_NEW = NEW_SKILL.replace(/skills\/foo\/SKILL\.md/g, "skills/foo/NOT-SKILL.md");
const ROOT_SKILL_NEW = NEW_SKILL.replace(/skills\/foo\/SKILL\.md/g, "SKILL.md");

const cases = [
  { name: "new-file-mode", input: NEW_SKILL, want: "yes" },
  { name: "deleted-file-mode", input: DELETED_SKILL, want: "yes" },
  { name: "rename-from", input: RENAMED_SKILL, want: "yes" },
  { name: "root-skill-md-new-file", input: ROOT_SKILL_NEW, want: "yes" },
  { name: "line1-hunk-frontmatter-change", input: FM_CHANGE_LINE1, want: "yes" },
  { name: "line1-hunk-frontmatter-removal-only", input: FM_REMOVAL_LINE1, want: "yes" },
  { name: "line1-hunk-change-after-closing-delimiter", input: BODY_CHANGE_LINE1, want: "no" },
  { name: "mid-hunk-no-delimiter-before-delimiter-after", input: FM_CHANGE_MID, want: "yes" },
  { name: "mid-hunk-delimiter-before-change", input: BODY_CHANGE_MID, want: "no" },
  { name: "body-only-far-hunk", input: BODY_CHANGE_FAR, want: "no" },
  { name: "multi-block-qualifying-last", input: BODY_CHANGE_FAR + FM_CHANGE_LINE1, want: "yes" },
  { name: "multi-block-qualifying-first", input: NEW_SKILL + BODY_CHANGE_FAR_OTHER, want: "yes" },
  { name: "multi-block-none-qualifies", input: BODY_CHANGE_FAR + BODY_CHANGE_FAR_OTHER, want: "no" },
  { name: "non-skill-md-new-file-ignored", input: README_NEW, want: "no" },
  { name: "non-skill-md-frontmatter-change-ignored", input: DOC_FM_CHANGE, want: "no" },
  { name: "lookalike-name-ignored", input: LOOKALIKE_NEW, want: "no" },
  { name: "non-skill-block-then-skill-body-only", input: README_NEW + BODY_CHANGE_FAR, want: "no" },
  { name: "empty-input", input: "", want: "no" },
  { name: "line1-hunk-frontmatter-insertion-only", input: FM_INSERTION_LINE1, want: "yes" },
  { name: "line1-hunk-insertion-after-closing-delimiter", input: BODY_INSERTION_LINE1, want: "no" },
  { name: "mid-hunk-body-change-hrule-after-known-false-positive", input: BODY_CHANGE_MID_HRULE_AFTER, want: "yes" },
  { name: "garbage-input", input: "@@ not a diff @@\n\u0000\u0001 random bytes\n+++\n---\n", want: "no" },
];

caseBegin("helper-diff-table", "skills/worktree-end/scripts/detect-restart-skill-md.js");
for (const { name, input, want } of cases) {
  test(name, () => {
    const got = runHelper(input);
    assert.strictEqual(got.status, 0, `${name}: exit status ${got.status} (stderr: ${got.err.slice(0, 200)})`);
    assert.strictEqual(got.out, want, `${name}: want=${want} got=${JSON.stringify(got.out)}`);
  });
}
caseEnd();
