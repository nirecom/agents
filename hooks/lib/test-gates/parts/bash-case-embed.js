"use strict";
// The bash entry's caseEmbedRules part (#2507 D7; ports bin/lib/test-language-parts/bash-case-embed.sh
// for the ops the gates ask: deps, leftover-defs, self-impl, case-count, syntax-check, rules-doc).
// run(op, file, helper, { cases }) -> { rc, stdout, stderr }. cases are the reader's (crr's deps);
// without them no line is inside a case, as when bash_case_embed runs in a fresh shell. The
// helper argument is ignored: as in bash, self-impl reads the bash entry's own helper library.

const fs = require("fs");
const path = require("path");
const { fileLines, scanLine, heredocTerm, heredocEnds } = require("./bash-scan");
const { REPO_ROOT, entryById, fieldValue } = require("../registry");
const { toWindowsPath } = require("../../branch-diff");
const S = require("../source");

const RE_DEF1 = /^([A-Za-z_][A-Za-z0-9_:.-]*)[ \t\n\v\f\r]*\(\)/;
const RE_DEF2 = /^function[ \t\n\v\f\r]+([A-Za-z_][A-Za-z0-9_:.-]*)/;
const RE_VAR = /(\$\{?[A-Za-z_][A-Za-z0-9_]*)/;
const RE_HELPER_DEF = /^(function[ \t\n\v\f\r]+)?([A-Za-z_][A-Za-z0-9_:.-]*)[ \t\n\v\f\r]*(\(\)|\{)/;
const RE_COUNTER = /^[ \t\n\v\f\r]*(PASS|FAIL)=0([ \t\n\v\f\r;]|$)/;

// scan(file, cases) — { code: [""(0), line 1, ...], defs: [{ name, line }] } as _bce_scan.
function scan(file, cases) {
  const code = [""];
  const defs = [];
  const lines = fileLines(file);
  if (lines === null) return { code, defs };
  const inCase = (n) => cases.some((c) => n > Number(c.begin) && n < Number(c.end));
  let hd = null;
  for (const [i, line] of lines.entries()) {
    const lineno = i + 1;
    if (hd) {
      if (heredocEnds(line, hd)) hd = null;
      code.push("");
      continue;
    }
    hd = heredocTerm(line) || null;
    let c = scanLine(line).code;
    const m = RE_DEF1.exec(c) || RE_DEF2.exec(c);
    if (m && !inCase(lineno)) {
      defs.push({ name: m[1], line: lineno });
      c = c.slice(m[0].length);
    }
    for (let v = RE_VAR.exec(c); v; v = RE_VAR.exec(c)) c = c.replace(v[1], () => "$");
    code.push(c);
  }
  return { code, defs };
}

const refers = (codeLine, name) => new RegExp(`(^|[^A-Za-z0-9_])${name.replace(/\./g, "\\.")}([^A-Za-z0-9_]|$)`).test(codeLine);

function deps(file, cases) {
  const s = scan(file, cases);
  return cases.map((c, i) => {
    const used = s.defs.filter((d) => {
      for (let l = Number(c.begin) + 1; l < Number(c.end); l += 1) if (refers(s.code[l] || "", d.name)) return true;
      return false;
    });
    return `${i}\t${used.map((d) => d.name).join(",")}`;
  });
}

function leftoverDefs(file, cases) {
  const s = scan(file, cases);
  return s.defs.filter((d) => !s.code.slice(1).some((l) => refers(l, d.name))).map((d) => `${d.line}\t${d.name}`);
}

function helperNames(helper) {
  const names = new Set();
  const lines = helper ? fileLines(helper) : null;
  for (const l of lines || []) {
    const m = RE_HELPER_DEF.exec(l);
    if (m) names.add(m[2]);
  }
  return names;
}

function selfImpl(file, cases, helper) {
  const names = helperNames(helper);
  const s = scan(file, cases);
  const rows = [];
  for (let l = 1; l < s.code.length; l += 1) {
    const m = RE_COUNTER.exec(s.code[l]);
    if (m) rows.push(`${l}\tcounter-init\t${m[1]}=0`);
  }
  for (const d of s.defs) if (names.has(d.name)) rows.push(`${d.line}\tharness-redef\t${d.name}`);
  return rows;
}

function syntaxCheck(file) {
  const cp = require("node:child_process");
  const r = S.isMem(file)
    ? cp.spawnSync("bash", ["-n"], { input: file.text, encoding: "utf8", timeout: 60000 })
    : cp.spawnSync("bash", ["-n", file], { encoding: "utf8", timeout: 60000 });
  return { rc: r.error || r.status !== 0 ? 1 : 0, stdout: "", stderr: r.stderr || "" };
}

// The entry's helper library on disk (keyed by the entry, so a temp copy finds it).
function defaultHelper() {
  const rel = fieldValue(entryById("bash"), "helperLibrary.path");
  return rel ? path.join(REPO_ROOT, ...rel.split("/")) : "";
}

const ok = (rows) => ({ rc: 0, stdout: rows.map((r) => `${r}\n`).join(""), stderr: "" });

function run(op, file, helper, opts = {}) {
  const cases = opts.cases || [];
  const abs = file === undefined || S.isMem(file) ? file : toWindowsPath(String(file));
  if (["deps", "leftover-defs", "self-impl", "syntax-check"].includes(op) && !abs) {
    return { rc: 1, stdout: "", stderr: `bash_case_embed ${op}: file required\n` };
  }
  switch (op) {
    case "rules-doc": return ok(["skills/sweep-tests/embed-rules/bash.md"]);
    case "deps": return ok(deps(abs, cases));
    case "leftover-defs": return ok(leftoverDefs(abs, cases));
    case "self-impl": {
      const h = defaultHelper();
      return ok(selfImpl(abs, cases, h && fs.existsSync(h) ? h : ""));
    }
    case "syntax-check": return syntaxCheck(abs);
    case "case-count": return { rc: 1, stdout: "", stderr: "" };
    default: return { rc: 2, stdout: "", stderr: `[bash-case-embed] unknown op: ${op}\n` };
  }
}

module.exports = { run };
