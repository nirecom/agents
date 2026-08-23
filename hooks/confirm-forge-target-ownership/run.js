// stdin/stdout driver for the forge-target-ownership guard: reads the PreToolUse
// payload, walks every command line through evaluate.js, persists the session's
// gh env / auth record, and writes the single decision.
// Entrypoint-private to confirm-forge-target-ownership.js.
"use strict";

const fs = require("fs");
const { isCommandTool, commandListOf } = require("../lib/tool-command-text");
const { parse } = require("../lib/command-ir");
const segmentUtils = require("../lib/bash-write-patterns/segment-utils");
const { commandBasename, ASSIGN_RE } = segmentUtils;
const { reasonText, REASON_CODES } = require("./reasons");
const { createBudget } = require("./budget");
const { normalizeToLines } = require("./nested-commands");
const { loadSessionGhEnv, saveSessionGhEnv, removeState } = require("./gh-env-state");
const { loadDirty, saveDirty } = require("./auth-context");
const { evaluateLine, addCode, addTarget, GITHUB, ENV_BLOCKING_ASSIGN_RE } = require("./evaluate");
const { DYNAMIC_TEXT_RE } = require("./segment-shape");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    for (;;) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      // Buffer.from COPIES: buf is reused by the next read, and a view onto it
      // would be overwritten, silently truncating any payload past 4096 bytes.
      chunks.push(Buffer.from(buf.subarray(0, n)));
    }
  } catch (_e) {
    // EOF or no stdin attached
  }
  return Buffer.concat(chunks).toString("utf8");
}

// DECIDED unwinds to the single exit point instead of calling process.exit, so
// the decision is written exactly once and the process still ends normally. An
// early process.exit would also silence anything appended after this module's
// own code, which is how the mutation harness proves it can observe the hook.
const DECIDED = { decided: true };
let answered = false;

function answer(json) {
  if (!answered) {
    answered = true;
    process.stdout.write(json);
  }
  throw DECIDED;
}

function passThrough() {
  answer("{}");
}

function emit(state) {
  const parts = [];
  for (const code of REASON_CODES) {
    if (state.codes.indexOf(code) !== -1) parts.push(reasonText(code));
  }
  for (const ask of state.targets) parts.push(ask);
  if (parts.length === 0) passThrough();
  const reason = "Confirm the forge target before this write: " + parts.join("; ") + ".";
  answer(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: reason,
    },
  }));
}

// The working directory only tells the truth about the target when this command
// line does nothing that could move it or redirect gh elsewhere. Anything dynamic
// — a `cd`, a second command, a substitution, a GH_*/proxy assignment — and the
// implicit target stops being knowable from `tool_input.cwd`.
function cwdIsAuthoritative(input, commands, lines) {
  if (!Array.isArray(commands) || commands.length !== 1) return false;
  if (!Array.isArray(lines) || lines.length !== 1) return false;
  const cwd = input.tool_input && input.tool_input.cwd;
  if (typeof cwd !== "string" || cwd === "") return false;
  const line = lines[0];
  if (DYNAMIC_TEXT_RE.test(line)) return false;
  let ir = null;
  try { ir = parse(line); } catch (_e) { ir = null; }
  if (!ir || ir.parseFailure || ir.kind !== "simple") return false;
  if (!Array.isArray(ir.segments) || ir.segments.length !== 1) return false;
  if (Array.isArray(ir.separators) && ir.separators.length > 0) return false;
  const seg = ir.segments[0];
  let head = seg.cmd0;
  const argv = Array.isArray(seg.argv) ? seg.argv : [];
  let i = 0;
  while (typeof head === "string" && ASSIGN_RE.test(head)) {
    const eq = head.indexOf("=");
    if (ENV_BLOCKING_ASSIGN_RE.test(head.slice(0, eq))) return false;
    if (i >= argv.length) return false;
    head = argv[i];
    i += 1;
  }
  return commandBasename(head) === "gh";
}

// Clearing the login/proof cache is itself a persistence operation, so its
// result is read for the same reason the write's was: removeState answers
// whether the record is GONE, and a file that survived the unlink is a proof the
// NEXT invocation would still believe — for exactly the identity or target this
// invocation has just discovered it cannot record. Reported here, not merely to
// stderr, because only an ask stops the following write from inheriting it.
function clearLoginProof(state, sid) {
  if (removeState(sid, "gh-login")) return;
  addTarget(state, "the guard could not clear the cached login proof, so the next command could still be resolved against an identity the guard can no longer vouch for");
}

function main() {
  const raw = readStdin();
  if (!raw || !raw.trim()) passThrough();
  let input = null;
  try { input = JSON.parse(raw); } catch (_e) { passThrough(); }
  if (!input || typeof input !== "object") passThrough();
  if (!isCommandTool(input.tool_name)) passThrough();
  const commands = commandListOf(input.tool_name, input.tool_input);
  if (commands.length === 0) passThrough();
  const sid = typeof input.session_id === "string" ? input.session_id : null;
  const state = {
    codes: [],
    targets: [],
    budget: createBudget(),
    ctx: { sid, host: GITHUB },
    cwd: input.tool_input && typeof input.tool_input.cwd === "string" ? input.tool_input.cwd : null,
    sessionEnv: loadSessionGhEnv(sid),
    invocationEnv: {},
    segmentEnv: {},
    envReleased: {},
    dirty: loadDirty(sid),
    authMutated: false,
    cwdAllowed: false,
  };
  state.authMutated = state.dirty.length > 0;
  const normalized = commands.map((c) => normalizeToLines(c));
  const allLines = [];
  for (const norm of normalized) {
    if (!norm.ok && norm.reason) addCode(state, norm.reason);
    for (const line of norm.lines) allLines.push(line);
  }
  state.cwdAllowed = cwdIsAuthoritative(input, commands, allLines);
  for (const line of allLines) evaluateLine(state, line, 0, true);
  if (saveDirty(sid, state.dirty).failed) {
    addTarget(state, "the guard could not record this command line's auth change, so the identity the next command acts as cannot be trusted for this write");
    // Asking THIS time is only half the answer: the login/proof cache predates
    // the state change that went unrecorded, so leaving it on disk hands the
    // NEXT invocation a proof for an identity the guard can no longer vouch for.
    clearLoginProof(state, sid);
  }
  const released = Object.keys(state.envReleased);
  if (Object.keys(state.invocationEnv).length > 0 || released.length > 0) {
    const merged = Object.assign({}, state.sessionEnv, state.invocationEnv);
    for (const name of released) {
      if (!state.invocationEnv[name]) delete merged[name];
    }
    // A persist that was ATTEMPTED and failed cannot be shrugged off here: the
    // decision below is allowed to be cheap only because the target it resolved
    // is remembered for the rest of the session. If it was not written, this
    // invocation has to ask rather than close on a state that does not exist.
    if (saveSessionGhEnv(sid, merged).failed) {
      addTarget(state, "the guard could not record this command line's GH_REPO/GH_HOST change, so the target it resolved cannot be trusted for this write");
      clearLoginProof(state, sid);
    }
  }
  emit(state);
}

function run() {
  try {
    main();
  } catch (e) {
    if (e !== DECIDED && !answered) {
      answered = true;
      process.stdout.write(JSON.stringify({
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "ask",
          permissionDecisionReason: "Confirm the forge target before this write: the guard could not evaluate this command.",
        },
      }));
    }
  }
}

module.exports = { run };
