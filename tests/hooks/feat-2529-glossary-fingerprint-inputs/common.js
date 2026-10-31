"use strict";
// Shared steps of T7 (invariant I-FP): build a valid record + grant for one stage, change exactly
// one input, then require (i) only that input's digest moved, (ii) evaluateGlossaryCheck says
// glossary-check-stale naming only that component, (iii) the re-record drops the old grant —
// except an artifact-only change, whose re-record carries it (#2770) — and (iv) granting passes.

const F = require("../../lib/glossary-check-fixture");

const SCOPE = "hooks/workflow-state/glossary-check/scope.js";
const RECORD = "hooks/workflow-state/glossary-check/record.js";
const COMPONENTS = ["artifact", "glossary", "intent_rows", "rules"];

function modules() {
  const scope = F.mod(SCOPE);
  const record = F.mod(RECORD);
  return scope && record ? { scope, record } : null;
}

// The component names a stale detail mentions; the code name and CLI name are stripped first so
// "glossary-check-stale" does not count as naming the glossary input.
function named(detail) {
  if (detail && typeof detail === "object") {
    for (const k of ["changed", "components", "changed_inputs"]) {
      if (Array.isArray(detail[k])) return detail[k].slice().sort();
    }
  }
  const s = (typeof detail === "string" ? detail : JSON.stringify(detail == null ? "" : detail))
    .replace(/check-glossary-drift/g, " ")
    .replace(/glossary[-_ ]check(?:[-_ ](?:stale|missing|record))?/gi, " ");
  return COMPONENTS.filter((c) => new RegExp(`(^|[^A-Za-z0-9_/-])${c}([^A-Za-z0-9_/-]|$)`).test(s)).sort();
}

function fp(m, ctx, extra) {
  const r = m.scope.stageFingerprint(ctx.sid, ctx.stage, Object.assign({ repoDir: ctx.repo }, extra || {}));
  return r && r.ok ? r : { ok: false, fingerprint: null, inputs: {}, error: r && r.error };
}

function evaluate(m, ctx, extra) {
  return m.record.evaluateGlossaryCheck(ctx.sid, F.STAGE_STEP[ctx.stage], F.readState(ctx.sid),
    Object.assign({ repoDir: ctx.repo }, extra || {}));
}

const passes = (v) => !!v && v.ok === true;

// Records the stage through the CLI, grants every finding, and checks the pair passes.
function recordAndGrant(m, ctx, label) {
  F.drift(ctx.sid, ctx.stage, ctx.cwd || ctx.repo);
  const rec = F.recordOf(ctx.sid, ctx.stage);
  F.grantFindings(ctx.sid, ctx.stage);
  const v = evaluate(m, ctx);
  F.check(`${ctx.stage} ${label}: recorded + granted record passes`, passes(v), JSON.stringify({ v, rec }));
  return rec;
}

// A fresh stage whose artifact carries VARIANT (one spelling finding), recorded and granted.
function baseline(m, tag, stage, opts) {
  const s = F.setupStage(tag, stage, F.VARIANT, opts);
  const ctx = { sid: s.sid, repo: s.repo, stage };
  const rec = recordAndGrant(m, ctx, "baseline");
  F.check(`${stage} baseline: the record holds a finding to grant`,
    !!rec && Array.isArray(rec.findings) && rec.findings.length > 0, JSON.stringify(rec));
  return ctx;
}

// One change of one input. `expect` is the component (or list) whose digest must move.
function cycle(m, ctx, label, expect, mutate) {
  const want = [].concat(expect).sort();
  const name = `${ctx.stage} ${label}`;
  const before = fp(m, ctx);
  mutate();
  const after = fp(m, ctx);
  const moved = before.ok && after.ok ? COMPONENTS.filter((c) => before.inputs[c] !== after.inputs[c]) : null;
  F.check(`${name}: only ${want.join("+")} moves`, !!moved && moved.join(",") === want.join(","),
    JSON.stringify({ moved, before: before.error, after: after.error }));
  const v = evaluate(m, ctx);
  F.check(`${name}: evaluateGlossaryCheck is glossary-check-stale naming only ${want.join("+")}`,
    !!v && v.ok === false && v.code === "glossary-check-stale" && named(v.detail).join(",") === want.join(","),
    JSON.stringify(v));
  F.drift(ctx.sid, ctx.stage, ctx.cwd || ctx.repo);
  const rec = F.recordOf(ctx.sid, ctx.stage);
  if (want.join(",") === "artifact") {
    // #2770: an artifact-only change with the same variants carries the grant to the new fingerprint.
    const moved = rec && (rec.grants || []).filter((g) => g.fingerprint === rec.fingerprint);
    F.check(`${name}: the re-record carries the grant to the new fingerprint`,
      !!rec && rec.fingerprint === after.fingerprint && moved.length > 0 && moved.length === rec.grants.length,
      JSON.stringify(rec));
    F.check(`${name}: the re-record with the carried grant passes`, passes(evaluate(m, ctx)), "not ok");
    return;
  }
  const kept = rec && (rec.grants || []).filter((g) => g.fingerprint !== rec.fingerprint);
  F.check(`${name}: the re-record is current and carries no grant of the old fingerprint`,
    !!rec && rec.fingerprint === after.fingerprint && (rec.grants || []).length === 0 && kept.length === 0,
    JSON.stringify(rec));
  const u = evaluate(m, ctx);
  F.check(`${name}: the ungranted re-record is glossary-findings-unresolved`,
    !!u && u.ok === false && u.code === "glossary-findings-unresolved", JSON.stringify(u));
  F.grantFindings(ctx.sid, ctx.stage);
  F.check(`${name}: granting the re-record passes`, passes(evaluate(m, ctx)), "not ok");
}

// An input change that must not move the fingerprint nor stale the record.
function unchanged(m, ctx, label, mutate) {
  const before = fp(m, ctx);
  mutate();
  const after = fp(m, ctx);
  F.check(`${ctx.stage} ${label}: the fingerprint does not move`,
    before.ok && after.ok && before.fingerprint === after.fingerprint, JSON.stringify({ before, after }));
  F.check(`${ctx.stage} ${label}: the record stays current`, passes(evaluate(m, ctx)), "not ok");
}

// Wraps a part section so an entry file can run it alone; a no-op when scope.js/record.js are missing.
const withModules = (fn) => (...args) => {
  const m = modules();
  if (m) fn(m, ...args);
};

module.exports = { COMPONENTS, modules, withModules, named, fp, evaluate, passes, recordAndGrant, baseline, cycle, unchanged };
