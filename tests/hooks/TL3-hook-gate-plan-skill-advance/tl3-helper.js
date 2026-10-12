"use strict";
// Helper for ../TL3-hook-gate-plan-skill-advance.sh.
//   seed <sid> <approved|unapproved>  -> writes the session state + intent plan (pinned dirs)
//   probe <skill> <marker> <file...>  -> key=value lines about the Skill tool_use in the turn
// `attempted` answers "did the model call Skill(<skill>)"; `result_error` and `marker` attribute
// a refusal to the skill gate rather than to a crash or a missing skill.
const fs = require("fs");
const path = require("path");

const [mode, ...args] = process.argv.slice(2);

if (mode === "seed") {
  const fx = require(path.join(__dirname, "..", "feature-2277-plan-approval-gate", "fixture.js"));
  const [sid, kind] = args;
  fx.writePlan(sid, "intent");
  const steps = { workflow_init: "complete", clarify_intent: "complete" };
  fx.writeState(sid, steps, kind === "approved" ? [{ step: "clarify_intent" }] : []);
  process.stdout.write("SEEDED\n");
  process.exit(0);
}

if (mode !== "probe") {
  console.error("BAD_MODE:" + String(mode));
  process.exit(2);
}

const [skill, marker, ...files] = args;
const records = [];
for (const f of files) {
  let text = "";
  try { text = fs.readFileSync(f, "utf8"); } catch (_) { continue; }
  try { records.push(JSON.parse(text)); continue; } catch (_) { /* JSONL below */ }
  for (const line of text.split("\n")) {
    try { if (line.trim()) records.push(JSON.parse(line)); } catch (_) { /* partial line */ }
  }
}
const uses = [];
const results = [];
const seen = new WeakSet();
const walk = (n) => {
  if (n === null || typeof n !== "object" || seen.has(n)) return;
  seen.add(n);
  if (n.type === "tool_use") uses.push(n);
  else if (n.type === "tool_result") results.push(n);
  for (const v of Array.isArray(n) ? n : Object.values(n)) walk(v);
};
records.forEach(walk);
const named = (u) => {
  const s = u && u.input && typeof u.input.skill === "string" ? u.input.skill : "";
  return s === skill || s.endsWith(":" + skill) || s.endsWith("/" + skill);
};
const attempts = uses.filter((u) => u.name === "Skill" && named(u));
const ids = new Set(attempts.map((a) => a.id));
const linked = results.filter((r) => ids.has(r.tool_use_id));
const textOf = (r) => (typeof r.content === "string" ? r.content
  : Array.isArray(r.content) ? r.content.map((b) => (b && typeof b.text === "string" ? b.text : "")).join("\n") : "");
const tri = (pred) => (linked.length === 0 ? "unknown" : String(linked.some(pred)));
console.log([
  "attempted=" + String(attempts.length > 0),
  "result_error=" + tri((r) => r.is_error === true),
  "marker=" + tri((r) => r.is_error === true && textOf(r).includes(marker)),
].join("\n"));
