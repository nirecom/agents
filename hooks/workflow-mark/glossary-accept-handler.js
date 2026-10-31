"use strict";
// Issue #2529 — WORKFLOW_GLOSSARY_ACCEPTED.
//
//   echo "<<WORKFLOW_GLOSSARY_ACCEPTED: term=<term>[ op=<op>][ cat=<cat>][ stage=<stage>] — <reason>>>"
// Records the user's grant for one glossary term against what is pending for it: (a) an open
// deterministic finding of every stage holding one (stage= narrows to that stage), (b) a glossary
// provenance check block, (c) an open tagged concern of the ledger of a target stage or the current
// stage. Never completes a step. The target stages, fingerprints and ledger lists are computed
// before the lock; the builder reads neither the current step nor the profile, so a refusal never
// depends on what step the in-lock view resolves to. A refusal names its reason in the notice.

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

// The current stage joins the open-finding stages so its ledger concerns (c) count before it has a record.
function targetStages(state, sid, norm, disc) {
  if (disc.op || disc.cat) return [];
  if (disc.stage) return [disc.stage];
  const current = stageOf(state, sid);
  return Object.keys(STAGE_STEP).filter((s) => s === current ||
    openFindings(stepOf(state, STAGE_STEP[s])[RECORD_KEY], norm).length > 0);
}

// Pre-lock reads per target stage: (a)'s recomputed fingerprint and (c)'s ledger list.
function prepare(sid, norm, disc) {
  const state = readState(sid);
  const targets = targetStages(state, sid, norm, disc).map((stage) => ({
    stage,
    fp: openFindings(stepOf(state, STAGE_STEP[stage])[RECORD_KEY], norm).length > 0 ? stageFingerprint(sid, stage) : null,
    ledger: STAGE_LEDGER_FORMAT[stage] ? listDrift(sid, STAGE_LEDGER_FORMAT[stage]) : null,
  }));
  return { targets };
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

// grantStage(current, sid, norm, disc, reason, t, v) -> the stage's record annotation | null.
// Runs in the lock against the record as it is now, so a record rewritten since prepare() is refused.
function grantStage(current, sid, norm, disc, reason, t, v) {
  const { stage } = t;
  const step = STAGE_STEP[stage];
  const rec = stepOf(current, step)[RECORD_KEY] || null;
  const next = rec ? Object.assign({}, rec) : { v: 1, stage };
  const rerun = `re-run check-glossary-drift --session ${sid} --stage ${stage} --record`;
  const noted = v.notes.length;
  let changed = false;
  if (rec && openFindings(rec, norm).length > 0) {
    if (t.fp && t.fp.ok && t.fp.fingerprint === rec.fingerprint) {
      next.grants = asArray(rec.grants).concat([{ norm, fingerprint: rec.fingerprint, reason }]);
      changed = true;
      v.granted.push(`finding at ${stage}`);
    } else if (t.fp && !t.fp.ok) {
      v.notes.push(`the ${stage} glossary_check inputs could not be read (${t.fp.error}) — ${rerun}`);
    } else {
      v.notes.push(`the ${stage} glossary_check record is older than its inputs — ${rerun}`);
    }
  }
  if (STAGE_LEDGER_FORMAT[stage] && t.ledger === null) v.notes.push(`the ${stage} concern ledger could not be listed`);
  const have = asArray(next.ledger_grants);
  const add = asArray(t.ledger).filter((c) => c.norm === norm && !have.some((g) => g && g.norm === norm && g.discrim === c.discrim))
    .filter((c, i, all) => all.findIndex((x) => x.discrim === c.discrim) === i)
    .map((c) => ({ norm, discrim: c.discrim, reason }));
  if (add.length > 0) {
    next.ledger_grants = have.concat(add);
    changed = true;
    v.granted.push(`ledger concern(s) ${add.map((g) => g.discrim).join(", ")} at ${stage}`);
  }
  if (disc.stage && !changed && v.notes.length === noted) {
    v.notes.push(`stage=${stage} has no open finding and no open tagged concern for this term`);
  }
  return changed ? annotation(step, RECORD_KEY, next) : null;
}

function grant(sid, term, disc, reason) {
  const norm = normalizeTerm(term);
  const pre = prepare(sid, norm, disc);
  const v = { granted: [], notes: [] };
  appendEvents(sid, (_events, current) => {
    v.granted = [];
    v.notes = [];
    const events = [];
    for (const t of pre.targets) {
      const ev = grantStage(current, sid, norm, disc, reason, t, v);
      if (ev) events.push(ev);
    }
    const prov = stepOf(current, PROVENANCE_STEP)[PROVENANCE_KEY] || null;
    const pg = grantProvenance(prov, norm, disc, reason);
    if (pg.length > 0) {
      events.push(annotation(PROVENANCE_STEP, PROVENANCE_KEY, Object.assign({}, prov, { grants: asArray(prov.grants).concat(pg) })));
      v.granted.push(pg.map((g) => `provenance ${g.operation} ${g.category}`).join(", "));
    }
    return events;
  });
  // Here, not in the builder: the builder empties `v` on every re-run.
  if (v.granted.length === 0 && v.notes.length === 0) {
    v.notes.push(disc.op || disc.cat ? "no glossary_provenance block matches this term with the given op= / cat="
      : "no stage holds an open finding or an open tagged concern for this term, and no glossary_provenance block names it");
  }
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
