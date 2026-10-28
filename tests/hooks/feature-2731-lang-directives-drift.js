#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/lang-directives.txt, hooks/lib/conv-lang.js
// Tags: TL1, hooks, lang, conv-lang, drift, static, template, scope:issue-specific
// #2731 R4: the conv-lang-fallback:v1 lines in agents/*.md and the two planning SKILL.md files
// trigger on the literal "Respond to the user in <language>". The template's CONV_LANG line must
// keep that first sentence, and TERMS must name no language (issue-create cites it alone).

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const fs = require("fs");
const os = require("os");
const path = require("path");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "lang-drift-"));
const CFG = path.join(TMP, "cfg");
fs.mkdirSync(CFG);
process.env.AGENTS_MAIN_ROOT = CFG;
process.on("exit", () => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true });
});

const ROOT = path.join(__dirname, "..", "..");
const TEMPLATE = path.join(ROOT, "hooks", "lib", "lang-directives.txt");
const MARKER = "<!-- conv-lang-fallback:v1 -->";

let passed = 0;
let failed = 0;
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

// templateEntries() -> { KEY: value } from the non-comment lines; throws when the file is missing.
function templateEntries() {
  const out = {};
  for (const raw of fs.readFileSync(TEMPLATE, "utf8").split(/\r?\n/)) {
    if (raw.trim() === "" || raw.startsWith("#")) continue;
    const i = raw.indexOf("=");
    if (i <= 0) throw new Error(`line without KEY=: ${show(raw)}`);
    out[raw.slice(0, i)] = raw.slice(i + 1);
  }
  return out;
}

// Every file carrying the fallback marker, from agents/*.md and skills/*/SKILL.md.
function fallbackFiles() {
  const files = [];
  const agentsDir = path.join(ROOT, "agents");
  for (const f of fs.readdirSync(agentsDir)) if (f.endsWith(".md")) files.push(path.join(agentsDir, f));
  const skillsDir = path.join(ROOT, "skills");
  for (const d of fs.readdirSync(skillsDir)) {
    const p = path.join(skillsDir, d, "SKILL.md");
    if (fs.existsSync(p)) files.push(p);
  }
  return files.filter((p) => fs.readFileSync(p, "utf8").includes(MARKER));
}
// The quoted trigger of one fallback line, e.g. "Respond to the user in <language>".
function triggerOf(file) {
  const line = fs.readFileSync(file, "utf8").split(/\r?\n/).find((l) => l.includes(MARKER));
  const m = /"([^"]*<language>[^"]*)"/.exec(line || "");
  if (!m) throw new Error(`${path.relative(ROOT, file)}: no quoted "<language>" trigger in ${show(line)}`);
  return m[1];
}

caseBegin("template-shape", "hooks/lib/lang-directives.txt");
{
  check("S1: lang-directives.txt exists", () => eq(fs.existsSync(TEMPLATE), true, "exists"));
  check("S2: the template defines exactly TERMS, CONV_LANG, PLAN_LANG, CODEX_FREE_TEXT", () => eq(Object.keys(templateEntries()).sort(), ["CODEX_FREE_TEXT", "CONV_LANG", "PLAN_LANG", "TERMS"], "keys"));
  check("S3: CONV_LANG, PLAN_LANG and CODEX_FREE_TEXT each reference {lang} and {terms}", () => {
    const t = templateEntries();
    eq(["CONV_LANG", "PLAN_LANG", "CODEX_FREE_TEXT"].filter((k) => !(t[k] || "").includes("{lang}") || !(t[k] || "").includes("{terms}")), [], "keys missing a placeholder");
  });
  check("S4: TERMS names no language (no {lang}) and nests no {terms}", () => {
    const t = templateEntries().TERMS;
    eq([typeof t === "string" && t.length > 0, /\{lang\}|\{terms\}/.test(t || "")], [true, false], "[non-empty, has placeholder]");
  });
  check("S5: every value fits the reader's guards (TERMS <= 300, others <= 600 characters)", () => {
    const t = templateEntries();
    eq(Object.keys(t).filter((k) => t[k].length > (k === "TERMS" ? 300 : 600)), [], "keys over the limit");
  });
}
caseEnd();

caseBegin("conv-lang-first-sentence-matches-fallback-trigger", "hooks/lib/lang-directives.txt");
{
  const files = fallbackFiles();
  check("F1: fixture — at least the 14 known files carry the conv-lang-fallback:v1 line", () => eq(files.length >= 14, true, `count=${files.length}`));
  check("F2: CONV_LANG starts with 'Respond to the user in {lang}.'", () => eq((templateEntries().CONV_LANG || "").startsWith("Respond to the user in {lang}."), true, "starts with trigger sentence"));
  for (const f of files) {
    const rel = path.relative(ROOT, f).replace(/\\/g, "/");
    check(`F3: ${rel} trigger is a prefix of the template CONV_LANG line`, () => {
      const trigger = triggerOf(f);
      const conv = (templateEntries().CONV_LANG || "").split("{lang}").join("<language>");
      eq(conv.startsWith(trigger), true, `trigger=${show(trigger)} conv=${show(conv.slice(0, 60))}`);
    });
  }
}
caseEnd();

caseBegin("rendered-conv-lang-still-fires-the-trigger", "hooks/lib/conv-lang.js");
{
  process.env.CONV_LANG = "japanese";
  let rendered = null;
  try {
    rendered = require(path.join(ROOT, "hooks", "lib", "conv-lang.js")).getConvLangInjection();
  } catch (e) {
    rendered = `require failed: ${e.message}`;
  }
  delete process.env.CONV_LANG;
  check("R1: getConvLangInjection() for japanese starts with 'Respond to the user in japanese.'", () => eq(String(rendered).startsWith("Respond to the user in japanese."), true, `rendered=${show(rendered)}`));
  const files = fallbackFiles();
  check("R2: the rendered directive matches every fallback trigger with <language> filled in", () => eq(files.filter((f) => !String(rendered).startsWith(triggerOf(f).split("<language>").join("japanese"))).map((f) => path.relative(ROOT, f)), [], "files whose trigger misses"));
}
caseEnd();

process.stdout.write(`Total: ${passed} passed, ${failed} failed\n`);
process.exitCode = failed === 0 ? 0 : 1;
