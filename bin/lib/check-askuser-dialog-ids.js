"use strict";
// bin/lib/check-askuser-dialog-ids.js — the full-coverage check behind bin/check-askuser-dialog-ids
// (#2764). Every line of skills/**/*.md and skills/**/scripts/*.sh (outside _archived, outside a
// YAML frontmatter) that names AskUserQuestion must carry a dialog ID (`metadata.source=<id>`) or
// the askuser-none note; every ID must be in the classification table, every table row must be
// used and valid, and every ASK_ID of the workflow-init driver must be classified.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const levels = require("../../hooks/lib/askuser-dialog-levels");

const TABLE_REL = "hooks/lib/askuser-dialog-levels.json";
const PHASES_REL = "bin/workflow/lib/workflow-init/phases";
const STEP_TABLE_REL = "hooks/workflow-state/step-table.js";
const PLACEHOLDER = "workflow-init.<ASK_ID>";
const ID_ON_LINE_RE = /metadata\.source=([A-Za-z0-9_.<>-]+)/g;
const REVIEW_HINT = "confirm against the criteria in docs/architecture/jev.md";

class TableUnreadable extends Error {}

const fwd = (p) => p.split(path.sep).join("/");

// walk(dir) -> every file under dir, skipping any _archived directory.
function walk(dir) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (_e) { return []; }
  const out = [];
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { if (e.name !== "_archived") out.push(...walk(p)); } else if (e.isFile()) out.push(p);
  }
  return out;
}

function isTarget(file) {
  if (file.endsWith(".md")) return true;
  return file.endsWith(".sh") && path.basename(path.dirname(file)) === "scripts";
}

// bodyLines(text) -> [{n, text}] with a leading YAML frontmatter dropped.
function bodyLines(text) {
  const lines = text.replace(/\r/g, "").split("\n");
  let start = 0;
  if (lines[0] === "---") {
    const end = lines.indexOf("---", 1);
    if (end > 0) start = end + 1;
  }
  return lines.slice(start).map((t, i) => ({ n: start + i + 1, text: t }));
}

// scanSkills(root) -> {marks: [{file, n, ids}], unmarked: [{file, n}]}.
function scanSkills(root) {
  const marks = [];
  const unmarked = [];
  for (const file of walk(path.join(root, "skills")).filter(isTarget).sort()) {
    const rel = fwd(path.relative(root, file));
    for (const { n, text } of bodyLines(fs.readFileSync(file, "utf8"))) {
      if (!text.includes("AskUserQuestion")) continue;
      const ids = [...text.matchAll(ID_ON_LINE_RE)].map((m) => m[1].replace(/\.+$/, ""));
      if (ids.length) marks.push({ file: rel, n, ids });
      else if (!text.includes("askuser-none")) unmarked.push({ file: rel, n });
    }
  }
  return { marks, unmarked };
}

const stripComments = (src) => src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");
const VALUE_RES = [
  [/^"([a-z0-9_]+)"\s*(?=[,}\n]|$)/, (m) => m[1]],
  [/^'([a-z0-9_]+)'\s*(?=[,}\n]|$)/, (m) => m[1]],
  [/^`([a-z0-9_]*)\$\{[^}`]*\}`\s*(?=[,}\n]|$)/, (m) => m[1].replace(/_+$/, "")],
];

// driverAskIds(root) -> {ids: Set, unparsed: [{file, text}]}.
function driverAskIds(root) {
  const ids = new Set();
  const unparsed = [];
  for (const file of walk(path.join(root, ...PHASES_REL.split("/"))).filter((f) => f.endsWith(".js")).sort()) {
    const rel = fwd(path.relative(root, file));
    const src = stripComments(fs.readFileSync(file, "utf8").replace(/\r/g, ""));
    const consts = new Map([...src.matchAll(/const\s+([A-Za-z_$][\w$]*)\s*=\s*["']([a-z0-9_]+)["']/g)].map((m) => [m[1], m[2]]));
    if (consts.has("ASK_ID")) ids.add(consts.get("ASK_ID"));
    for (const m of src.matchAll(/\baskId\s*:\s*/g)) {
      const rest = src.slice(m.index + m[0].length);
      let got = null;
      for (const [re, pick] of VALUE_RES) {
        const v = rest.match(re);
        if (v) { got = pick(v); break; }
      }
      const ident = got === null ? rest.match(/^([A-Za-z_$][\w$]*)\s*(?=[,}\n]|$)/) : null;
      if (ident && consts.has(ident[1])) got = consts.get(ident[1]);
      if (got) ids.add(got);
      else unparsed.push({ file: rel, text: rest.split("\n")[0].slice(0, 60) });
    }
  }
  return { ids, unparsed };
}

function stepNamesOf(root) {
  for (const base of [root, path.resolve(__dirname, "..", "..")]) {
    try { return require(path.join(base, ...STEP_TABLE_REL.split("/"))).stepNames(); } catch (_e) { /* next */ }
  }
  return [];
}

function readTable(root) {
  try { return levels.loadTable(path.join(root, ...TABLE_REL.split("/"))); } catch (e) { throw new TableUnreadable(e.message); }
}

// tableViolations(rows, stepNames) -> violations of the table's own rows.
function tableViolations(rows, stepNames) {
  const out = [];
  const seen = new Map();
  rows.forEach((r, i) => {
    const label = r && typeof r.id === "string" ? r.id : `row ${i}`;
    for (const p of levels.rowProblems(r, stepNames)) out.push({ code: "ASKUSER_ROW_INVALID", file: TABLE_REL, message: `${label}: ${p}` });
    if (r && typeof r.id === "string") seen.set(r.id, (seen.get(r.id) || 0) + 1);
  });
  for (const [id, c] of seen) if (c > 1) out.push({ code: "ASKUSER_ID_DUPLICATE", file: TABLE_REL, message: `${id}: ${c} rows` });
  if (!rows.some((r) => r && r.level === "low")) out.push({ code: "ASKUSER_NO_LOW", file: TABLE_REL, message: "no low row: nothing can be auto-answered" });
  return out;
}

const rowKey = (r) => JSON.stringify([r.level, Array.isArray(r.steps) ? r.steps : null, r.reason]);

// reviewsAgainst(root, base, rows) -> {reviews, notes}: rows added or changed since base.
function reviewsAgainst(root, base, rows) {
  const r = spawnSync("git", ["-C", root, "show", `${base}:${TABLE_REL}`], { encoding: "utf8", timeout: 30000 });
  let old = null;
  try { if (r.status === 0) old = JSON.parse(r.stdout).dialogs; } catch (_e) { old = null; }
  if (!Array.isArray(old)) return { reviews: [], notes: [`base ${base}: the classification table cannot be read there; REVIEW lines skipped`] };
  const before = new Map(old.filter((x) => x && typeof x.id === "string").map((x) => [x.id, rowKey(x)]));
  const reviews = rows.filter((x) => x && typeof x.id === "string" && before.get(x.id) !== rowKey(x))
    .map((x) => ({ id: x.id, level: String(x.level), steps: Array.isArray(x.steps) ? x.steps.join(",") : "-" }));
  return { reviews, notes: [] };
}

// check({root, base}) -> {violations, reviews, notes}; throws TableUnreadable.
function check({ root, base }) {
  const rows = readTable(root);
  const violations = tableViolations(rows, stepNamesOf(root));
  const tableIds = new Set(rows.filter((r) => r && typeof r.id === "string").map((r) => r.id));
  const { marks, unmarked } = scanSkills(root);
  for (const u of unmarked) {
    violations.push({ code: "ASKUSER_LINE_UNMARKED", file: u.file, line: u.n, message: "an AskUserQuestion line without a dialog ID or askuser-none" });
  }
  const driver = driverAskIds(root);
  for (const u of driver.unparsed) violations.push({ code: "ASKUSER_ASK_ID_UNPARSED", file: u.file, message: `askId value not read statically: ${u.text}` });
  const driverIds = [...driver.ids].sort().map((a) => `workflow-init.${a}`);
  for (const id of driverIds) if (!tableIds.has(id)) violations.push({ code: "ASKUSER_ASK_ID_UNCLASSIFIED", file: PHASES_REL, message: `${id} is not in ${TABLE_REL}` });
  const used = new Set();
  for (const m of marks) {
    for (const id of m.ids) {
      if (id === PLACEHOLDER) { driverIds.forEach((d) => used.add(d)); continue; }
      used.add(id);
      if (!tableIds.has(id)) violations.push({ code: "ASKUSER_ID_UNCLASSIFIED", file: m.file, line: m.n, message: `${id} is not in ${TABLE_REL}` });
    }
  }
  for (const id of [...tableIds].sort()) if (!used.has(id)) violations.push({ code: "ASKUSER_ID_ORPHAN", file: TABLE_REL, message: `${id} is used by no AskUserQuestion line` });
  const rv = base ? reviewsAgainst(root, base, rows) : { reviews: [], notes: [] };
  return { violations, reviews: rv.reviews, notes: rv.notes };
}

function formatText(result) {
  const out = result.violations.map((v) => `HIGH: ${v.file}${v.line ? `:${v.line}` : ""}: ${v.message} code=${v.code}`);
  for (const r of result.reviews) out.push(`REVIEW: ${r.id} level=${r.level} steps=${r.steps} — ${REVIEW_HINT}`);
  for (const n of result.notes) out.push(`NOTE: ${n}`);
  const n = result.violations.length;
  out.push(`## AskUserQuestion Dialog IDs: ${n ? `FAIL — ${n} violation(s)` : "PASS"}`);
  return out.join("\n") + "\n";
}

module.exports = { check, formatText, TableUnreadable, TABLE_REL, PLACEHOLDER };
