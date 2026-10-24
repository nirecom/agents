#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/user-instructions.js, user-instructions.example.md, .gitignore
// Tags: TL2, hooks, user-instructions, template, gitignore, html-comment, fail-open, scope:issue-specific
// #2731: the tracked template user-instructions.example.md (copy it, save it as user-instructions.md)
// is comment-only, so a verbatim copy injects nothing; .gitignore ignores the copy, never the template.
// Fixture: hooks/ is copied into a temp checkout; the real repo files are only read.
// TL3 gap (what this test does NOT catch):
// - none beyond the hook registrations, covered by tests/hooks/feature-2240-user-instructions.js

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "user-instr-tpl-"));
const CFG = path.join(TMP, "cfg");
const TRANSCRIPTS = path.join(TMP, "transcript-base");
for (const d of [CFG, TRANSCRIPTS]) fs.mkdirSync(d);
process.env.AGENTS_MAIN_ROOT = CFG;
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = TRANSCRIPTS;
delete process.env.CONV_LANG;
delete process.env.PLAN_LANG;
process.on("exit", () => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true });
});

const ROOT = path.join(__dirname, "..", "..");
const TEMPLATE = path.join(ROOT, "user-instructions.example.md");
const GITIGNORE = path.join(ROOT, ".gitignore");
const COPY = path.join(TMP, "agents");
fs.cpSync(path.join(ROOT, "hooks"), path.join(COPY, "hooks"), { recursive: true, filter: (src) => !/[\\/](node_modules|\.git)([\\/]|$)/.test(src) });
const UI_LIB = path.join(COPY, "hooks", "lib", "user-instructions.js");

let passed = 0;
let failed = 0;
let skipped = 0;
function check(name, fn) {
  let why = null;
  try {
    const r = fn();
    if (typeof r === "string") why = r;
  } catch (e) {
    why = e && e.message ? e.message : String(e);
  }
  if (why === null) {
    passed += 1;
    process.stdout.write(`PASS: ${name}\n`);
  } else {
    failed += 1;
    process.stdout.write(`FAIL: ${name} — ${why}\n`);
  }
}
const show = (v) => (v === undefined ? "undefined" : JSON.stringify(v));
function eq(got, want, what) {
  if (JSON.stringify(got) !== JSON.stringify(want)) throw new Error(`${what || "value"}: want=${show(want)} got=${show(got)}`);
}
function readTemplate() {
  if (!fs.existsSync(TEMPLATE)) throw new Error("user-instructions.example.md does not exist at the checkout root");
  return fs.readFileSync(TEMPLATE, "utf8");
}
const comments = (s) => s.match(/<!--[\s\S]*?-->/g) || [];
const stripComments = (s) => s.replace(/<!--[\s\S]*?-->/g, "");
const gitignoreLines = () => fs.readFileSync(GITIGNORE, "utf8").split(/\r?\n/).map((l) => l.trim()).filter((l) => l !== "" && !l.startsWith("#"));

caseBegin("template-is-comment-only", "user-instructions.example.md");
{
  check("E1: user-instructions.example.md exists at the checkout root", () => eq(fs.existsSync(TEMPLATE) && fs.statSync(TEMPLATE).isFile(), true, "template is a file"));
  check("E2: with every <!-- --> stripped, the template is whitespace-only", () => { const t = readTemplate(); eq([comments(t).length > 0, stripComments(t).trim()], [true, ""], "[has a comment, remaining text]"); });
  check("E3: the comment text names user-instructions.md as the copy-to target", () => eq(comments(readTemplate()).some((c) => /(^|[^.\w-])user-instructions\.md\b/.test(c)), true, "user-instructions.md named in a comment"));
}
caseEnd();

caseBegin("template-copy-injects-nothing", "hooks/lib/user-instructions.js");
{
  check("E4: the template copied verbatim as user-instructions.md -> getUserInstructionsInjection() is null", () => {
    fs.writeFileSync(path.join(COPY, "user-instructions.md"), readTemplate());
    delete require.cache[require.resolve(UI_LIB)];
    eq(require(UI_LIB).getUserInstructionsInjection(), null, "injection");
  });
}
caseEnd();

caseBegin("gitignore-ignores-copy-not-template", ".gitignore");
{
  check("G1: .gitignore has the line user-instructions.md", () => eq(gitignoreLines().includes("user-instructions.md"), true, "line present"));
  check("G2: no .gitignore line ignores user-instructions.example.md (exact or user-instructions* glob)", () => eq(gitignoreLines().filter((l) => l === "user-instructions.example.md" || /^\/?user-instructions[^/]*\*/.test(l) || l === "*.example.md"), [], "matching lines"));
  check("G3: the old user-instructions.local.md line is gone", () => eq(gitignoreLines().includes("user-instructions.local.md"), false, "old line present"));
  const ci = (p) => spawnSync("git", ["check-ignore", "--no-index", "-q", p], { cwd: ROOT, encoding: "utf8", timeout: 30000 });
  const probe = ci("user-instructions.example.md");
  if (probe.error || (probe.status !== 0 && probe.status !== 1)) {
    skipped += 1;
    process.stdout.write(`SKIP: G4 — git check-ignore unavailable (${probe.error || `exit ${probe.status}`})\n`);
  } else {
    check("G4: git check-ignore — template not ignored (exit 1), copy ignored (exit 0)", () => eq([probe.status, ci("user-instructions.md").status], [1, 0], "[template exit, copy exit]"));
  }
}
caseEnd();

process.stdout.write(`Total: ${passed} passed, ${failed} failed, ${skipped} skipped\n`);
process.exitCode = failed === 0 ? 0 : 1;
