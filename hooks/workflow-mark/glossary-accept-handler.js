"use strict";
// Issue #2529 — WORKFLOW_GLOSSARY_ACCEPTED.
//
//   echo "<<WORKFLOW_GLOSSARY_ACCEPTED: term=<term>[ op=<op>][ cat=<cat>][ stage=<stage>] — <reason>>>"
// Records the user's grant for one glossary term against what is pending for it: (a) an open
// deterministic finding of the current stage, (b) a glossary provenance check block, (c) an open tagged
// concern of the current stage's ledger. Never completes a step. The fingerprint and the
// ledger list are computed before the lock; the decision and the write share one builder.

const path = require("path");
const { spawnSync } = require("child_process");
const { GLOSSARY_ACCEPTED_RE_DQ, GLOSSARY_ACCEPTED_LOOKSLIKE_RE } = require("../lib/sentinel-patterns");
const { appendEvents, readState } = require("../workflow-state/state-io");
const { resolveCurrentStep } = require("../workflow-state/current-step");
const { resolveSessionProfile } = require("../workflow-state/session-profile");
const { sanitizeLine } = require("../lib/output-sanitize");
const { normalizeTerm } = require("../lib/glossary-term");
const { toWindowsPath } = require("../lib/branch-diff");
const { getWorkflowPlansDir } = require("../lib/workflow-plans-dir");
const { STAGE_STEP, STAGE_LEDGER_FORMAT, stageOfStep, stageFingerprint } = require("../workflow-state/glossary-check/scope");
const { RECORD_KEY, PROVENANCE_KEY, PROVENANCE_STEP } = require("../workflow-state/glossary-check/record");

const LABEL = "GLOSSARY_ACCEPTED";
const ORIGIN = "workflow-mark-glossary-accept";
const FORM = "echo \"<<WORKFLOW_GLOSSARY_ACCEPTED: term=<term> [op=<add|delete|redefine>] [cat=<user|internal>] [stage=<stage>] — <reason>>>\"";
const DOMAIN = { op: ["add", "delete", "redefine"], cat: ["user", "internal"], stage: Object.keys(STAGE_STEP) };
const LEDGER_CLI = path.join(__dirname, "..", "..", "bin", "concern-ledger");

const asArray = (v) => (Array.isArray(v) ? v : []);
const fwd = (p) => String(p).replace(/\\/g, "/");

// parseDiscriminators(" op=add cat=user") -> { disc } | { error }.
function parseDiscriminators(text) {
  const disc = {};
  for (const tok of String(text || "").trim().split(/\s+/).filter(Boolean)) {
    const [name, value] = tok.split("=");
    if (Object.prototype.hasOwnProperty.call(disc, name)) return { error: `duplicate ${name}=` };
    if (!DOMAIN[name] || !DOMAIN[name].includes(value)) return { error: `${tok} is outside the domain` };
    disc[name] = value;
  }
  if (disc.stage && (disc.op || disc.cat)) return { error: "op= / cat= cannot be combined with stage=" };
  return { disc };
}

function stageOf(state, sid) {
  if (!state || !state.steps) return null;
  return stageOfStep(resolveCurrentStep(state, { profile: resolveSessionProfile(state, sid), sessionId: sid }));
}

const stepOf = (state, step) => (state && state.steps && state.steps[step]) || {};
const openFindings = (rec, norm) => asArray(rec && rec.findings).filter((f) => f && f.norm === norm &&
  !asArray(rec.grants).some((g) => g && g.norm === norm && g.fingerprint === rec.fingerprint));

// listDrift(sid, format) -> [{ discrim, norm }] | null (list-drift failed: fail-closed).
function listDrift(sid, format) {
  const plans = fwd(toWindowsPath(getWorkflowPlansDir()));
  const r = spawnSync("bash", [fwd(LEDGER_CLI), "list-drift", "--plans-dir", plans, "--session-id", sid, "--format", format],
    { encoding: "utf8", timeout: 15000 });
  if (r.error || r.status !== 0) return null;
  return String(r.stdout || "").split(/\r?\n/).filter(Boolean).map((l) => {
    const [discrim, term] = l.split("\t");
    return { discrim, norm: normalizeTerm(term) };
  }).filter((x) => x.discrim && x.norm);
}

// Pre-lock reads: the stage, (a)'s recomputed fingerprint and (c)'s ledger list.
function prepare(sid, norm, disc) {
  const state = readState(sid);
  const stage = stageOf(state, sid);
  const scoped = stage && (!disc.stage || disc.stage === stage) && !disc.op && !disc.cat ? stage : null;
  const pre = { stage: scoped, fp: null, ledger: null };
  if (!scoped) return pre;
  if (openFindings(stepOf(state, STAGE_STEP[scoped])[RECORD_KEY], norm).length > 0) pre.fp = stageFingerprint(sid, scoped);
  if (STAGE_LEDGER_FORMAT[scoped]) pre.ledger = listDrift(sid, STAGE_LEDGER_FORMAT[scoped]);
  return pre;
}

function annotation(step, key, value) {
  return { kind: "step_annotation", step, key, value, provenance: "declared", origin: ORIGIN };
}

// grantProvenance(prov, norm, disc, reason) -> new grants (b).
function grantProvenance(prov, norm, disc, reason) {
  if (!prov || disc.stage) return [];
  const have = asArray(prov.grants);
  const out = [];
  for (const b of asArray(prov.blocked)) {
    const bn = b && (b.norm || normalizeTerm(b.term));
    if (bn !== norm || (disc.op && b.operation !== disc.op) || (disc.cat && b.category !== disc.cat)) continue;
    const g = { norm: bn, operation: b.operation, category: b.category, fingerprint: prov.fingerprint, reason };
    const dup = (x) => x && x.norm === g.norm && x.operation === g.operation && x.category === g.category && x.fingerprint === g.fingerprint;
    if (!have.some(dup) && !out.some(dup)) out.push(g);
  }
  return out;
}

function grant(sid, term, disc, reason) {
  const norm = normalizeTerm(term);
  const pre = prepare(sid, norm, disc);
  const v = { granted: [], notes: [] };
  appendEvents(sid, (_events, current) => {
    v.granted = [];
    v.notes = [];
    const events = [];
    const stage = pre.stage && stageOf(current, sid) === pre.stage ? pre.stage : null;
    if (stage) {
      const step = STAGE_STEP[stage];
      const rec = stepOf(current, step)[RECORD_KEY] || null;
      let next = rec ? Object.assign({}, rec) : { v: 1, stage };
      let changed = false;
      if (rec && openFindings(rec, norm).length > 0) {
        if (pre.fp && pre.fp.ok && pre.fp.fingerprint === rec.fingerprint) {
          next.grants = asArray(rec.grants).concat([{ norm, fingerprint: rec.fingerprint, reason }]);
          changed = true;
          v.granted.push(`finding at ${stage}`);
        } else {
          v.notes.push(`the ${stage} glossary_check record is older than its inputs — re-run ` +
            `check-glossary-drift --session ${sid} --stage ${stage} --record`);
        }
      }
      if (STAGE_LEDGER_FORMAT[stage] && pre.ledger === null) v.notes.push("the concern ledger could not be listed");
      const have = asArray(next.ledger_grants);
      const add = asArray(pre.ledger).filter((c) => c.norm === norm && !have.some((g) => g && g.norm === norm && g.discrim === c.discrim))
        .filter((c, i, all) => all.findIndex((x) => x.discrim === c.discrim) === i)
        .map((c) => ({ norm, discrim: c.discrim, reason }));
      if (add.length > 0) {
        next.ledger_grants = have.concat(add);
        changed = true;
        v.granted.push(`ledger concern(s) ${add.map((g) => g.discrim).join(", ")}`);
      }
      if (changed) events.push(annotation(step, RECORD_KEY, next));
    }
    const prov = stepOf(current, PROVENANCE_STEP)[PROVENANCE_KEY] || null;
    const pg = grantProvenance(prov, norm, disc, reason);
    if (pg.length > 0) {
      events.push(annotation(PROVENANCE_STEP, PROVENANCE_KEY, Object.assign({}, prov, { grants: asArray(prov.grants).concat(pg) })));
      v.granted.push(pg.map((g) => `provenance ${g.operation} ${g.category}`).join(", "));
    }
    return events;
  });
  return v;
}

function handle(ctx) {
  const { cmd, sessionId, pushMessage, signalFatal } = ctx;
  const m = cmd.match(GLOSSARY_ACCEPTED_RE_DQ);
  if (!m) {
    if (!GLOSSARY_ACCEPTED_LOOKSLIKE_RE.test(cmd)) return false;
    pushMessage(`workflow-mark: malformed WORKFLOW_${LABEL} — expected: ${FORM} ` +
      "<term> must not contain = ( ) ; | & > or a backtick; <reason> must not contain ( ) ; | & > or a backtick.");
    return true;
  }
  const term = sanitizeLine(m[1].trim());
  const reason = sanitizeLine(m[3].trim());
  const p = parseDiscriminators(m[2]);
  const why = p.error || (reason.replace(/\s/g, "").length < 3 ? "reason too short" : null);
  if (why) {
    pushMessage(`workflow-mark: malformed WORKFLOW_${LABEL} — ${why}; state unchanged. Expected: ${FORM}`);
    return true;
  }
  if (!sessionId) {
    signalFatal(`workflow-mark: could not resolve session_id — ${LABEL} NOT recorded.`);
    return true;
  }
  try {
    const v = grant(sessionId, term, p.disc, reason);
    const notes = v.notes.length > 0 ? ` (${v.notes.join("; ")})` : "";
    if (v.granted.length === 0) {
      pushMessage(`workflow-mark: ${LABEL} rejected — nothing pending for term "${term}"${notes}; state unchanged.`);
      return true;
    }
    pushMessage(`[workflow] ${LABEL}: grant recorded for "${term}" — ${v.granted.join("; ")}${notes}.`);
  } catch (e) {
    pushMessage(`workflow-mark: failed to write state — ${e.message}. ${LABEL} NOT recorded.`);
  }
  return true;
}

module.exports = { handle, parseDiscriminators };
