"use strict";

// #2699 — the registry of every supervisor reason / context generator shown to the user or the
// main conversation. Each one carries the CONV_LANG injection exactly once. Production code never
// reads this list; tests/hooks/feature-2699-supervisor-reason-conv-lang.js checks against it that
// every "[EM Supervisor]" / "[C4 " literal sits in a registered (or already-injecting) generator.
// Adding a new generator: register it here with sampleArgs that make it return a string.
// module paths are relative to this file.

const META = { sessionId: "sid", effectiveSid: "sid", stateFilePath: "state.json", auditAgentPath: "agents/supervisor-audit.md" };
const FINDING = { severity: "warning", categories: ["workflow"], reporter: "supervisor", detail: "sample", reason: "sample" };

const REGISTRY = [
  { module: "../supervisor-guard/audit-arm.js", export: "formatAuditArmReason",
    sampleArgs: [{ run_id: "run-0001", cause: "step-complete:outline", sub_checks: ["outline-intent"] }, META] },
  { module: "../stop-premature-stop-guard.js", export: "formatPrematureStopReason",
    sampleArgs: [{ pendingNote: "Workflow step pending: research." }] },
  { module: "../stop-premature-stop-guard.js", export: "formatMechanismFailureReason",
    sampleArgs: ["workflow_init"] },
  { module: "../supervisor-guard/format-integrated.js", export: "formatIntegratedReason",
    sampleArgs: [{ decision: "block", source: "l3", reason: "fallback" }, null, "Audit verdict BLOCK: sample"] },
  { module: "./supervisor-report-format.js", export: "formatL3StageBoundaryReason",
    sampleArgs: ["OUTLINE", "WARN", "sid", "state.json"] },
  { module: "./supervisor-report-format.js", export: "formatL3SeverityThresholdReason",
    sampleArgs: ["error", "WARN", "sid", "state.json"] },
  { module: "./supervisor-findings-render.js", export: "formatLayer2Findings",
    sampleArgs: [[FINDING], { sessionId: "sid", supervisorPath: "agents/supervisor.md", stateFilePath: "state.json", actionableOnly: true }] },
  { module: "../supervisor-trigger.js", export: "formatAlertAdvisory", sampleArgs: [1] },
  { module: "../workflow-gate/user-verified-audit.js", export: "holdReason", sampleArgs: [] },
  { module: "../workflow-gate/user-verified-audit.js", export: "armReason",
    sampleArgs: [{ run_id: "run-0001", sub_checks: ["code-plan"] }] },
  { module: "../workflow-gate/user-verified-audit.js", export: "unreadableArtifactsReason",
    sampleArgs: ["plan artifacts unreadable"] },
  { module: "../workflow-gate/user-verified-audit.js", export: "gateFailedReason", sampleArgs: [] },
];

module.exports = { REGISTRY };
