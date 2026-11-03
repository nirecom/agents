"use strict";
// Shared assertions on the output of hooks/workflow-mark.js (#2824): the normal channel (INFO only),
// the strong channel (any UNAPPLIED message) and the silent `{}`. The strong channel's form comes
// from hooks/workflow-mark/emit.js STRONG_CHANNEL ("exit2" or "block-decision"), never from a guess.
// Each *Failure(result, pattern) returns null when the output has the expected form, else a reason;
// a missing emit.js is reported as "not implemented: ...". CLI for shell tests:
//   node workflow-mark-output.js strong-channel
//   node workflow-mark-output.js check <unapplied|info|silent> <ERE> <rc> <stdoutFile> <stderrFile>

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const ROOT = path.resolve(__dirname, "..", "..");
const EMIT_PATH = path.join(ROOT, "hooks", "workflow-mark", "emit.js");
const MARK_HOOK = path.join(ROOT, "hooks", "workflow-mark.js");
const PREFIX = "[NOT APPLIED]";

function loadEmit() {
  try {
    return require(EMIT_PATH);
  } catch (e) {
    throw new Error(`not implemented: hooks/workflow-mark/emit.js does not load (${String(e.message).split("\n")[0]})`);
  }
}

function strongChannel() {
  const c = loadEmit().STRONG_CHANNEL;
  if (c !== "exit2" && c !== "block-decision") {
    throw new Error(`not implemented: emit.STRONG_CHANNEL is ${JSON.stringify(c)}, expected "exit2" or "block-decision"`);
  }
  return c;
}

// parseStdout(text) -> the object on the last non-empty stdout line, or null.
function parseStdout(text) {
  const lines = String(text || "").split(/\r?\n/).filter((l) => l.trim() !== "");
  if (lines.length === 0) return null;
  try {
    const v = JSON.parse(lines[lines.length - 1]);
    return v && typeof v === "object" ? v : null;
  } catch (_) {
    return null;
  }
}

// additionalContextOf(out) -> hookSpecificOutput.additionalContext (S2) or the top-level one (S1).
function additionalContextOf(out) {
  if (!out) return "";
  const hso = out.hookSpecificOutput;
  if (hso && typeof hso.additionalContext === "string") return hso.additionalContext;
  return typeof out.additionalContext === "string" ? out.additionalContext : "";
}

const toRe = (p) => (p instanceof RegExp ? p : new RegExp(p, "i"));
const show = (r) => `rc=${r.code} stdout=${JSON.stringify(String(r.stdout || "").slice(0, 600))} ` +
  `stderr=${JSON.stringify(String(r.stderr || "").slice(0, 600))}`;

function unappliedFailure(r, pattern) {
  const ch = strongChannel();
  const re = toRe(pattern);
  if (ch === "exit2") {
    const err = String(r.stderr || "");
    if (r.code !== 2) return `strong channel exit2: expected exit 2; ${show(r)}`;
    if (!err.includes(PREFIX)) return `strong channel exit2: stderr lacks ${PREFIX}; ${show(r)}`;
    if (!re.test(err)) return `strong channel exit2: stderr lacks /${re.source}/; ${show(r)}`;
    return null;
  }
  const out = parseStdout(r.stdout);
  if (r.code !== 0) return `strong channel block-decision: expected exit 0; ${show(r)}`;
  if (!out || out.decision !== "block" || typeof out.reason !== "string") {
    return `strong channel block-decision: stdout is not {decision:"block", reason}; ${show(r)}`;
  }
  if (!out.reason.includes(PREFIX)) return `strong channel block-decision: reason lacks ${PREFIX}; ${show(r)}`;
  if (!re.test(out.reason)) return `strong channel block-decision: reason lacks /${re.source}/; ${show(r)}`;
  return null;
}

function infoFailure(r, pattern) {
  loadEmit();
  const re = toRe(pattern);
  const out = parseStdout(r.stdout);
  if (r.code !== 0) return `normal channel: expected exit 0; ${show(r)}`;
  if (!out) return `normal channel: stdout is not JSON; ${show(r)}`;
  if (out.decision !== undefined) return `normal channel: unexpected decision field; ${show(r)}`;
  if (typeof out.systemMessage !== "string" || out.systemMessage === "") return `normal channel: no systemMessage; ${show(r)}`;
  if (out.hookSpecificOutput && out.hookSpecificOutput.hookEventName !== "PostToolUse") {
    return `normal channel: hookSpecificOutput.hookEventName is not PostToolUse; ${show(r)}`;
  }
  const ac = additionalContextOf(out);
  if (!re.test(ac)) return `normal channel: additionalContext lacks /${re.source}/; ${show(r)}`;
  if ((ac + out.systemMessage + String(r.stderr || "")).includes(PREFIX)) return `normal channel: INFO carries ${PREFIX}; ${show(r)}`;
  return null;
}

function silentFailure(r) {
  const out = parseStdout(r.stdout);
  if (r.code !== 0) return `silent: expected exit 0; ${show(r)}`;
  if (!out || Object.keys(out).length !== 0) return `silent: expected stdout {}; ${show(r)}`;
  return null;
}

// runMark(payload, {env, cwd}) -> {code, stdout, stderr} of one real hooks/workflow-mark.js run.
function runMark(payload, opts = {}) {
  const env = Object.assign({}, process.env, opts.env || {});
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, [MARK_HOOK], {
    input: JSON.stringify(payload), encoding: "utf8", timeout: 60000, env, cwd: opts.cwd || process.cwd(),
  });
  if (r.error) throw new Error(`workflow-mark.js did not run: ${r.error.message}`);
  return { code: r.status, stdout: r.stdout || "", stderr: r.stderr || "" };
}

// bashPayload(command, {sid, cwd, exitCode, agentId, toolUseId}) -> a PostToolUse Bash payload.
function bashPayload(command, o = {}) {
  const p = { tool_name: "Bash", tool_input: { command }, tool_response: { exit_code: o.exitCode || 0, stdout: "" } };
  if (o.cwd) p.tool_input.cwd = o.cwd;
  if (o.sid) p.session_id = o.sid;
  if (o.agentId) p.agent_id = o.agentId;
  if (o.toolUseId) p.tool_use_id = o.toolUseId;
  return p;
}

module.exports = {
  EMIT_PATH, MARK_HOOK, PREFIX, loadEmit, strongChannel, parseStdout, additionalContextOf,
  unappliedFailure, infoFailure, silentFailure, runMark, bashPayload,
};

if (require.main === module) {
  const [mode, kind, pattern, rc, outFile, errFile] = process.argv.slice(2);
  // Helper that run-all may execute directly with no args: print usage and pass.
  if (mode === undefined) {
    process.stdout.write("usage: workflow-mark-output.js strong-channel | check <kind> <pattern> <rc> <outFile> <errFile>\n");
    process.exit(0);
  }
  try {
    if (mode === "strong-channel") {
      process.stdout.write(strongChannel() + "\n");
      process.exit(0);
    }
    const r = { code: Number(rc), stdout: fs.readFileSync(outFile, "utf8"), stderr: fs.readFileSync(errFile, "utf8") };
    const why = kind === "unapplied" ? unappliedFailure(r, pattern)
      : kind === "info" ? infoFailure(r, pattern) : silentFailure(r);
    if (why) { process.stdout.write(why + "\n"); process.exit(1); }
    process.exit(0);
  } catch (e) {
    process.stdout.write(String(e.message) + "\n");
    process.exit(1);
  }
}
