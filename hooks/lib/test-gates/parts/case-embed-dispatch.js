"use strict";
// The shared body of the analyzer-backed caseEmbedRules parts (#2507 D7; ports cec_dispatch of
// bin/lib/test-language-parts/case-embed-common.sh). The pester cache of the bash part gives the
// same answers as a launch per op, so it has no counterpart here.

const OPS = new Set(["deps", "leftover-defs", "self-impl", "skip-reason", "syntax-check", "case-count"]);
const ORDER_MISMATCH = "case-embed: order mismatch (the analyzer and the test case reader disagree on the cases)\n";

const outLines = (out) => String(out).replace(/\n+$/, "").split("\n").map((l) => l.replace(/\r$/, "")).filter(Boolean);
const printed = (lines) => lines.map((l) => `${l}\n`).join("");

// orderFilter(out, cases) — cec_order_filter: leading ORDER rows match the cases, the rest printed.
function orderFilter(out, cases) {
  let n = 0;
  const rest = [];
  for (const line of outLines(out)) {
    if (line.startsWith("ORDER\t")) {
      const col = line.replace(/^\t+|\t+$/g, "").split(/\t+/);
      const c = cases[n];
      if (col[1] !== String(n) || !c || (col[2] || "") !== String(c.begin) || (col[3] || "") !== String(c.end)) {
        n = -1;
        break;
      }
      n += 1;
    } else rest.push(line);
  }
  if (n !== cases.length) return { rc: 1, stdout: "", stderr: ORDER_MISMATCH };
  return { rc: 0, stdout: printed(rest), stderr: "" };
}

// dispatch(ctx, op, file) — ctx: { id, call(op, file, helper), runtimeMissing(), readCases(file),
// cases, helper }. rc 0 answered, 1 the analyzer / order / syntax failed, 2 bad op, 69 no runtime.
function dispatch(ctx, op, file) {
  if (op === "rules-doc") return { rc: 0, stdout: `skills/sweep-tests/embed-rules/${ctx.id}.md\n`, stderr: "" };
  if (!OPS.has(op)) return { rc: 2, stdout: "", stderr: `[${ctx.id}-case-embed] unknown op: ${op || ""}\n` };
  if (!file) return { rc: 2, stdout: "", stderr: `[${ctx.id}-case-embed] ${op}: file required\n` };
  if (ctx.runtimeMissing()) return { rc: 69, stdout: "", stderr: "" };
  if (op === "syntax-check") {
    const r = ctx.call(op, file);
    return { rc: r.rc === 0 ? 0 : 1, stdout: "", stderr: r.stderr || "" };
  }
  let cases = ctx.cases || [];
  if (op === "deps" && cases.length === 0) {
    const rd = ctx.readCases(file);
    if (rd.rc !== 0) return { rc: 1, stdout: "", stderr: "" };
    cases = rd.g.cases;
  }
  const r = ctx.call(op, file, op === "self-impl" ? ctx.helper : undefined);
  if (r.rc !== 0) return { rc: 1, stdout: "", stderr: r.stderr || "" };
  if (op === "deps") return orderFilter(r.stdout, cases);
  return { rc: 0, stdout: printed(outLines(r.stdout)), stderr: r.stderr || "" };
}

module.exports = { dispatch, orderFilter, OPS };
