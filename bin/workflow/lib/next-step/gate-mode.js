"use strict";
// `next-step --gate`: read-only. Turns the RECORDED current step (no evidence
// resolution, unlike the normal verdict) plus its CONFIRM_* value — and, at
// detail, the outline→detail scope change — into one closed-vocabulary
// GATE_ACTION (proceed | ask | present-and-stop | none). Skills obey it verbatim.
// GATE_HINT / REASON never carry a single quote (same invariant as STEP_HINT).

const path = require("path");
const { spawnSync } = require("child_process");
const { resolveSessionId } = require("../../../../hooks/workflow-state");
const { resolveCurrentEffectiveStep } = require("../../../../hooks/workflow-state/current-step");
const { getWorkflowPlansDir } = require("../../../../hooks/lib/workflow-plans-dir");
const { confirmGateForStep } = require("../../../../hooks/lib/confirm-gate/step-gate-map");
const {
  probeConfirmGateSync, posixJoin,
} = require("../../../../hooks/lib/confirm-gate/probe");
const { NEXT_STEP_GATE_PROBE_TIMEOUT_MS } = require("./gate-line");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..", "..", "..");

const SCOPE_CHANGE_TIMEOUT_MS = 5000;

const HINTS = {
  proceed: "Take the OFF branch of the calling skill; do not wait for the user.",
  ask: "Take the ON branch of the calling skill, exactly as that skill defines it.",
  "present-and-stop":
    "Present the scope change line and the relevant detail section, then end the turn " +
    "without the completion sentinel or --advance. If the user approves, rerun next-step " +
    "--gate --scope-change-approved and follow its GATE_ACTION; if the user asks for " +
    "changes, loop back to MDP-5.",
  none:
    "No confirm gate applies here; take neither branch, report REASON to the user, and " +
    "end the turn without the completion sentinel or --advance.",
};

function clean(s) {
  return String(s == null ? "" : s).replace(/['"]/g, "").replace(/\s+/g, " ").trim();
}

function print(action, gateLine, hint, reason) {
  let out = "GATE_ACTION=" + action + "\n";
  if (gateLine) out += gateLine + "\n";
  out += "GATE_HINT=\"" + clean(hint) + "\"\n";
  out += "REASON=\"" + clean(reason) + "\"\n";
  process.stdout.write(out);
}

// { changed, line, failed }: exit 0 = change (stdout line), 1 = none, anything else = check failed.
function detectScopeChange(sid) {
  try {
    const plans = getWorkflowPlansDir();
    const outline = posixJoin(plans, sid + "-outline.md");
    const detail = posixJoin(plans, sid + "-detail.md");
    const r = spawnSync("bash", [posixJoin(SCRIPT_CHECKOUT_ROOT, "bin", "detect-scope-change.sh"), outline, detail], {
      cwd: SCRIPT_CHECKOUT_ROOT,
      encoding: "utf8",
      timeout: SCOPE_CHANGE_TIMEOUT_MS,
      windowsHide: true,
      maxBuffer: 1024 * 1024,
    });
    if (r.error || r.signal) return { changed: false, line: "", failed: true };
    if (r.status === 0) return { changed: true, line: clean(String(r.stdout).split(/\r?\n/)[0]), failed: false };
    if (r.status === 1) return { changed: false, line: "", failed: false };
    return { changed: false, line: "", failed: true };
  } catch (_e) {
    return { changed: false, line: "", failed: true };
  }
}

function runGate(rawSession, opts) {
  const approved = !!(opts && opts.scopeChangeApproved);
  const sid = resolveSessionId({ sessionIdFromInput: rawSession });
  if (!sid) return print("none", "", HINTS.none, "session-unresolved");
  const step = resolveCurrentEffectiveStep(sid);
  const key = step ? confirmGateForStep(step) : null;
  if (!key) return print("none", "", HINTS.none, "no-confirm-gate-for-step:" + step);

  const value = probeConfirmGateSync(key, NEXT_STEP_GATE_PROBE_TIMEOUT_MS);
  const gateLine = "GATE_" + key + "=" + value;
  const reasons = [step + ": " + key + "=" + value];
  let action = value === "OFF" ? "proceed" : "ask";
  let hint = HINTS[action];

  if (step === "detail") {
    const sc = detectScopeChange(sid);
    if (sc.failed) {
      reasons.push("scope-change-check-failed");
      hint += " The scope-change check failed: warn the user that it could not run.";
    }
    if (sc.changed && action === "proceed" && approved) {
      return print("proceed", gateLine, HINTS.proceed, "scope-change-approved");
    }
    if (sc.changed) {
      reasons.push("scope-change-detected");
      if (action === "proceed") action = "present-and-stop";
      hint = "Scope change: " + sc.line + ". " + HINTS[action];
    }
  } else if (approved) {
    reasons.push("scope-change-approved-ignored");
  }
  return print(action, gateLine, hint, reasons.join(", "));
}

module.exports = { runGate };
