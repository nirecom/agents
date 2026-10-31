"use strict";
// code-lang check (#2507): the CODE_LANG policy of hooks/lib/lint-commit-lang.js over the staged
// files, read from the snapshot (ACMR, as the module's own git listing). Unset CODE_LANG loads
// nothing; a missing or throwing module fails open.

const { out } = require("../output");
const { fromCfg } = require("../lib/support");

const ACMR = new Set(["A", "C", "M", "R"]);
const line = (prefix, v) => `${prefix}${v.file}:${v.lineNumber}: ${String(v.line).slice(0, 80)}`;

async function run({ context, snapshot, files }) {
  const env = context.env || process.env;
  if (!env.CODE_LANG) return { verdict: "pass", messages: [] };
  const messages = [];
  let r;
  try {
    const list = (files || []).filter((f) => ACMR.has(snapshot.status(f)));
    r = fromCfg(context.cfgDir, "hooks/lib/lint-commit-lang.js").check({ files: list, read: (f) => snapshot.content(f) });
  } catch (e) {
    return { verdict: "pass", messages: [out(`pre-commit: lint-commit-lang skipped (${e && e.message})`)] };
  }
  r = r || {};
  if (r.excluded) messages.push(out("lint-commit-lang: skipped (CODE_LANG_EXCLUDE match)"));
  if (Array.isArray(r.violations) && r.violations.length > 0) {
    for (const v of r.violations.slice(0, 10)) messages.push(out(line("  ", v)));
    messages.push(out(""), out("Commit blocked: CODE_LANG policy violation in staged files."),
      out("Fix the issues above, or add 'lang-check: ignore' anywhere in the file to bypass."));
    return { verdict: "block", messages };
  }
  if (Array.isArray(r.hints)) for (const h of r.hints.slice(0, 5)) messages.push(out(line("  hint: ", h)));
  return { verdict: "pass", messages };
}

module.exports = { run };
