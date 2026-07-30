"use strict";
// bin/worker-dispatch/workers/session-close-gate.js
//
// Stage 2 worker: replaces agents/session-close-worker.md.
//
// Decides one thing — may the caller run SC-6, or must it halt? The answer is a
// pure function of the supervisor state file plus wall-clock time, which is why
// this worker is a good scriptification target: the agent it replaces was
// re-deriving a fixed decision table on every run.
//
// SC-4 changes character here. The agent was told to "scan for any unreported
// observations", which an LLM answers by judgment and therefore answers
// differently each time. A script cannot judge, so the scan is redefined as what
// it was actually approximating: every issue entry in the outcome JSON whose
// per-step field records a failure or a skip is one observation, reported at a
// severity fixed by the field value. Same audit trail, reproducible.

const fs = require("fs");
const path = require("path");

const { run: spawnRun } = require("../spawn");

const REPORT_TIMEOUT_MS = 30000;
const PHASE_TIMEOUT_MS = 600000;
// Per-issue fields the outcome JSON records a disposition for. `state` is the
// triage verdict; the rest are the pipeline steps ICF-H/I/J and the history write.
const OUTCOME_FIELDS = ["state", "historyEntry", "issueClosed", "sentinelsPosted", "wipCleared"];

// Absent and corrupt are different facts and must not collapse into one null:
// absent means no supervisor ever wrote here, corrupt means the record of what
// it found is unreadable. Treating the second as the first makes an unreadable
// state file look like a clean session. `kind` is "absent" | "corrupt" | "ok".
function readJsonTri(p) {
  if (typeof p !== "string" || p === "") return { kind: "absent", value: null };
  let raw;
  try {
    raw = fs.readFileSync(p, "utf8");
  } catch (e) {
    return { kind: e && e.code === "ENOENT" ? "absent" : "corrupt", value: null };
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (_e) {
    return { kind: "corrupt", value: null };
  }
  // `null`, a number, or a bare string parses fine but carries no phase fields.
  if (parsed === null || typeof parsed !== "object") return { kind: "corrupt", value: null };
  return { kind: "ok", value: parsed };
}

// A field value is an observation when it is not the clean-completion value.
// "failed" is a warning; every skip variant is a notice; anything else is clean.
function severityFor(value) {
  if (typeof value !== "string") return null;
  if (value === "failed") return "warning";
  if (value === "skipped" || value.startsWith("skipped_") || value.startsWith("skipped-")) return "notice";
  return null;
}

// SC-4: derive one observation per non-clean field across all issue entries.
function scanOutcome(outcome) {
  const issues = outcome && Array.isArray(outcome.issues) ? outcome.issues : [];
  const found = [];
  for (const entry of issues) {
    if (!entry || typeof entry !== "object") continue;
    const num = Number.isInteger(entry.issueNumber) ? entry.issueNumber : null;
    const label = num === null ? "(issue number missing)" : `#${num}`;
    for (const field of OUTCOME_FIELDS) {
      const severity = severityFor(entry[field]);
      if (severity === null) continue;
      found.push({
        severity,
        detail: `issue-close outcome ${label}: ${field}=${entry[field]}`,
      });
    }
  }
  return found;
}

// Reporting is best-effort by design: SC-4 is an audit trail, and a failed
// report must never change the gate decision the caller depends on.
function reportFinding(ctx, sessionId, finding) {
  try {
    const res = spawnRun(ctx.entry, {
      anchors: ctx.anchors,
      command: "node",
      script: "report",
      args: [
        "--categories", "workflow",
        "--severity", finding.severity,
        "--detail", finding.detail,
        "--reporter", "session-close-gate",
        "--session-id", sessionId,
      ],
      cwd: ctx.anchors.mainRoot,
      timeoutMs: REPORT_TIMEOUT_MS,
    });
    return res.status === 0;
  } catch (_e) {
    return false;
  }
}

function elapsedMs(armedAt, nowMs) {
  if (typeof armedAt !== "string") return null;
  const t = Date.parse(armedAt);
  return Number.isNaN(t) ? null : nowMs - t;
}

// SC-5. Returns { gateAction, phase, findings, repair } — `repair` names the
// CLI the caller must run to un-wedge a stale pending phase, or null.
function evaluateAlert(state, nowMs) {
  const alert = state && typeof state.alert === "object" && state.alert !== null ? state.alert : {};
  const phase = typeof alert.alert_phase === "string" ? alert.alert_phase : null;
  const findings = [];

  if (phase !== "pending") return { gateAction: "proceed", phase, findings, repair: null };

  const armedAt = alert.alert_armed_at;
  if (armedAt === null || armedAt === undefined) {
    findings.push({
      severity: "error",
      detail: "supervisor alert_phase=pending with alert_armed_at=null (anomalous state)",
    });
    return { gateAction: "proceed", phase, findings, repair: null };
  }

  // #961: a recorded last_run_at means the alert actually ran and only the phase
  // flag was left behind. Repair the flag rather than blocking the close.
  if (alert.last_run_at !== null && alert.last_run_at !== undefined) {
    findings.push({
      severity: "notice",
      detail: "supervisor alert_phase=pending but last_run_at is set — repairing phase to done",
    });
    return { gateAction: "proceed", phase, findings, repair: "alert" };
  }

  const elapsed = elapsedMs(armedAt, nowMs);
  if (elapsed === null || elapsed > PHASE_TIMEOUT_MS) {
    findings.push({
      severity: "warning",
      detail:
        elapsed === null
          ? "supervisor alert_armed_at is unparseable — proceeding via elapsed-time fallback"
          : `supervisor alert has been pending for ${Math.round(elapsed / 1000)}s — proceeding via elapsed-time fallback`,
    });
    return { gateAction: "proceed", phase, findings, repair: null };
  }

  return { gateAction: "yield", phase, findings, repair: null };
}

// SC-5b. Mirrors the alert table, with one asymmetry the spec fixes: a pending
// audit within its timeout yields even when the alert side said proceed.
function evaluateAudit(state, nowMs) {
  const audit = state && typeof state.audit === "object" && state.audit !== null ? state.audit : {};
  const phase = typeof audit.audit_phase === "string" ? audit.audit_phase : null;
  const findings = [];

  if (phase !== "pending") return { gateAction: null, phase, findings, repair: null };

  if (audit.audit_last_run_at !== null && audit.audit_last_run_at !== undefined) {
    findings.push({
      severity: "notice",
      detail: "supervisor audit_phase=pending but audit_last_run_at is set — repairing phase to done",
    });
    return { gateAction: null, phase, findings, repair: "audit" };
  }

  const elapsed = elapsedMs(audit.audit_armed_at, nowMs);
  if (elapsed === null || elapsed > PHASE_TIMEOUT_MS) {
    findings.push({
      severity: "warning",
      detail:
        elapsed === null
          ? "supervisor audit_armed_at is unparseable — proceeding via elapsed-time fallback"
          : `supervisor audit has been pending for ${Math.round(elapsed / 1000)}s — proceeding via elapsed-time fallback`,
    });
    return { gateAction: null, phase, findings, repair: null };
  }

  return { gateAction: "yield", phase, findings, repair: null };
}

function applyRepair(ctx, sessionId, which) {
  const script = which === "alert" ? "writeAlert" : "writeAudit";
  const setFlag = which === "alert" ? "--set-alert-phase" : "--set-audit-phase";
  const clearFlag = which === "alert" ? "--clear-alert-armed-at" : "--clear-audit-armed-at";
  try {
    // --session-id is passed for the audit repair too. The CLI can auto-resolve
    // it, but a worker has no session context of its own to resolve from, so the
    // caller-supplied id is the only trustworthy source here.
    const res = spawnRun(ctx.entry, {
      anchors: ctx.anchors,
      command: "node",
      script,
      args: ["--session-id", sessionId, setFlag, "done", clearFlag],
      cwd: ctx.anchors.mainRoot,
      timeoutMs: REPORT_TIMEOUT_MS,
    });
    return res.status === 0;
  } catch (_e) {
    return false;
  }
}

function run(payload, ctx) {
  const { anchors, fsguard } = ctx;
  const sessionId = payload.session_id;
  const plansDir = payload.plans_dir || anchors.plansDir;
  const artifactDir = payload.artifact_dir || anchors.plansDir;
  const nowMs = Date.now();

  // SC-4 — retrospective scan. Non-fatal throughout: a missing or malformed
  // outcome file yields zero observations, never a failed gate. A malformed one
  // still earns a finding — zero observations from an unreadable file is not the
  // same fact as zero observations from a clean one.
  const outcomeRead = readJsonTri(payload.outcome_json_path);
  const findings = scanOutcome(outcomeRead.value);
  if (outcomeRead.kind === "corrupt") {
    findings.push({
      severity: "warning",
      detail: `issue-close outcome JSON unreadable or malformed: ${payload.outcome_json_path} — SC-4 scanned nothing`,
    });
  }

  // SC-5 / SC-5b — phase evaluation.
  const statePath = path.join(plansDir, `${sessionId}-supervisor-state.json`);
  const stateRead = readJsonTri(statePath);
  const state = stateRead.value;

  let gateAction = "proceed";
  let alertPhase = null;
  let auditPhase = null;

  if (stateRead.kind === "corrupt") {
    // Fail closed: the gate exists to withhold the Final Report while a
    // supervisor review is outstanding, and an unreadable state file cannot
    // prove there is none. Yielding costs a re-run; proceeding loses the review.
    gateAction = "yield";
    findings.push({
      severity: "warning",
      detail: `supervisor state file unreadable or malformed: ${statePath} — gate yields (fail-closed)`,
    });
  } else if (state !== null) {
    const alert = evaluateAlert(state, nowMs);
    const audit = evaluateAudit(state, nowMs);
    alertPhase = alert.phase;
    auditPhase = audit.phase;
    findings.push(...alert.findings, ...audit.findings);
    gateAction = audit.gateAction === "yield" ? "yield" : alert.gateAction;
    if (alert.repair !== null) applyRepair(ctx, sessionId, alert.repair);
    if (audit.repair !== null) applyRepair(ctx, sessionId, audit.repair);
  }

  for (const finding of findings) reportFinding(ctx, sessionId, finding);

  const gatePath = path.join(artifactDir, `${sessionId}-session-close-gate.json`);
  let written = null;
  try {
    written = fsguard.writeFile(gatePath, `${JSON.stringify({ gate_action: gateAction }, null, 2)}\n`);
  } catch (e) {
    return {
      status: "failed",
      summary: `gate JSON write failed: ${e && e.message ? e.message : "unknown error"}`,
      artifactPath: "(none)",
    };
  }

  // A corrupt state file skips phase evaluation, so both phases are unset — but
  // reporting them as "(absent)" next to gate_action=yield reads as a
  // contradiction. Say why they are unset, in the stdout the caller parses.
  const phaseUnset = stateRead.kind === "corrupt" ? "(corrupt)" : "(absent)";
  const summary =
    `gate_action=${gateAction}; SC-4 findings: ${findings.length};` +
    ` SC-5 alert_phase: ${alertPhase === null ? phaseUnset : alertPhase};` +
    ` SC-5b audit_phase: ${auditPhase === null ? phaseUnset : auditPhase}`;

  // Log write is best-effort — the gate JSON is the contract, the log is not.
  try {
    fsguard.writeFile(
      path.join(artifactDir, `${sessionId}-session-close-worker.log`),
      [
        `state file: ${stateRead.kind === "ok" ? statePath : `(${stateRead.kind})`}`,
        `gate_action: ${gateAction}`,
        `alert_phase: ${alertPhase === null ? "(absent)" : alertPhase}`,
        `audit_phase: ${auditPhase === null ? "(absent)" : auditPhase}`,
        `findings: ${findings.length}`,
        ...findings.map((f) => `  [${f.severity}] ${f.detail}`),
        "",
      ].join("\n")
    );
  } catch (_e) {
    // ignore
  }

  return { status: "complete", summary, artifactPath: written };
}

module.exports = { run, scanOutcome, severityFor, evaluateAlert, evaluateAudit };
