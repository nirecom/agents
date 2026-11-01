#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/user-instructions.js, user-instructions.example.md, user-instructions-jev.example.md, .gitignore
// Tags: TL2, hooks, user-instructions, template, gitignore, html-comment, fail-open, scope:issue-specific, user-instructions-jev, truncation
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
const { after, test } = require("node:test");
const { noNewFailures } = require("../lib/case-verdict");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "user-instr-tpl-"));
const CFG = path.join(TMP, "cfg");
const TRANSCRIPTS = path.join(TMP, "transcript-base");
for (const d of [CFG, TRANSCRIPTS]) fs.mkdirSync(d);
process.env.AGENTS_MAIN_ROOT = CFG;
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = TRANSCRIPTS;
delete process.env.CONV_LANG;
delete process.env.PLAN_LANG;
after(() => {
  process.stdout.write(`Total: ${passed} passed, ${failed} failed, ${skipped} skipped\n`);
  restore();
  fs.rmSync(TMP, { recursive: true, force: true });
});

const ROOT = path.join(__dirname, "..", "..");
const TEMPLATE = path.join(ROOT, "user-instructions.example.md");
const JEV_TEMPLATE = path.join(ROOT, "user-instructions-jev.example.md");
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
// verdict(fn) -> the node:test body of one case: it fails when a check inside fn failed.
const verdict = (fn) => () => noNewFailures(() => failed, fn);
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
test("template-is-comment-only", verdict(() => {
  check("E1: user-instructions.example.md exists at the checkout root", () => eq(fs.existsSync(TEMPLATE) && fs.statSync(TEMPLATE).isFile(), true, "template is a file"));
  check("E2: with every <!-- --> stripped, the template is whitespace-only", () => { const t = readTemplate(); eq([comments(t).length > 0, stripComments(t).trim()], [true, ""], "[has a comment, remaining text]"); });
  check("E3: the comment text names user-instructions.md as the copy-to target", () => eq(comments(readTemplate()).some((c) => /(^|[^.\w-])user-instructions\.md\b/.test(c)), true, "user-instructions.md named in a comment"));
}));
caseEnd();

caseBegin("template-copy-injects-nothing", "hooks/lib/user-instructions.js");
test("template-copy-injects-nothing", verdict(() => {
  check("E4: the template copied verbatim as user-instructions.md -> getUserInstructionsInjection() is null", () => {
    fs.writeFileSync(path.join(COPY, "user-instructions.md"), readTemplate());
    delete require.cache[require.resolve(UI_LIB)];
    eq(require(UI_LIB).getUserInstructionsInjection(), null, "injection");
  });
}));
caseEnd();

// #2461: user-instructions-jev.md is read by the same readInstructionFile under its own header,
// and the user-instructions.md injection keeps its truncation mark.
caseBegin("instruction-file-jev-header", "hooks/lib/user-instructions.js");
test("instruction-file-jev-header", verdict(() => {
  const lib = () => { delete require.cache[require.resolve(UI_LIB)]; return require(UI_LIB); };
  const JEV = path.join(TMP, "user-instructions-jev.md");
  const HDR = "[user-instructions-jev]";
  check("J1: a normal user-instructions-jev.md -> its header line, then the text", () => {
    fs.writeFileSync(JEV, "Always allow X.\n<!-- note -->Ask about Y.\n");
    eq(lib().readInstructionFile(JEV, HDR), `${HDR}\nAlways allow X.\nAsk about Y.`, "block");
  });
  check("J2: a comment-only file -> null", () => {
    fs.writeFileSync(JEV, "<!-- only a comment -->\n");
    eq(lib().readInstructionFile(JEV, HDR), null, "block");
  });
  check("J3: an empty file -> null", () => {
    fs.writeFileSync(JEV, "");
    eq(lib().readInstructionFile(JEV, HDR), null, "block");
  });
  check("J4: MAX_BYTES + 1 bytes -> cut at MAX_BYTES, with the jev truncation mark", () => {
    const { MAX_BYTES, readInstructionFile } = lib();
    fs.writeFileSync(JEV, "a".repeat(MAX_BYTES + 1));
    eq(readInstructionFile(JEV, HDR), `${HDR}\n${"a".repeat(MAX_BYTES)}\n[user-instructions-jev truncated at ${MAX_BYTES} bytes]`, "block");
  });
  check("J5: getUserInstructionsInjection() over MAX_BYTES keeps the mark [user-instructions truncated at 4096 bytes]", () => {
    fs.writeFileSync(path.join(COPY, "user-instructions.md"), "b".repeat(5000));
    const got = lib().getUserInstructionsInjection();
    eq([got.startsWith("[user-instructions]\n"), got.endsWith("\n[user-instructions truncated at 4096 bytes]")], [true, true], "[header, mark]");
  });
}));
caseEnd();

// #2461: the Jev template is comment-only too, so a verbatim copy reads as nothing.
caseBegin("jev-template-is-comment-only", "user-instructions-jev.example.md");
test("jev-template-is-comment-only", verdict(() => {
  const readJevTemplate = () => fs.readFileSync(JEV_TEMPLATE, "utf8");
  check("K1: with every <!-- --> stripped, user-instructions-jev.example.md is whitespace-only", () => { const t = readJevTemplate(); eq([comments(t).length > 0, stripComments(t).trim()], [true, ""], "[has a comment, remaining text]"); });
  check("K2: the comment text names user-instructions-jev.md as the copy-to target", () => eq(comments(readJevTemplate()).some((c) => /(^|[^.\w-])user-instructions-jev\.md\b/.test(c)), true, "user-instructions-jev.md named in a comment"));
  check("K3: the template copied verbatim as user-instructions-jev.md -> readInstructionFile() is null", () => {
    const copy = path.join(TMP, "user-instructions-jev.md");
    fs.writeFileSync(copy, readJevTemplate());
    delete require.cache[require.resolve(UI_LIB)];
    eq(require(UI_LIB).readInstructionFile(copy, "[user-instructions-jev]"), null, "block");
  });
}));
caseEnd();

caseBegin("gitignore-ignores-jev-copy-not-template", ".gitignore");
test("gitignore-ignores-jev-copy-not-template", verdict(() => {
  check("K4: .gitignore has the line user-instructions-jev.md", () => eq(gitignoreLines().includes("user-instructions-jev.md"), true, "line present"));
  check("K5: no .gitignore line ignores user-instructions-jev.example.md", () => eq(gitignoreLines().filter((l) => l === "user-instructions-jev.example.md" || /^\/?user-instructions[^/]*\*/.test(l) || l === "*.example.md"), [], "matching lines"));
  const ci = (p) => spawnSync("git", ["check-ignore", "--no-index", "-q", p], { cwd: ROOT, encoding: "utf8", timeout: 30000 });
  const probe = ci("user-instructions-jev.example.md");
  if (probe.error || (probe.status !== 0 && probe.status !== 1)) {
    skipped += 1;
    process.stdout.write(`SKIP: K6 — git check-ignore unavailable (${probe.error || `exit ${probe.status}`})\n`);
  } else {
    check("K6: git check-ignore — Jev template not ignored (exit 1), Jev copy ignored (exit 0)", () => eq([probe.status, ci("user-instructions-jev.md").status], [1, 0], "[template exit, copy exit]"));
  }
}));
caseEnd();

caseBegin("gitignore-ignores-copy-not-template", ".gitignore");
test("gitignore-ignores-copy-not-template", verdict(() => {
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
}));
caseEnd();
