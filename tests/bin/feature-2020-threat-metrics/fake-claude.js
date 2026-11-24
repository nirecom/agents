"use strict";
// Stub of `claude -p --output-format json` for tests/bin/feature-2020-threat-metrics.js (#2020).
// The answer is keyed by the `kw-<A>-<B>-<category>` token each fixture finding carries: one
// {axisA, axisB, category} object per token, in prompt order, as the JSON array in `result`.
// Each call is logged to CLAUDE_STUB_LOG (args, prompt, and whether CLAUDECODE reached the child).
const fs = require("node:fs");

let stdin = "";
try {
  stdin = fs.readFileSync(0, "utf8");
} catch {
  stdin = "";
}
const args = process.argv.slice(2);
const prompt = [stdin].concat(args.filter((a) => !a.startsWith("-"))).join("\n");
const rows = [];
for (const m of prompt.matchAll(/kw-(A\d)-(B\d)-([a-z]+)/g)) rows.push({ axisA: m[1], axisB: m[2], category: m[3] });
if (process.env.CLAUDE_STUB_LOG) {
  const entry = { args, prompt, rows: rows.length, claudecode: process.env.CLAUDECODE !== undefined };
  fs.appendFileSync(process.env.CLAUDE_STUB_LOG, `${JSON.stringify(entry)}\n`);
}
process.stdout.write(JSON.stringify({ type: "result", subtype: "success", is_error: false, result: JSON.stringify(rows) }));
