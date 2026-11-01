#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/lang-directive.js, hooks/lib/lang-directives.txt
// Tags: TL2, hooks, lang, conv-lang, plan-lang, codex, template, fallback, scope:issue-specific
// #2731: lang-directives.txt is the one source of the three language directives. The reader
// renders {lang} and {terms}, falls back per key to the fixed sentence when a line is broken,
// and drops only the terms sentence when TERMS is broken. --codex conv|plan prints the
// CODEX_FREE_TEXT line, or nothing when the language is a noop; it always exits 0.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { after, test } = require("node:test");
const { noNewFailures } = require("../lib/case-verdict");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "lang-directive-"));
const CFG = path.join(TMP, "cfg");
fs.mkdirSync(CFG);
process.env.AGENTS_MAIN_ROOT = CFG;
delete process.env.CONV_LANG;
delete process.env.PLAN_LANG;
after(() => {
  process.stdout.write(`Total: ${passed} passed, ${failed} failed\n`);
  restore();
  fs.rmSync(TMP, { recursive: true, force: true });
});

const ROOT = path.join(__dirname, "..", "..");
const LIB = path.join(ROOT, "hooks", "lib", "lang-directive.js");
const REAL_TEMPLATE = path.join(ROOT, "hooks", "lib", "lang-directives.txt");

let LD = null;
let loadError = null;
try { LD = require(LIB); } catch (e) { loadError = e; }
function lib() {
  if (!LD) throw new Error(`hooks/lib/lang-directive.js not loadable: ${loadError && String(loadError.message).split("\n")[0]}`);
  return LD;
}

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
// verdict(fn) -> the node:test body of one case: it fails when a check inside fn failed.
const verdict = (fn) => () => noNewFailures(() => failed, fn);
function eq(got, want, what) {
  if (JSON.stringify(got) !== JSON.stringify(want)) throw new Error(`${what || "value"}: want=${show(want)} got=${show(got)}`);
}

const TERMS = "Keep glossary terms in their exact spelling, and leave common engineering terms, identifiers and command names untranslated (e.g. gap, fallback).";
const conv = (l) => `Respond to the user in ${l}. This covers everything you write, including narration between tool calls and a subagent's final report to its caller. Write each sentence in ${l}.`;
const plan = (l) => `Write planning artifacts (files under the plans directory) in ${l}. Write each sentence in ${l}.`;
const codex = (l) => `Write every free-text field (detail, summary, concern text) in ${l}. Keep JSON keys and enum values exactly as given.`;
const FB = {
  CONV_LANG: (l) => `Respond to the user in ${l}. This applies to all text you write, including narration between tool calls.`,
  PLAN_LANG: (l) => `Write planning artifacts (files under the plans directory) in ${l}.`,
  CODEX_FREE_TEXT: (l) => `Write every free-text field (detail, summary, concern text) in ${l}.`,
};

// Fixture template lines; FX_TERMS differs from the real TERMS so a fixture render is recognisable.
const FX_TERMS = "Use the exact a=b spelling.";
const LINES = {
  TERMS: `TERMS=${FX_TERMS}`,
  CONV_LANG: "CONV_LANG=Respond to the user in {lang}. Fixture conv in {lang}. {terms}",
  PLAN_LANG: "PLAN_LANG=Fixture plan in {lang}. {terms}",
  CODEX_FREE_TEXT: "CODEX_FREE_TEXT=Fixture codex in {lang}. {terms}",
};
const FX = {
  CONV_LANG: (l) => `Respond to the user in ${l}. Fixture conv in ${l}. ${FX_TERMS}`,
  PLAN_LANG: (l) => `Fixture plan in ${l}. ${FX_TERMS}`,
  CODEX_FREE_TEXT: (l) => `Fixture codex in ${l}. ${FX_TERMS}`,
};
const KEYS = ["CONV_LANG", "PLAN_LANG", "CODEX_FREE_TEXT"];
let fxCount = 0;
// useTemplate(overrides) — writes a fixture template (null drops a key) and points the reader at it.
function useTemplate(overrides, eol) {
  const merged = Object.assign({}, LINES, overrides || {});
  const body = ["# fixture template", "# CONV_LANG=commented out, never read"].concat(Object.values(merged).filter((v) => v !== null));
  const p = path.join(TMP, `tpl-${++fxCount}.txt`);
  fs.writeFileSync(p, body.join(eol || "\n") + (eol || "\n"));
  pointAt(p);
  return p;
}
// pointAt(p) — the reader's test hook; a no-op before the module exists, so each check reports it.
function pointAt(p) {
  if (LD && typeof LD._setTemplateFileForTest === "function") LD._setTemplateFileForTest(p);
}
const render = (key, l) => lib().renderDirective(key, l || "japanese");

caseBegin("real-template-renders-lang-and-terms", "hooks/lib/lang-directive.js");
test("real-template-renders-lang-and-terms", verdict(() => {
  pointAt(REAL_TEMPLATE);
  check("N1: CONV_LANG renders {lang} and ends with the TERMS sentence", () => eq(render("CONV_LANG"), `${conv("japanese")} ${TERMS}`, "CONV_LANG"));
  check("N2: PLAN_LANG renders {lang} and ends with the TERMS sentence", () => eq(render("PLAN_LANG"), `${plan("japanese")} ${TERMS}`, "PLAN_LANG"));
  check("N3: CODEX_FREE_TEXT renders {lang} and ends with the TERMS sentence", () => eq(render("CODEX_FREE_TEXT"), `${codex("japanese")} ${TERMS}`, "CODEX_FREE_TEXT"));
  check("N4: every {lang} occurrence is replaced (multi-word language)", () => eq(render("CONV_LANG", "traditional-chinese"), `${conv("traditional-chinese")} ${TERMS}`, "CONV_LANG"));
  check("N5: renderTerms returns the TERMS line verbatim", () => eq(lib().renderTerms(), TERMS, "renderTerms"));
  check("N6: no rendered directive keeps a placeholder", () => eq(KEYS.filter((k) => /\{(lang|terms)\}/.test(render(k))), [], "keys with placeholders"));
}));
caseEnd();

caseBegin("fixture-template-parse-rules", "hooks/lib/lang-directive.js");
test("fixture-template-parse-rules", verdict(() => {
  useTemplate();
  check("P1: '#' comment lines are ignored and the value keeps any '=' after the first", () => eq(KEYS.map((k) => render(k)), KEYS.map((k) => FX[k]("japanese")), "rendered"));
  useTemplate(null, "\r\n");
  check("P2: a CRLF checkout renders exactly like LF (no carriage return, no fallback)", () => eq(KEYS.map((k) => render(k)), KEYS.map((k) => FX[k]("japanese")), "rendered"));
}));
caseEnd();

caseBegin("per-key-degradation-to-fixed-sentence", "hooks/lib/lang-directive.js");
test("per-key-degradation-to-fixed-sentence", verdict(() => {
  pointAt(path.join(TMP, "no-such-template.txt"));
  check("D1: missing template file -> every key falls back to its fixed sentence", () => eq(KEYS.map((k) => render(k)), KEYS.map((k) => FB[k]("japanese")), "rendered"));
  for (const key of KEYS) {
    useTemplate({ [key]: null });
    check(`D2: ${key} key missing -> only ${key} falls back`, () => eq(KEYS.map((k) => render(k)), KEYS.map((k) => (k === key ? FB[k] : FX[k])("japanese")), "rendered"));
    useTemplate({ [key]: `${key}=${key === "CONV_LANG" ? "Respond to the user in japanese." : "No placeholder here."} {terms}` });
    check(`D3: ${key} without {lang} -> only ${key} falls back`, () => eq(KEYS.map((k) => render(k)), KEYS.map((k) => (k === key ? FB[k] : FX[k])("japanese")), "rendered"));
    const longVal = `${LINES[key]} ${"x".repeat(600)}`;
    useTemplate({ [key]: longVal });
    check(`D4: ${key} over 600 characters -> only ${key} falls back`, () => eq(KEYS.map((k) => render(k)), KEYS.map((k) => (k === key ? FB[k] : FX[k])("japanese")), "rendered"));
  }
  useTemplate({ CONV_LANG: "CONV_LANG=Reply to the user in {lang}. Fixture conv in {lang}. {terms}" });
  check("D5: CONV_LANG whose first sentence is not 'Respond to the user in {lang}.' -> CONV_LANG falls back", () => eq(render("CONV_LANG"), FB.CONV_LANG("japanese"), "CONV_LANG"));
  check("D5: control — PLAN_LANG and CODEX_FREE_TEXT keep the template", () => eq([render("PLAN_LANG"), render("CODEX_FREE_TEXT")], [FX.PLAN_LANG("japanese"), FX.CODEX_FREE_TEXT("japanese")], "rendered"));
  useTemplate({ PLAN_LANG: `PLAN_LANG=Fixture plan in {lang}. ${"y".repeat(570)} {terms}` });
  check("D6: boundary — a 600-character-or-less value with {lang} is still used", () => eq(render("PLAN_LANG").startsWith("Fixture plan in japanese."), true, "template used"));
}));
caseEnd();

caseBegin("broken-terms-drops-only-the-terms-sentence", "hooks/lib/lang-directive.js");
test("broken-terms-drops-only-the-terms-sentence", verdict(() => {
  const bare = { CONV_LANG: "Respond to the user in japanese. Fixture conv in japanese.", PLAN_LANG: "Fixture plan in japanese.", CODEX_FREE_TEXT: "Fixture codex in japanese." };
  const variants = [
    ["TERMS missing", null],
    ["TERMS empty", "TERMS="],
    ["TERMS over 300 characters", `TERMS=${"z".repeat(301)}`],
    ["TERMS containing {lang}", "TERMS=Keep terms in {lang}."],
    ["TERMS containing {terms}", "TERMS=Keep {terms} as is."],
  ];
  for (const [label, line] of variants) {
    useTemplate({ TERMS: line });
    check(`B1: ${label} -> renderTerms is empty`, () => eq(lib().renderTerms(), "", "renderTerms"));
    check(`B1: ${label} -> all three directives drop {terms} with no trailing whitespace`, () => eq(KEYS.map((k) => render(k)), KEYS.map((k) => bare[k]), "rendered"));
  }
  useTemplate({ TERMS: `TERMS=${"t".repeat(300)}` });
  check("B2: boundary — a TERMS of exactly 300 characters is kept", () => eq(lib().renderTerms(), "t".repeat(300), "renderTerms"));
  pointAt(REAL_TEMPLATE);
}));
caseEnd();

// cli(kind, env) -> { status, out } for one `node lang-directive.js --codex <kind>` run.
function cli(args, env) {
  const e = Object.assign({}, process.env);
  delete e.CONV_LANG;
  delete e.PLAN_LANG;
  Object.assign(e, env || {});
  const r = spawnSync(process.execPath, [LIB].concat(args), { cwd: TMP, env: e, encoding: "utf8", timeout: 60000 });
  return { status: r.status, out: String(r.stdout || "").replace(/\r?\n$/, ""), stderr: r.stderr };
}

caseBegin("codex-cli-prints-the-free-text-line", "hooks/lib/lang-directive.js");
test("codex-cli-prints-the-free-text-line", verdict(() => {
  check("C1: --codex conv with CONV_LANG=japanese prints the rendered CODEX_FREE_TEXT line, exit 0", () => {
    const r = cli(["--codex", "conv"], { CONV_LANG: "japanese" });
    eq([r.status, r.out], [0, `${codex("japanese")} ${TERMS}`], "[exit, stdout]");
  });
  check("C2: --codex conv applies the conv guard (CONV_LANG=JAPANESE is lowercased)", () => eq(cli(["--codex", "conv"], { CONV_LANG: "  JAPANESE " }).out, `${codex("japanese")} ${TERMS}`, "stdout"));
  check("C3: --codex plan with PLAN_LANG=japanese prints the rendered CODEX_FREE_TEXT line", () => eq(cli(["--codex", "plan"], { PLAN_LANG: "japanese" }).out, `${codex("japanese")} ${TERMS}`, "stdout"));
  check("C4: --codex plan with PLAN_LANG=english is a real directive (english is valid for plans)", () => eq(cli(["--codex", "plan"], { PLAN_LANG: "english" }).out, `${codex("english")} ${TERMS}`, "stdout"));
  check("C5: --codex conv reads CONV_LANG only, not PLAN_LANG", () => {
    const r = cli(["--codex", "conv"], { PLAN_LANG: "japanese" });
    eq([r.status, r.out], [0, ""], "[exit, stdout]");
  });
}));
caseEnd();

caseBegin("codex-cli-noop-and-fail-open", "hooks/lib/lang-directive.js");
test("codex-cli-noop-and-fail-open", verdict(() => {
  const quiet = [
    ["--codex conv, CONV_LANG=english", ["--codex", "conv"], { CONV_LANG: "english" }],
    ["--codex conv, CONV_LANG=any", ["--codex", "conv"], { CONV_LANG: "any" }],
    ["--codex conv, CONV_LANG unset", ["--codex", "conv"], {}],
    ["--codex conv, CONV_LANG with a control character", ["--codex", "conv"], { CONV_LANG: "japanese\u0001evil" }],
    ["--codex plan, PLAN_LANG=any", ["--codex", "plan"], { PLAN_LANG: "any" }],
    ["--codex plan, PLAN_LANG unset", ["--codex", "plan"], {}],
    ["--codex with an unknown kind", ["--codex", "bogus"], { CONV_LANG: "japanese", PLAN_LANG: "japanese" }],
    ["--codex with no kind", ["--codex"], { CONV_LANG: "japanese" }],
  ];
  for (const [label, args, env] of quiet) {
    check(`Q1: ${label} -> prints nothing, exit 0`, () => {
      if (!fs.existsSync(LIB)) throw new Error("hooks/lib/lang-directive.js does not exist");
      const r = cli(args, env);
      eq([r.status, r.out], [0, ""], "[exit, stdout]");
    });
  }
}));
caseEnd();
