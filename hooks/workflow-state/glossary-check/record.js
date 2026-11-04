"use strict";
// hooks/workflow-state/glossary-check/record.js — the glossary-check record (#2529): the
// step annotations `glossary_check` (per glossary step) and `glossary_provenance` (review_docs), the
// completion predicate evaluateGlossaryCheck, and the completion-boundary guard over one batch.
// Every input comes from scope.js (invariant I-FP); this module never reads an input itself.

const { GLOSSARY_STEPS, RA_STEPS, RS_STEPS, loadStepInputs, fingerprintOf } = require("./scope");
const { CARRY_ROLES, grantCarry, retainedExpired, staleOutlook, termsText, causeText, reacceptText, termIn } = require("./grant-carry");

const RECORD_KEY = "glossary_check";
const PROVENANCE_KEY = "glossary_provenance";
const PROVENANCE_STEP = "review_docs";
// Set only by events.js (an inheritance copy, or a batch carrying a `reset` anchor); since
// #2709 neither is a SANCTIONED_SOURCES token, so a caller's own opts.sanctioned never reaches here.
const SKIP_TOKENS = Object.freeze(["reset-sentinel", "session-inherit"]);
const COMPONENTS = Object.freeze(["artifact", "glossary", "intent_rows", "rules"]);

const asArray = (v) => (Array.isArray(v) ? v : []);
const sameFp = (grants, fp) => asArray(grants).filter((g) => g && g.fingerprint === fp);

// recoveryFor(sid, step, code, detail): the one recovery text per refusal code, shown by the
// completion refusal, the next-step hint, the effective view and the commit gate alike. No single
// quotes, in the text or in any part it embeds (termsText, causeText, reacceptText "hint"):
// next-step wraps NEXT_HINT in them.
function recoveryFor(sid, step, code, detail) {
  const run = `check-glossary-drift --session ${sid || "<sid>"} --step ${step} --record`;
  const d = detail || {};
  if (code === "glossary-findings-unresolved") {
    const terms = termsText(asArray(d.findings).map((f) => String(f && f.term)));
    const lapsed = asArray(d.expired).map((e) =>
      `the grant for ${termsText([e.term])} lapsed on the last record (${causeText(e)}); `).join("");
    return `${lapsed}fix each open DRIFT finding (${terms}) in the ${step} artifact and run: ${run}, ` +
      `or accept it with: echo "<<WORKFLOW_GLOSSARY_ACCEPTED: term=<term> step=${step} — <reason>>>"; ` +
      "then complete the step again.";
  }
  if (code === "glossary-check-stale") {
    const changed = asArray(d.changed).join(", ");
    const granted = asArray(d.granted_terms);
    const head = `the ${step} glossary_check record is older than its inputs (changed: ${changed}). run: ${run}; `;
    if (granted.length === 0) return `${head}then complete the step again.`;
    if (d.carry === "possible") {
      return `${head}the grants for ${termsText(granted)} carry over when their variants did not change; then complete the step again.`;
    }
    return `${head}the grants for ${termsText(granted)} lapse on that record because ${changed} changed: fix each finding, or ` +
      `${granted.map((t) => reacceptText(t, step, "hint")).join("; or ")}; then complete the step again.`;
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

// expired_grants is written once a record has a fingerprinted predecessor or holds an entry; a
// first record keeps the pre-#2909 shape (readers take a missing field as none).
function expiredField(prev, carry, open) {
  const list = retainedExpired(prev.expired_grants, carry.expired, open);
  return typeof prev.fingerprint === "string" || list.length > 0 ? { expired_grants: list } : {};
}

const variantsOf = (findings, norm) => asArray(findings).filter((f) => f && f.norm === norm).map((f) => f.variant);
const entriesOf = (blocked, norm) => asArray(blocked).filter((b) => b && b.norm === norm)
  .map((b) => JSON.stringify([b.term, b.operation, b.category, b.definition === undefined ? null : b.definition]));

// checkRecordEvents(current, step, fpResult, findings, origin) -> [step_annotation event].
// current: the step's previous glossary_check value (or null). Grants survive at the same
// fingerprint, or move to the new one when only the artifact or the rules changed and the granted
// norm shows no variant it did not show before; any other grant of the old fingerprint goes to
// expired_grants (grant-carry.js). ledger_grants are bound to a concern and always carry.
function checkRecordEvents(current, step, fpResult, findings, origin) {
  const prev = current || {};
  const next = asArray(findings).map((f) => ({
    source: "deterministic", class: "spelling", term: f.term, norm: f.norm, variant: f.variant, where: f.where,
  }));
  const r = grantCarry(prev, fpResult, CARRY_ROLES.check, variantsOf, prev.findings, next, (n) => termIn(prev.findings, n));
  const grants = sameFp(prev.grants, fpResult.fingerprint).concat(r.carried);
  const open = next.filter((f) => !grants.some((g) => g && g.norm === f.norm));
  const value = Object.assign({
    v: 1, step, fingerprint: fpResult.fingerprint, inputs: fpResult.inputs, findings: next, grants,
    ledger_grants: asArray(prev.ledger_grants),
  }, expiredField(prev, r, open));
  return [annotation(step, RECORD_KEY, value, origin || "check-glossary-drift")];
}

// provenanceRecordEvents(current, fpResult, sessionSource, unmatched, origin) -> [event].
// unmatched: every operation the intent does not cover, before grants ({ term, norm, operation,
// category, reason, definition }). blocked is what no grant covers. A grant moves to the new
// fingerprint when only ops or rules changed and its norm's unmatched entries (definition included)
// did not grow or change, else it goes to expired_grants; a record written before #2770 has no
// unmatched, so its blocked stands in.
function provenanceRecordEvents(current, fpResult, sessionSource, unmatched, origin) {
  const prev = current || {};
  const all = asArray(unmatched);
  const before = Array.isArray(prev.unmatched) ? prev.unmatched : prev.blocked;
  const r = grantCarry(prev, fpResult, CARRY_ROLES.provenance, entriesOf, before, all, (n) => termIn(before, n));
  const grants = sameFp(prev.grants, fpResult.fingerprint).concat(r.carried);
  const blocked = all.filter((b) => !grants.some((g) =>
    g && g.norm === b.norm && g.operation === b.operation && g.category === b.category));
  const value = Object.assign({
    v: 1, fingerprint: fpResult.fingerprint, inputs: fpResult.inputs, session_source: sessionSource,
    blocked, unmatched: all, grants,
  }, expiredField(prev, r, blocked));
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
  if (!GLOSSARY_STEPS.includes(step)) return { ok: true };
  const fail = (code, detail) => ({ ok: false, code, detail: Object.assign({ recovery: recoveryFor(sid, step, code, detail) }, detail) });
  const scopeOpts = { repoDir: o.repoDir, ruleModules: o.ruleModules };
  let loaded = null;
  if (o.mode === "commit" && RS_STEPS.includes(step)) {
    loaded = loadStepInputs(sid, step, scopeOpts);
    if (loaded.ok && loaded.artifact.empty) return { ok: true };
  }
  const rec = recordOf(projection, step);
  if (!rec || typeof rec.fingerprint !== "string" || rec.fingerprint === "") return fail("glossary-check-missing", {});
  const now = fingerprintOf(loaded || loadStepInputs(sid, step, scopeOpts));
  if (!now.ok) return fail("glossary-fingerprint-unavailable", { error: now.error, cause: now.detail || null });
  if (now.fingerprint !== rec.fingerprint) {
    const changed = changedComponents(rec.inputs, now.inputs);
    return fail("glossary-check-stale", Object.assign({ changed }, staleOutlook(rec, changed, CARRY_ROLES.check)));
  }
  const grants = sameFp(rec.grants, rec.fingerprint);
  const open = asArray(rec.findings).filter((f) => !grants.some((g) => g.norm === f.norm));
  if (open.length > 0) {
    const expired = asArray(rec.expired_grants).filter((e) => e && open.some((f) => f.norm === e.norm));
    return fail("glossary-findings-unresolved", { findings: open, expired });
  }
  return { ok: true };
}

const statusOf = (proj, step) => {
  const entry = proj && proj.steps && proj.steps[step];
  return (entry && entry.status) || "pending";
};

// glossaryRefusalOfComplete(sid, step, projection, opts) -> the evaluateGlossaryCheck refusal code
// (stale / findings-unresolved / fingerprint-unavailable) of a plan step (R-A) recorded complete
// with a glossary_check record, else null. A complete with no record, or a record without a
// fingerprint (recorded before #2529), is legacy and left complete. R-S steps: the commit gate.
function glossaryRefusalOfComplete(sid, step, projection, opts) {
  const err = glossaryRefusalErrorOfComplete(sid, step, projection, opts);
  return err ? err.code : null;
}

// glossaryRefusalErrorOfComplete(...) -> the same refusal as a GlossaryCheckIncompleteError
// (code + recovery text), for a writer that must word it; null when the complete stands.
function glossaryRefusalErrorOfComplete(sid, step, projection, opts) {
  const o = opts || {};
  if (!RA_STEPS.includes(step) || statusOf(projection, step) !== "complete") return null;
  const rec = recordOf(projection, step);
  if (!rec || typeof rec.fingerprint !== "string" || rec.fingerprint === "") return null;
  const v = evaluateGlossaryCheck(sid, step, projection, { mode: "boundary", repoDir: o.repoDir, ruleModules: o.ruleModules });
  return v.ok ? null : new GlossaryCheckIncompleteError(step, v.code, v.detail && v.detail.recovery);
}

// glossaryBoundaryForBatch(sid, prev, next, opts): throws GlossaryCheckIncompleteError when a
// glossary step moves to complete in this batch without a valid record.
function glossaryBoundaryForBatch(sid, prevProjection, nextProjection, opts) {
  const o = opts || {};
  if (SKIP_TOKENS.includes(o.sanctioned)) return;
  for (const step of GLOSSARY_STEPS) {
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
