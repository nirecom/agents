"use strict";
// bin/workflow/lib/jev-skip-adapter/answer.js — the plan-skip-judge side: its answer file read
// strictly (one SKIP_CONDITIONS: line, known keys, literal true/false), the one fill rule that
// turns every key without a value into false (run the stage), and the executor model.

const fs = require("fs");
const path = require("path");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..", "..", "..");
const { CONDITION_SCHEMAS } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "workflow-state", "skip-signal-resolver", "condition-schemas.js"));
const { LINE_PREFIX } = require("./questions.js");

const AGENT_PATH = path.join(SCRIPT_CHECKOUT_ROOT, "agents", "plan-skip-judge.md");
const EXECUTOR = "plan-skip-judge";
const MODEL_RE = /^[A-Za-z0-9._-]{1,64}$/;
const NO_ANSWER = "NO_ANSWER";
const ADOPTED_TO_SOURCE = Object.freeze({ jev: "jev", llm: "subagent", mixed: "mixed" });

// Every CONDITION_SCHEMAS[target] key; a key without a literal true is false.
function fillConditions(target, values) {
  const v = values && typeof values === "object" ? values : {};
  const out = {};
  for (const k of CONDITION_SCHEMAS[target] || []) out[k] = v[k] === true;
  return out;
}

const stripBlank = (s) => s.replace(/^[ \t]+|[ \t]+$/g, "");

// parseSubagent(raw|null, target) -> {status: ok|parse-fallback|missing, values, answered}.
// values holds every key (false unless answered true); answered only the keys with a literal
// true/false. Anything but exactly one nonblank line, a SKIP_CONDITIONS: line, or an empty
// token, an unknown or a repeated key rejects the whole answer; a non-literal value rejects
// that key alone.
function parseSubagent(raw, target) {
  const reject = (status) => ({ status, values: fillConditions(target, {}), answered: {} });
  if (raw === null || raw === undefined) return reject("parse-fallback");
  const text = String(raw);
  if (text.trim() === "" || text.trim() === NO_ANSWER) return reject("missing");
  const lines = text.split("\n").map((l) => l.replace(/\r$/, "")).filter((l) => l.trim() !== "");
  if (lines.length !== 1 || !lines[0].trim().startsWith(LINE_PREFIX)) return reject("parse-fallback");
  const schema = CONDITION_SCHEMAS[target] || [];
  const answered = {};
  const seen = new Set();
  let partial = false;
  for (const tok of lines[0].trim().slice(LINE_PREFIX.length).split(",")) {
    const t = stripBlank(tok);
    if (t === "") return reject("parse-fallback");
    const eq = t.indexOf("=");
    const key = stripBlank(eq < 0 ? t : t.slice(0, eq));
    if (!schema.includes(key) || seen.has(key)) return reject("parse-fallback");
    seen.add(key);
    const val = eq < 0 ? null : stripBlank(t.slice(eq + 1));
    if (val === "true" || val === "false") answered[key] = val === "true";
    else partial = true;
  }
  if (schema.some((k) => !Object.prototype.hasOwnProperty.call(answered, k))) partial = true;
  return { status: partial ? "parse-fallback" : "ok", values: fillConditions(target, answered), answered };
}

function frontmatterModel() {
  try {
    const text = fs.readFileSync(AGENT_PATH, "utf8").replace(/\r\n/g, "\n");
    const m = /^---\n([\s\S]*?)\n---/.exec(text);
    const line = m && /^model:[ \t]*(\S+)[ \t]*$/m.exec(m[1]);
    return line && MODEL_RE.test(line[1]) ? line[1] : "unknown";
  } catch (_e) {
    return "unknown";
  }
}

// tool_input.model when it is a sane model name, else the agent frontmatter model.
function resolveExecutorModel(toolInput) {
  const m = toolInput && toolInput.model;
  return typeof m === "string" && MODEL_RE.test(m) ? m : frontmatterModel();
}

module.exports = {
  EXECUTOR, ADOPTED_TO_SOURCE, fillConditions, parseSubagent, frontmatterModel, resolveExecutorModel,
};
