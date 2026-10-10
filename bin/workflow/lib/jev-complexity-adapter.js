"use strict";
// bin/workflow/lib/jev-complexity-adapter.js — the complexity-judge knowledge the Jev
// broker needs: how to build the request, how Jev's probabilities become one SIGNALS:
// line (always re-parsed by the unmodified normalize-judge-signals), how to read the
// LLM's answer out of the Agent PostToolUse payload, and the step -> stage table.
// Jev's response is untrusted: only SIGNAL_IDS keys are read, extra keys are ignored.
// This module never writes a signals file.

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { StringDecoder } = require("string_decoder");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..", "..");
const { SIGNAL_IDS } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "workflow-state", "complexity-routing.js"));
const { redactSecretShaped } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "workflow-state", "complexity-routing", "secret-shape.js"));
const { redactSecrets } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "output-sanitize.js"));

const RUBRIC_PATH = path.join(SCRIPT_CHECKOUT_ROOT, "skills", "_shared", "judge-task-complexity.md");
const AGENT_PATH = path.join(SCRIPT_CHECKOUT_ROOT, "agents", "complexity-judge.md");
const MAX_STATE_CHARS = 16000;
const MAX_ARTIFACT_READ_BYTES = 1048576;
const ARTIFACTS = ["intent", "outline", "detail"];
const SID_RE = /^[A-Za-z0-9._-]{1,128}$/;
const MODEL_RE = /^[A-Za-z0-9._-]{1,64}$/;
const S0_LINE = "SIGNALS: S0-undecidable";

const STEP_TO_STAGE = Object.freeze({
  workflow_init: "cos1",
  clarify_intent: "cos1",
  outline: "outline",
  detail: "detail",
  write_tests: "write_tests",
  write_code: "write_code",
});

function stageForStep(step) {
  return typeof step === "string" && Object.prototype.hasOwnProperty.call(STEP_TO_STAGE, step)
    ? STEP_TO_STAGE[step] : "unknown";
}

function questionKey(id) {
  return id.toLowerCase().replace(/-/g, "_");
}

// The body of the rubric's "### <id>" section, read at runtime (never copied here).
function rubricSection(rubric, id) {
  const lines = rubric.split("\n");
  const start = lines.indexOf("### " + id);
  if (start < 0) return null;
  const body = [];
  for (const l of lines.slice(start + 1)) {
    if (l.startsWith("#")) break;
    if (l.trim()) body.push(l.trim());
  }
  return body.length ? body.join(" ") : null;
}

// Throws when a signal has no rubric section; the broker then treats the point as unmappable.
function buildQuestions() {
  const rubric = fs.readFileSync(RUBRIC_PATH, "utf8").replace(/\r\n/g, "\n");
  const questions = {};
  for (const id of SIGNAL_IDS) {
    const body = rubricSection(rubric, id);
    if (!body) throw new Error("rubric section missing for " + id);
    questions[questionKey(id)] = {
      type: "noul",
      instructions: `Judge whether the software task described in the state meets the complexity signal ${id}. ` +
        `Rubric: ${body}`,
      criteria: {
        true: `The task meets the ${id} rubric condition.`,
        false: `The task does not meet the ${id} rubric condition.`,
      },
    };
  }
  return questions;
}

// mapAnswers(response, threshold) -> {rawLine, probabilities, minConfidence, status}.
function mapAnswers(response, threshold) {
  const answers = response && typeof response === "object" && response.answers && typeof response.answers === "object"
    ? response.answers : {};
  const probabilities = {};
  let valid = true;
  for (const id of SIGNAL_IDS) {
    const key = questionKey(id);
    const a = Object.prototype.hasOwnProperty.call(answers, key) ? answers[key] : null;
    const p = a && typeof a === "object" ? a.noul : undefined;
    if (typeof p === "number" && Number.isFinite(p) && p >= 0 && p <= 1) {
      probabilities[id] = p;
    } else {
      probabilities[id] = null;
      valid = false;
    }
  }
  if (!valid) return { rawLine: S0_LINE, probabilities, minConfidence: null, status: "unmappable" };
  const minConfidence = Math.min(...SIGNAL_IDS.map((id) => Math.max(probabilities[id], 1 - probabilities[id])));
  if (minConfidence < threshold) return { rawLine: S0_LINE, probabilities, minConfidence, status: "low-confidence" };
  const selected = SIGNAL_IDS.filter((id) => probabilities[id] >= 0.5);
  const rawLine = selected.length ? "SIGNALS: " + selected.join(", ") : "SIGNALS: none";
  return { rawLine, probabilities, minConfidence, status: "ok" };
}

function plansDirOrNull() {
  try {
    const { getWorkflowPlansDir } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "workflow-plans-dir.js"));
    return getWorkflowPlansDir();
  } catch (_e) {
    return null;
  }
}

// At most maxBytes of the file, decoded as UTF-8; when truncated, StringDecoder.write (no
// end()) drops only an incomplete trailing sequence, so a genuine U+FFFD at the cap survives.
function readCapped(file, maxBytes) {
  const fd = fs.openSync(file, "r");
  try {
    const size = fs.fstatSync(fd).size;
    const cap = Math.min(size, maxBytes);
    const buf = Buffer.alloc(cap);
    let n = 0;
    while (n < cap) {
      const got = fs.readSync(fd, buf, n, cap - n, null);
      if (got === 0) break;
      n += got;
    }
    return size > maxBytes
      ? new StringDecoder("utf8").write(buf.subarray(0, n))
      : buf.toString("utf8", 0, n);
  } finally {
    fs.closeSync(fd);
  }
}

// The read cap bounds memory and time far above MAX_STATE_CHARS; the header's line count
// is then over the read portion only.
function readArtifactsFor(dir, id) {
  if (typeof id !== "string" || !SID_RE.test(id) || id.includes("..")) return [];
  const out = [];
  for (const name of ARTIFACTS) {
    try {
      const text = readCapped(path.join(dir, `${id}-${name}.md`), MAX_ARTIFACT_READ_BYTES);
      out.push({ name, text: text.replace(/\r\n/g, "\n") });
    } catch (_e) { /* absent artifact */ }
  }
  return out;
}

// Comparable form of a path: /c/... normalized, resolved, no trailing separator, "/"
// separators, lower-cased on win32 only. Null for a non-string or empty value.
function pathKey(p, toWindowsPath) {
  if (typeof p !== "string" || !p) return null;
  const w = toWindowsPath(p);
  if (typeof w !== "string" || !w) return null;
  let k = path.resolve(w).replace(/\\/g, "/");
  while (k.length > 1 && k.endsWith("/") && !/^[A-Za-z]:\/$/.test(k)) k = k.slice(0, -1);
  return process.platform === "win32" ? k.toLowerCase() : k;
}

// The workflow session id can differ from the hook's: <cwd>/WORKTREE_NOTES.md alone is read
// (no sibling scan, no git, no process.cwd()), and only for an absolute cwd. The notes id is
// adopted only when its state's session_worktree, or the latest worktree-entered event's own
// cwd (not a fallback-process-cwd guess), path-equals the hook cwd: every main-checkout
// session shares the start cwd, so a start-context or process cwd never binds and a stale
// notes file lends no plan or step (#2460 C12).
function notesSessionId(rawCwd) {
  try {
    if (typeof rawCwd !== "string" || !rawCwd) return null;
    const { toWindowsPath } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "branch-diff.js"));
    const cwd = toWindowsPath(rawCwd);
    if (typeof cwd !== "string" || !cwd || !path.isAbsolute(cwd)) return null;
    const notes = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "worktree-notes-session-ids.js"));
    const wsid = notes.readSessionIdFromWorktreeNotes(path.join(cwd, notes.NOTES_BASENAME));
    if (!wsid) return null;
    const { readState } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "workflow-state", "state-io.js"));
    const state = readState(wsid);
    if (!state || typeof state !== "object") return null;
    const want = pathKey(cwd, toWindowsPath);
    const same = (p) => { const k = pathKey(p, toWindowsPath); return k !== null && k === want; };
    if (same(state.session_worktree)) return wsid;
    const events = Array.isArray(state.events) ? state.events : [];
    let entered = null;
    for (const e of events) {
      if (e && e.kind === "worktree" && e.transition === "entered") entered = e;
    }
    const bound = entered !== null && typeof entered.cwd === "string"
      && entered.path_source !== "fallback-process-cwd" && same(entered.cwd);
    return bound ? wsid : null;
  } catch (_e) {
    return null;
  }
}

// The bound WORKTREE_NOTES Session-ID's artifacts when it has any (the workflow session the
// LLM judge reads), else the hook session id's, so Jev sees the plan the LLM judge sees.
function readArtifacts(sessionId, cwd) {
  const dir = plansDirOrNull();
  if (!dir) return [];
  const notes = readArtifactsFor(dir, notesSessionId(cwd));
  return notes.length ? notes : readArtifactsFor(dir, sessionId);
}

function lineCount(text) {
  return text ? text.replace(/\n$/, "").split("\n").length : 0;
}

// At most n UTF-16 units, never ending on a lone high surrogate: bytes/sha256 must describe
// the exact string sent, and Buffer would re-encode a lone surrogate as U+FFFD.
function sliceUnits(s, n) {
  const end = Math.max(0, n);
  if (end > 0 && end < s.length) {
    const c = s.charCodeAt(end - 1);
    if (c >= 0xd800 && c <= 0xdbff) return s.slice(0, end - 1);
  }
  return s.slice(0, end);
}

// Every text that leaves the machine: provider key shapes, then the wider credential set
// (github_pat_, URL userinfo, Authorization schemes, token=/password: assignments, any PEM kind).
function redactOutbound(text) {
  return redactSecrets(redactSecretShaped(text));
}

// State = header, the dispatch prompt, then intent/outline/detail, each redacted by
// redactOutbound before the 16000-char cap: the prompt is kept and later artifacts are trimmed first.
function buildRequest({ toolInput, sessionId, stage, cwd } = {}) {
  const prompt = redactOutbound(toolInput && typeof toolInput.prompt === "string" ? toolInput.prompt : "");
  const rawArts = readArtifacts(sessionId, cwd);
  const has = (n) => rawArts.some((a) => a.name === n);
  const planLines = rawArts.filter((a) => a.name !== "detail").reduce((n, a) => n + lineCount(a.text), 0);
  const arts = rawArts.map((a) => ({ name: a.name, text: redactOutbound(a.text) }));
  const header = [
    `stage: ${stage || "unknown"}`,
    `intent+outline lines: ${planLines}`,
    `artifacts: ${ARTIFACTS.map((n) => `${n}=${has(n) ? "present" : "absent"}`).join(" ")}`,
    "",
  ].join("\n");
  let state = `${header}\n## dispatch prompt\n${prompt}\n`;
  let truncated = false;
  if (state.length > MAX_STATE_CHARS) {
    state = sliceUnits(state, MAX_STATE_CHARS);
    truncated = true;
  }
  const sources = [];
  for (const a of arts) {
    if (truncated) break;
    const section = `\n## ${a.name}.md\n${a.text}`;
    const room = MAX_STATE_CHARS - state.length;
    if (section.length <= room) {
      state += section;
    } else {
      state += sliceUnits(section, room);
      truncated = true;
    }
    if (room > 0) sources.push(a.name);
  }
  return {
    state,
    input: {
      bytes: Buffer.byteLength(state),
      sha256: crypto.createHash("sha256").update(state).digest("hex"),
      truncated,
      sources,
    },
  };
}

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
// The payload is trimmed after the prefix as the parser does, so "SIGNALS:S0-undecidable" is S0.
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

module.exports = {
  STEP_TO_STAGE,
  MAX_STATE_CHARS,
  MAX_ARTIFACT_READ_BYTES,
  stageForStep,
  notesSessionId,
  questionKey,
  buildQuestions,
  mapAnswers,
  buildRequest,
  extractLlmText,
  classifyLlm,
  resolveExecutorModel,
};
