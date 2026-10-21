"use strict";
// hooks/workflow-state/glossary-check/record.js — the glossary-check record (#2529): the
// step annotations `glossary_check` (per stage) and `glossary_provenance` (review_docs), the
// completion predicate evaluateGlossaryCheck, and the completion-boundary guard over one batch.
// Every input comes from scope.js (invariant I-FP); this module never reads an input itself.

const { STAGE_STEP, RA_STAGES, RS_STAGES, stageOfStep, loadStageInputs, fingerprintOf } = require("./scope");

const RECORD_KEY = "glossary_check";
const PROVENANCE_KEY = "glossary_provenance";
const PROVENANCE_STEP = "review_docs";
// Set only by events.js (an inheritance copy, or a batch carrying a `reset` anchor); since
// #2709 neither is a SANCTIONED_SOURCES token, so a caller's own opts.sanctioned never reaches here.
const SKIP_TOKENS = Object.freeze(["reset-sentinel", "session-inherit"]);
const COMPONENTS = Object.freeze(["artifact", "glossary", "intent_rows", "rules"]);

const asArray = (v) => (Array.isArray(v) ? v : []);
const sameFp = (grants, fp) => asArray(grants).filter((g) => g && g.fingerprint === fp);

// recoveryFor(sid, stage, code, detail): the one recovery text per refusal code, shown by the
// completion refusal, the next-step hint and the effective view alike. No single quotes:
// next-step wraps NEXT_HINT in them.
function recoveryFor(sid, stage, code, detail) {
  const run = `check-glossary-drift --session ${sid || "<sid>"} --stage ${stage} --record`;
  const d = detail || {};
  if (code === "glossary-findings-unresolved") {
    const terms = [...new Set(asArray(d.findings).map((f) => String(f && f.term)))].join(", ");
    return `fix each open DRIFT finding (${terms}) in the ${stage} artifact and run: ${run}, ` +
      `or accept it with: echo "<<WORKFLOW_GLOSSARY_ACCEPTED: term=<term> stage=${stage} — <reason>>>"; ` +
      "then complete the step again.";
  }
  const generic = `run: ${run}, then fix each DRIFT finding or record an ACCEPTED grant, and complete the step again.`;
  if (code === "glossary-fingerprint-unavailable") {
    return `the glossary check inputs cannot be read (${d.error || "unknown"}${d.cause ? ": " + d.cause : ""}); ` +
      "fix that cause first, then " + generic;
  }
  return generic;
}

class GlossaryCheckIncompleteError extends Error {
  constructor(step, code, recovery) {
    super(`workflow step "${step}" cannot be completed: ${code}. ${recovery || ""}`.trim());
    this.name = "GlossaryCheckIncompleteError";
    this.step = step;
    this.code = code;
    this.recovery = recovery || "";
  }
}

function annotation(step, key, value, origin) {
  return { kind: "step_annotation", step, key, value, provenance: "observed", origin };
}

// checkRecordEvents(current, stage, fpResult, findings, origin) -> [step_annotation event].
// current: the stage's previous glossary_check value (or null). Grants survive only at the same
// fingerprint; ledger_grants are bound to a concern, not the fingerprint, and always carry.
function checkRecordEvents(current, stage, fpResult, findings, origin) {
  const prev = current || {};
  const value = {
    v: 1, stage, fingerprint: fpResult.fingerprint, inputs: fpResult.inputs,
    findings: asArray(findings).map((f) => ({
      source: "deterministic", class: "spelling", term: f.term, norm: f.norm, variant: f.variant, where: f.where,
    })),
    grants: sameFp(prev.grants, fpResult.fingerprint),
    ledger_grants: asArray(prev.ledger_grants),
  };
  return [annotation(STAGE_STEP[stage], RECORD_KEY, value, origin || "check-glossary-drift")];
}

// provenanceRecordEvents(current, fpResult, sessionSource, blocked, origin) -> [event].
function provenanceRecordEvents(current, fpResult, sessionSource, blocked, origin) {
  const prev = current || {};
  const value = {
    v: 1, fingerprint: fpResult.fingerprint, inputs: fpResult.inputs, session_source: sessionSource,
    blocked: asArray(blocked), grants: sameFp(prev.grants, fpResult.fingerprint),
  };
  return [annotation(PROVENANCE_STEP, PROVENANCE_KEY, value, origin || "check-glossary-provenance")];
}

function recordOf(projection, step) {
  const entry = projection && projection.steps && projection.steps[step];
  return (entry && entry[RECORD_KEY]) || null;
}

function changedComponents(recorded, current) {
  const r = recorded || {};
  return COMPONENTS.filter((c) => r[c] !== current[c]);
}

// evaluateGlossaryCheck(sid, step, projection, opts) -> { ok: true } | { ok: false, code, detail }.
// opts.mode: "boundary" (default) | "commit"; opts.repoDir / opts.ruleModules go to scope.js.
function evaluateGlossaryCheck(sid, step, projection, opts) {
  const o = opts || {};
  const stage = stageOfStep(step);
  if (!stage) return { ok: true };
  const fail = (code, detail) => ({ ok: false, code, detail: Object.assign({ recovery: recoveryFor(sid, stage, code, detail) }, detail) });
  const scopeOpts = { repoDir: o.repoDir, ruleModules: o.ruleModules };
  let loaded = null;
  if (o.mode === "commit" && RS_STAGES.includes(stage)) {
    loaded = loadStageInputs(sid, stage, scopeOpts);
    if (loaded.ok && loaded.artifact.empty) return { ok: true };
  }
  const rec = recordOf(projection, step);
  if (!rec || typeof rec.fingerprint !== "string" || rec.fingerprint === "") return fail("glossary-check-missing", {});
  const now = fingerprintOf(loaded || loadStageInputs(sid, stage, scopeOpts));
  if (!now.ok) return fail("glossary-fingerprint-unavailable", { error: now.error, cause: now.detail || null });
  if (now.fingerprint !== rec.fingerprint) {
    return fail("glossary-check-stale", { changed: changedComponents(rec.inputs, now.inputs) });
  }
  const grants = sameFp(rec.grants, rec.fingerprint);
  const open = asArray(rec.findings).filter((f) => !grants.some((g) => g.norm === f.norm));
  if (open.length > 0) return fail("glossary-findings-unresolved", { findings: open });
  return { ok: true };
}

const statusOf = (proj, step) => {
  const entry = proj && proj.steps && proj.steps[step];
  return (entry && entry.status) || "pending";
};

// glossaryRefusalOfComplete(sid, step, projection, opts) -> the evaluateGlossaryCheck refusal code
// (stale / findings-unresolved / fingerprint-unavailable) of a plan stage (R-A) recorded complete
// with a glossary_check record, else null. A complete with no record, or a record without a
// fingerprint (recorded before #2529), is legacy and left complete. R-S stages: the commit gate.
function glossaryRefusalOfComplete(sid, step, projection, opts) {
  const err = glossaryRefusalErrorOfComplete(sid, step, projection, opts);
  return err ? err.code : null;
}

// glossaryRefusalErrorOfComplete(...) -> the same refusal as a GlossaryCheckIncompleteError
// (code + recovery text), for a writer that must word it; null when the complete stands.
function glossaryRefusalErrorOfComplete(sid, step, projection, opts) {
  const o = opts || {};
  if (!RA_STAGES.includes(stageOfStep(step)) || statusOf(projection, step) !== "complete") return null;
  const rec = recordOf(projection, step);
  if (!rec || typeof rec.fingerprint !== "string" || rec.fingerprint === "") return null;
  const v = evaluateGlossaryCheck(sid, step, projection, { mode: "boundary", repoDir: o.repoDir, ruleModules: o.ruleModules });
  return v.ok ? null : new GlossaryCheckIncompleteError(step, v.code, v.detail && v.detail.recovery);
}

// glossaryBoundaryForBatch(sid, prev, next, opts): throws GlossaryCheckIncompleteError when a
// glossary stage step moves to complete in this batch without a valid record.
function glossaryBoundaryForBatch(sid, prevProjection, nextProjection, opts) {
  const o = opts || {};
  if (SKIP_TOKENS.includes(o.sanctioned)) return;
  for (const stage of Object.keys(STAGE_STEP)) {
    const step = STAGE_STEP[stage];
    if (statusOf(prevProjection, step) === "complete" || statusOf(nextProjection, step) !== "complete") continue;
    const v = evaluateGlossaryCheck(sid, step, nextProjection, { mode: "boundary", repoDir: o.repoDir, ruleModules: o.ruleModules });
    if (!v.ok) throw new GlossaryCheckIncompleteError(step, v.code, v.detail && v.detail.recovery);
  }
}

module.exports = {
  RECORD_KEY, PROVENANCE_KEY, PROVENANCE_STEP,
  GlossaryCheckIncompleteError, checkRecordEvents, provenanceRecordEvents,
  evaluateGlossaryCheck, glossaryRefusalOfComplete, glossaryRefusalErrorOfComplete, glossaryBoundaryForBatch,
};
