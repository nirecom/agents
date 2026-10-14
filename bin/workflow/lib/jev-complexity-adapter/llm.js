"use strict";
// bin/workflow/lib/jev-complexity-adapter/llm.js — reading the LLM judge's side: its text
// out of an Agent PostToolUse payload, the line the unmodified parser consumes, the LLM-side
// status, the executor model, and the removal of deterministic tokens from its answer.

const fs = require("fs");
const path = require("path");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..", "..", "..");
const { DETERMINISTIC_SIGNAL_IDS } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "workflow-state", "complexity-routing.js"));

const AGENT_PATH = path.join(SCRIPT_CHECKOUT_ROOT, "agents", "complexity-judge.md");
const MODEL_RE = /^[A-Za-z0-9._-]{1,64}$/;

// The LLM's text from an Agent PostToolUse payload: tool_response (string, or the text
// blocks of content[]), then payload.tool_output, then payload.tool_output_text.
function extractLlmText(toolResponse, payload) {
  const p = payload && typeof payload === "object" ? payload : {};
  const resp = toolResponse !== undefined ? toolResponse : p.tool_response;
  if (typeof resp === "string" && resp.length) return resp;
  if (resp && typeof resp === "object") {
    const content = resp.content;
    if (typeof content === "string" && content.length) return content;
    if (Array.isArray(content)) {
      const text = content
        .filter((b) => b && b.type === "text" && typeof b.text === "string")
        .map((b) => b.text)
        .join("\n");
      if (text.length) return text;
    }
  }
  for (const k of ["tool_output", "tool_output_text"]) {
    if (typeof p[k] === "string" && p[k].length) return p[k];
  }
  return null;
}

// The line normalize-judge-signals normalize() consumes (it exports only the normalized CSV,
// so its selection rule is mirrored here): the single trimmed "SIGNALS:" line with no
// non-blank line after it; preamble before it is allowed. null when the parser would fall back.
function parserSelectedLine(raw) {
  let selected = null;
  let count = 0;
  for (const line of String(raw).split(/\r?\n/)) {
    const t = line.trim();
    if (t === "") continue;
    if (t.startsWith("SIGNALS:")) {
      selected = t;
      count++;
    } else if (count) {
      return null;
    }
  }
  return count === 1 ? selected : null;
}

// LLM-side status: missing (no text), parse-fallback (the parser fell back to S0 and the
// line it consumed does not carry the S0 payload), or ok. S0 after reasoning text is a
// genuine S0; S0 followed by another SIGNALS line or trailing prose is a fallback.
function classifyLlm(raw, parsed) {
  if (raw === null || raw === undefined) return "missing";
  if (parsed !== "S0-undecidable") return "ok";
  const t = parserSelectedLine(raw);
  return t !== null && t.slice("SIGNALS:".length).trim() === "S0-undecidable" ? "ok" : "parse-fallback";
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

// stripDeterministicTokens("SIGNALS: ...") -> {line, override}: the deterministic ids the LLM
// named are removed (they are computed, never judged) and returned as override; nothing left
// is "SIGNALS: none". Other tokens — an empty one included — pass through untouched for the
// strict parser to judge: a malformed list is never repaired into a well-formed one.
function stripDeterministicTokens(selectedLine) {
  const payload = String(selectedLine).slice("SIGNALS:".length);
  const tokens = payload.split(",").map((t) => t.trim());
  const override = tokens.filter((t) => DETERMINISTIC_SIGNAL_IDS.includes(t));
  const kept = tokens.filter((t) => !DETERMINISTIC_SIGNAL_IDS.includes(t));
  return { line: kept.length ? "SIGNALS: " + kept.join(", ") : "SIGNALS: none", override };
}

const NORMALIZER = path.join(SCRIPT_CHECKOUT_ROOT, "bin", "workflow", "normalize-judge-signals");
const NO_ANSWER = "NO_ANSWER";

// parseSubagent(raw|null) -> {status, csv, override}: the subagent's answer file as the CLI
// reads it. null raw (unreadable or over the cap) is a parse-fallback; NO_ANSWER is missing.
// Deterministic tokens are stripped first, so naming one never discards the whole answer.
function parseSubagent(raw) {
  if (raw === null || raw === undefined) return { status: "parse-fallback", csv: "S0-undecidable", override: [] };
  const text = String(raw);
  if (text.trim() === "" || text.trim() === NO_ANSWER) return { status: "missing", csv: null, override: [] };
  const line = parserSelectedLine(text);
  if (line === null) return { status: "parse-fallback", csv: "S0-undecidable", override: [] };
  const stripped = stripDeterministicTokens(line);
  let csv;
  try {
    csv = require(NORMALIZER).normalize(stripped.line);
  } catch (_e) {
    csv = null;
  }
  if (typeof csv !== "string") return { status: "parse-fallback", csv: "S0-undecidable", override: stripped.override };
  return { status: classifyLlm(stripped.line, csv), csv, override: stripped.override };
}

module.exports = {
  extractLlmText, parserSelectedLine, classifyLlm, frontmatterModel, resolveExecutorModel,
  stripDeterministicTokens, parseSubagent,
};
