"use strict";
// Mechanism-failure detection and once-per-finding reporting (#1997).
//
// When the workflow mechanism itself fails — a step stuck in_progress forever,
// a state file that vanished or went corrupt — nothing used to surface it.
// Rationale: docs/architecture/claude-code/workflow.md.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { getWorkflowDir, readState } = require("../workflow-state/state-io");
const { STEP_IN_FLIGHT_TTL_MS } = require("./step-in-flight-policy");
const { normalizeCwd } = require("./path-normalize");

const SID_RE = /^[A-Za-z0-9_-]+$/;
const SID_MAX_LEN = 128;
const LEDGER_SUFFIX = ".stall-reported";
const STATE_PSEUDO_STEP = "(state)";
const REPORT_TIMEOUT_MS = 15000;

// The session id arrives from hook stdin and becomes a filename, so it is
// validated before any path is built — never sanitized into something else.
function isSafeSid(sid) {
  return typeof sid === "string" && sid.length > 0 && sid.length <= SID_MAX_LEN && SID_RE.test(sid);
}

function ledgerPathFor(sid) {
  return path.join(getWorkflowDir(), sid + LEDGER_SUFFIX);
}

function findingKey(finding) {
  return String(finding && finding.step) + ":" + String(finding && finding.kind);
}

// detectStalledSteps(sid): total, read-only classification of what went wrong.
// State-level failures have no step to blame and report under `(state)`;
// `state-absent` and `state-corrupt` stay distinct because "never initialized"
// and "written then damaged" call for different human responses.
function detectStalledSteps(sid) {
  try {
    if (!isSafeSid(sid)) return [];
    const statePath = path.join(getWorkflowDir(), sid + ".json");
    if (!fs.existsSync(statePath)) return [{ step: STATE_PSEUDO_STEP, kind: "state-absent" }];
    const state = readState(sid);
    if (!state || !state.steps || typeof state.steps !== "object") {
      return [{ step: STATE_PSEUDO_STEP, kind: "state-corrupt" }];
    }
    const findings = [];
    for (const step of Object.keys(state.steps)) {
      const entry = state.steps[step];
      if (!entry || typeof entry !== "object" || entry.status !== "in_progress") continue;
      // An in_progress record with no usable timestamp can never expire on the
      // age axis, so it is its own kind: a silent failure forever otherwise.
      if (typeof entry.updated_at !== "string") {
        findings.push({ step, kind: "invalid-timestamp" });
        continue;
      }
      const updatedAt = Date.parse(entry.updated_at);
      if (Number.isNaN(updatedAt)) {
        findings.push({ step, kind: "invalid-timestamp" });
        continue;
      }
      if (Date.now() - updatedAt >= STEP_IN_FLIGHT_TTL_MS) {
        findings.push({ step, kind: "in-flight-expired" });
      }
    }
    return findings;
  } catch (_e) {
    return [];
  }
}

function readLedger(sid) {
  try {
    const parsed = JSON.parse(fs.readFileSync(ledgerPathFor(sid), "utf8"));
    if (Array.isArray(parsed)) return { version: 1, session_id: sid, findings: parsed };
    if (parsed && Array.isArray(parsed.findings)) return parsed;
  } catch (_e) {}
  return { version: 1, session_id: sid, findings: [] };
}

function writeLedger(sid, ledger) {
  const target = ledgerPathFor(sid);
  const tmpPath = target + "." + process.pid + ".tmp";
  const json = JSON.stringify(ledger, null, 2) + "\n";
  try {
    fs.mkdirSync(path.dirname(target), { recursive: true });
    // flag "wx" (O_CREAT|O_EXCL): symlink at predictable tmp path fails with EEXIST
    try {
      fs.writeFileSync(tmpPath, json, { encoding: "utf8", flag: "wx", mode: 0o600 });
    } catch (e) {
      if (e && e.code === "EEXIST") {
        fs.unlinkSync(tmpPath);
        fs.writeFileSync(tmpPath, json, { encoding: "utf8", flag: "wx", mode: 0o600 });
      } else { throw e; }
    }
    fs.renameSync(tmpPath, target);
    return true;
  } catch (_e) {
    try { fs.unlinkSync(tmpPath); } catch (_u) {}
    return false;
  }
}

// The CLI is located from AGENTS_CONFIG_DIR verbatim rather than through
// resolveAgentsConfigDir(): the caller may point at an alternate config dir
// that carries only bin/, and marker validation would silently redirect the
// report back to the installed checkout.
function resolveConfigDir() {
  const raw = process.env.AGENTS_CONFIG_DIR;
  if (typeof raw === "string" && raw.trim()) {
    try { return path.resolve(normalizeCwd(raw.trim()) || raw.trim()); } catch (_e) {}
  }
  return path.resolve(__dirname, "..", "..");
}

// Git Bash cannot exec a shebang script directly through spawnSync, so the
// interpreter is chosen from the script's own first line.
function interpreterFor(cliPath) {
  let head = "";
  try {
    const fd = fs.openSync(cliPath, "r");
    const buf = Buffer.alloc(128);
    const n = fs.readSync(fd, buf, 0, 128, 0);
    fs.closeSync(fd);
    head = buf.slice(0, n).toString("utf8").split("\n")[0];
  } catch (_e) {
    return process.execPath;
  }
  if (/node/.test(head)) return process.execPath;
  if (/\b(bash|sh|zsh)\b/.test(head)) return "bash";
  return process.execPath;
}

function detailFor(finding) {
  return (
    "mechanism-failure: workflow step '" + String(finding.step) + "' is " +
    String(finding.kind) + " — the mechanism stalled and nothing settled it."
  );
}

// Spawning bin/supervisor-report (rather than calling appendFinding in-process)
// keeps one reporting entrypoint for every producer of supervisor findings.
function runSupervisorReport(sid, finding) {
  const cli = path.join(resolveConfigDir(), "bin", "supervisor-report");
  if (!fs.existsSync(cli)) return { ok: false, reason: "supervisor-report-missing" };
  const args = [
    cli,
    "--categories", "workflow",
    "--severity", "error",
    "--detail", detailFor(finding),
    "--reporter", "mechanism-failure",
    "--session-id", sid,
  ];
  const res = spawnSync(interpreterFor(cli), args, {
    encoding: "utf8",
    timeout: REPORT_TIMEOUT_MS,
    windowsHide: true,
  });
  if (res.error) return { ok: false, reason: "supervisor-report-spawn-failed" };
  if (res.status !== 0) return { ok: false, reason: "supervisor-report-exit-" + String(res.status) };
  return { ok: true, reason: "reported" };
}

// The alert layer is what a human or a later session actually reads, so the
// finding is surfaced there too — a mechanism failure needs no triage to know
// it must be seen.
function recordAlertFinding(sid, finding) {
  try {
    const { writeAlertState } = require("./supervisor-state-writer");
    return writeAlertState(sid, {
      findings: [{
        categories: ["workflow"],
        severity: "error",
        detail: detailFor(finding),
        reporter: "mechanism-failure",
      }],
    }) === true;
  } catch (_e) {
    return false;
  }
}

// reportMechanismFailureOnce(sid, finding): report a finding at most once per
// session. Never throws — it runs inside a UserPromptSubmit hook, where an
// exception costs the user their prompt. The ledger is written only AFTER a
// successful report, so a transient failure cannot become permanent silence.
function reportMechanismFailureOnce(sid, finding) {
  try {
    if (!isSafeSid(sid)) return { reported: false, reason: "invalid-session-id" };
    if (!finding || typeof finding !== "object" || !finding.step || !finding.kind) {
      return { reported: false, reason: "invalid-finding" };
    }
    const key = findingKey(finding);
    const ledger = readLedger(sid);
    if (ledger.findings.some((f) => findingKey(f) === key)) {
      return { reported: false, reason: "already-reported" };
    }
    const sent = runSupervisorReport(sid, finding);
    if (!sent.ok) return { reported: false, reason: sent.reason };
    if (!recordAlertFinding(sid, finding)) {
      return { reported: false, reason: "alert-record-failed" };
    }
    ledger.findings.push({
      step: String(finding.step),
      kind: String(finding.kind),
      reported_at: new Date().toISOString(),
    });
    if (!writeLedger(sid, ledger)) return { reported: false, reason: "ledger-write-failed" };
    return { reported: true, reason: "reported" };
  } catch (e) {
    return { reported: false, reason: "unexpected-error" };
  }
}

module.exports = {
  LEDGER_SUFFIX,
  STATE_PSEUDO_STEP,
  isSafeSid,
  ledgerPathFor,
  detectStalledSteps,
  reportMechanismFailureOnce,
};
