"use strict";
// Readers shared by tests/hooks/feature-2676-hook-classification.js and
// feature-2676-hook-timeout-relation.js: the classification table of
// docs/architecture/claude-code/settings/hook-timeout.md (the SSOT of which PreToolUse hook is an
// allow-deny hook and which has a decision time limit) and the settings.json registrations.
// The table is found by its header, not by its position, so prose around it may change freely.
const fs = require("node:fs");
const path = require("node:path");

const REPO = path.resolve(__dirname, "..", "..", "..");
const DOC = path.join(REPO, "docs", "architecture", "claude-code", "settings", "hook-timeout.md");
const SETTINGS = path.join(REPO, "settings.json");

// Header cells, as \u escapes (no CJK in test source).
const chars = (...codes) => String.fromCharCode(...codes);
const COL_KIND = chars(0x5206, 0x985e); // classification
const COL_LIMIT = chars(0x4e0a, 0x9650, 0x6642, 0x9593); // decision time limit
const COL_REASON = chars(0x7406, 0x7531); // reason
const LIMIT_YES = chars(0x3042, 0x308a); // with a limit
const LIMIT_NO = chars(0x306a, 0x3057); // no limit
const EM_DASH = chars(0x2014);
const IDEOGRAPHIC_COMMA = chars(0x3001);
// A dash cell (em dash, hyphen or en dash) means "not applicable".
const DASH = new RegExp(`^(${EM_DASH}|-|${chars(0x2013)})?$`);

const cellsOf = (line) => line.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((cell) => cell.trim());
const isTableLine = (line) => /^\s*\|/.test(line);

// readClassification() -> { rows, error }. rows: { hooks, kind, limit, reason, raw }, where hooks
// are the hook names in the first cell (a cell may name several, e.g. a merged hook and members),
// kind is "allow-deny" | "non-allow-deny" | null, limit is "yes" | "no" | "none" | null.
function readClassification(docPath = DOC) {
  if (!fs.existsSync(docPath)) return { rows: [], error: `${path.relative(REPO, docPath)} does not exist` };
  const lines = fs.readFileSync(docPath, "utf8").split(/\r?\n/);
  const headerAt = lines.findIndex((line) => {
    if (!isTableLine(line)) return false;
    const header = cellsOf(line);
    return /^hook$/i.test(header[0].replace(/`/g, "")) && [COL_KIND, COL_LIMIT, COL_REASON].every((col) => header.some((cell) => cell.startsWith(col)));
  });
  if (headerAt < 0) return { rows: [], error: "no table with the columns hook / classification / limit / reason" };
  const header = cellsOf(lines[headerAt]);
  const at = (col) => header.findIndex((cell) => cell.startsWith(col));
  const rows = [];
  for (let index = headerAt + 2; index < lines.length && isTableLine(lines[index]); index += 1) {
    const cells = cellsOf(lines[index]);
    const kindCell = cells[at(COL_KIND)] || "";
    const limitCell = (cells[at(COL_LIMIT)] || "").replace(/[`*]/g, "");
    rows.push({
      hooks: (cells[0].match(/[a-z][a-z0-9]*(?:-[a-z0-9]+)+|[a-z]{3,}/g) || []).filter((name) => fs.existsSync(path.join(REPO, "hooks", `${name}.js`))),
      kind: /non-allow-deny hook/.test(kindCell) ? "non-allow-deny" : (/allow-deny hook/.test(kindCell) ? "allow-deny" : null),
      limit: limitCell.startsWith(LIMIT_YES) ? "yes" : (limitCell.startsWith(LIMIT_NO) ? "no" : (limitCell && DASH.test(limitCell) ? "none" : null)),
      reason: (cells[at(COL_REASON)] || "").trim(),
      raw: lines[index],
    });
  }
  return { rows, error: null };
}

// rowFor(rows, hookName) -> the row naming the hook, or undefined.
const rowFor = (rows, hookName) => rows.find((row) => row.hooks.includes(hookName));

// registrations() -> [{ matcher, command, timeout, hook }] for every PreToolUse registration;
// hook is the basename of the hooks/<name>.js the command runs.
function registrations() {
  const settings = JSON.parse(fs.readFileSync(SETTINGS, "utf8"));
  return settings.hooks.PreToolUse.flatMap((entry) => entry.hooks.map((hook) => {
    const found = String(hook.command).match(/hooks[\\/]([A-Za-z0-9_-]+)\.js/);
    return { matcher: entry.matcher, command: hook.command, timeout: hook.timeout, hook: found ? found[1] : null };
  }));
}

module.exports = { REPO, DOC, COL_KIND, COL_LIMIT, COL_REASON, LIMIT_YES, LIMIT_NO, EM_DASH, IDEOGRAPHIC_COMMA, DASH, readClassification, rowFor, registrations };
