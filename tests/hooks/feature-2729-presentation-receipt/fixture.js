"use strict";
// Shared #2729 fixture: the presentation turn, the Stop hook and confirm-checkpoint run as child
// processes against a per-call config root (.env) and the publish-mode preload, plus raw access
// to the presentation receipt and the supervisor findings. Builds on the #2650 fixture.
// Requires WORKFLOW_STATE_DIR and WORKFLOW_PLANS_DIR pinned by the calling test.
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const X = require("../feature-2650-confirm-continuation/fixture");
const CE = require("../../lib/confirm-env-fixture");
const PCAS = require("../../lib/pre-confirm-audit-settle");

const ROOT = X.ROOT;
const PRELOAD = path.join(__dirname, "publish-mode-preload.js");
const CFG_BASE = path.join(X.F.STATE_DIR, "cfg-2729");
const BASE_VARS = { CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "on", CONFIRM_DETAIL: "on", PLAN_LANG: "english", PLAN_SYNC_REMOTE_URL: "" };
const DEFAULT_CFG = CE.confirmEnvRoot(CFG_BASE, BASE_VARS);

// cfg(over) -> a config root whose .env is BASE_VARS with `over` applied.
const cfg = (over) => (over ? CE.confirmEnvRoot(CFG_BASE, Object.assign({}, BASE_VARS, over)) : DEFAULT_CFG);

// envFor({cfg, mode, fault, env}) -> child env: the config root, the publish-mode preload, no session id;
// `env` adds per-call variables (CC_UNPUBLISHED_STAGE, STOP_CONFIRM_CONTINUE_T0_OFFSET_MS) last.
function envFor(o) {
  const opt = o || {};
  const env = CE.childEnvWith(opt.cfg || DEFAULT_CFG);
  delete env.CLAUDE_CODE_SESSION_ID;
  env.CC_PUBLISH_MODE = opt.mode || "published";
  if (opt.fault) env.CC_FAULT = opt.fault; else delete env.CC_FAULT;
  env.NODE_OPTIONS = X.nodeOptions([PRELOAD]);
  delete env.CC_UNPUBLISHED_STAGE;
  delete env.STOP_CONFIRM_CONTINUE_T0_OFFSET_MS;
  if (opt.env) Object.assign(env, opt.env);
  return env;
}

const parse = (out) => { try { return out ? JSON.parse(out) : {}; } catch (_) { return { unparsed: out }; } };

// stop(sid, tpath, opts) -> {rc, out, err, json, reason, blocked, continued}. opts.input merges into the hook input.
function stop(sid, tpath, opts) {
  const o = opts || {};
  const input = Object.assign({ session_id: sid, transcript_path: tpath, hook_event_name: "Stop", stop_hook_active: false }, o.input || {});
  const r = spawnSync(process.execPath, [path.join(ROOT, "hooks/stop-confirm-plan-guard.js")], {
    input: JSON.stringify(input), env: envFor(o), encoding: "utf8", timeout: 60000, cwd: X.TDIR,
  });
  const out = r.stdout || "";
  const json = parse(out);
  const reason = typeof json.reason === "string" ? json.reason : "";
  return {
    rc: r.status, out, err: r.stderr || "", json, reason,
    blocked: r.status === 2 && json.decision === "block",
    continued: r.status === 2 && reason.startsWith("[confirm-plan] continue:"),
  };
}

// echo(sid, stage, opts) -> {rc, json, msg, reason, denied, skipped, dialog} for the stage's CONFIRM echo.
// opts.noSid sends the hook input without a session id; opts.transcriptPath sends the transcript_path
// the real hook receives (the judge must not depend on it, but a regression reading it is then caught).
function echo(sid, stage, opts) {
  const o = opts || {};
  // #2853: the stage's pre-confirm audit is settled on the plan as it is now; this fixture tests the receipt.
  if (!o.noSid) PCAS.trySettle(sid, stage, "CONTINUE");
  const input = { tool_name: "Bash", tool_input: { command: X.echoOf(stage) }, hook_event_name: "PreToolUse" };
  if (!o.noSid) input.session_id = sid;
  if (o.transcriptPath) input.transcript_path = o.transcriptPath;
  const r = spawnSync(process.execPath, [path.join(ROOT, "hooks/confirm-checkpoint.js")], {
    input: JSON.stringify(input), env: envFor(o), encoding: "utf8", timeout: 60000, cwd: X.TDIR,
  });
  const json = parse(r.stdout || "");
  const msg = typeof json.systemMessage === "string" ? json.systemMessage : "";
  const hso = json.hookSpecificOutput || {};
  const denied = hso.permissionDecision === "deny";
  const skipped = r.status === 0 && msg.startsWith("[confirm-skipped");
  return {
    rc: r.status, json, msg, err: r.stderr || "", reason: typeof json.reason === "string" ? json.reason : "",
    denied, skipped, dialog: r.status === 0 && msg !== "" && !skipped && !denied,
  };
}

const receiptPath = (sid, stage) => path.join(X.stateDirOf(sid), `${sid}.confirm-plan-receipt-${stage}.json`);
function readReceiptRaw(sid, stage) {
  try { return JSON.parse(fs.readFileSync(receiptPath(sid, stage), "utf8")); } catch (_) { return null; }
}
const receiptExists = (sid, stage) => fs.existsSync(receiptPath(sid, stage));
function writeReceiptRaw(sid, stage, body) {
  fs.mkdirSync(path.dirname(receiptPath(sid, stage)), { recursive: true });
  fs.writeFileSync(receiptPath(sid, stage), typeof body === "string" ? body : JSON.stringify(body));
}

// findings(sid) -> the supervisor layer1 findings recorded for the session ([] when none).
function findings(sid) {
  try {
    const st = require(path.join(ROOT, "hooks/lib/supervisor-state-writer")).readState(sid);
    return (st && st.layer1 && Array.isArray(st.layer1.findings)) ? st.layer1.findings : [];
  } catch (_) { return []; }
}

const sha256 = (p) => require("crypto").createHash("sha256").update(fs.readFileSync(p)).digest("hex");

// presentTurn(s, stages, closing, opts) -> transcript path of one turn that wrote `stages`' plans
// (a turn marker each, like show-plan-link) and whose last text block is `closing`.
function presentTurn(s, stages, closing, opts) {
  const o = opts || {};
  const entries = (o.before || []).slice();
  entries.push(X.U(o.prompt || "write the plan", `u-prompt-${s.sid.slice(0, 8)}`));
  let i = 0;
  for (const st of stages) {
    const p = X.linesFor(s.sid, st).plan;
    if (o.markers !== false) X.turnMarker(s.sid, st, p);
    i += 1;
    entries.push(X.A(`a-w${i}`, X.W(p, `w${i}`)), X.TR(`w${i}`, `u-tr${i}`));
  }
  entries.push(X.A(o.anchorUuid || "a-anchor", X.T(closing)));
  return X.writeTranscript(s.sid, entries);
}

// The intent plan text edited after its approval (the approval hash no longer matches).
const EDITED_INTENT = "# Intent\n\n## Goal\n\nfixture goal, edited after approval\n\n## Issues\n\n- #1 fixture\n\n## Constraints\n\nnone\n";

module.exports = Object.assign({}, X, {
  CE, PRELOAD, BASE_VARS, DEFAULT_CFG, cfg, envFor, stop, echo,
  receiptPath, readReceiptRaw, receiptExists, writeReceiptRaw, findings, sha256, presentTurn, EDITED_INTENT,
});

// echoAsync(sid, stage, opts) -> Promise of echo()'s result shape, from an async spawn, so several
// confirm-checkpoint processes can race on one presentation receipt.
function echoAsync(sid, stage, opts) {
  const o = opts || {};
  const input = { tool_name: "Bash", tool_input: { command: X.echoOf(stage) }, hook_event_name: "PreToolUse", session_id: sid };
  PCAS.trySettle(sid, stage, "CONTINUE");
  return new Promise((resolve) => {
    const child = require("child_process").spawn(process.execPath, [path.join(ROOT, "hooks/confirm-checkpoint.js")], {
      env: envFor(o), cwd: X.TDIR, stdio: ["pipe", "pipe", "pipe"],
    });
    let out = "";
    let err = "";
    const timer = setTimeout(() => child.kill(), 60000);
    child.stdout.on("data", (d) => { out += d; });
    child.stderr.on("data", (d) => { err += d; });
    child.on("error", (e) => { err += String(e); });
    child.on("close", (rc) => {
      clearTimeout(timer);
      const json = parse(out);
      const msg = typeof json.systemMessage === "string" ? json.systemMessage : "";
      const denied = (json.hookSpecificOutput || {}).permissionDecision === "deny";
      const skipped = rc === 0 && msg.startsWith("[confirm-skipped");
      resolve({
        rc, json, msg, err, reason: typeof json.reason === "string" ? json.reason : "",
        denied, skipped, dialog: rc === 0 && msg !== "" && !skipped && !denied,
      });
    });
    child.stdin.end(JSON.stringify(input));
  });
}
module.exports.echoAsync = echoAsync;
