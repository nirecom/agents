"use strict";
// hooks/lib/jev/two-stage/query.js — `jev-judge query` (#2460): freeze the point's policy,
// take the stage's owner marker, build the Jev input and copy the stage sources (the Jev input
// names the copies only; SOURCES_DIR says where they are), ask Jev only when the CLI owns the
// record and the required sections are whole, gate the answers, and leave the cli-ticket for finalize.
// The test overrides are captured before anything below can load .env into process.env.
const { captureTestOverrides } = require("../test-overrides");
const ENTRY_OVERRIDES = captureTestOverrides(process.env);

const fs = require("fs");
const path = require("path");

const broker = require("../broker");
const provider = require("../provider-core");
const pending = require("../pending");
const { registryEntry, recordingOwner } = require("../registry");
const { isValidId } = require("../state-paths");
const { applyGate } = require("./gate");
const { takeSignalsOwnerAtQuery } = require("./settle-complexity");
const { takeSkipOwnerAtQuery } = require("./settle-skip");
const { buildJevInput, answerPath } = require("./jev-input");
const { TICKET_RE, sha256, newTicketId, removeSources, pointStageEntry, slashed } = require("./paths");
const { requiredSectionsStatus } = require(path.join(__dirname, "..", "..", "..", "..", "bin", "workflow", "lib", "jev-request-common.js"));

const DET_PATH = path.join(__dirname, "..", "..", "..", "workflow-state", "complexity-routing", "deterministic-signals.js");
const WRITE_CODE_LIST = "write-code files";

// The policy every later step of this ticket uses instead of the registry (query-time freeze).
function freezePolicy(entry) {
  const owner = recordingOwner(entry);
  return {
    mode: entry.mode, recording_owner: owner, record_decision: broker.isEnabled() && owner === "cli",
    threshold: Object.assign({}, entry.confidence_threshold_by_answer),
    short_circuit_answer: entry.short_circuit_answer === undefined ? null : entry.short_circuit_answer,
    backup_subagent: entry.backup_subagent, fallback: entry.fallback, adapter: entry.adapter,
  };
}

// The stage's owner marker is taken before anything is read or asked: from here on an older
// judgment still in flight can no longer settle, however long this query takes. Throws on failure.
function takeOwnerAtQuery(sid, stage, entry, owner) {
  if (entry.target) takeSkipOwnerAtQuery(sid, entry.target, owner);
  else takeSignalsOwnerAtQuery(sid, stage, owner);
}

// S1b / S4 from the verified write-code list copy only (null outside the deterministic stage).
function deterministicFor(jevInput, stage, adapter, repoRoot) {
  if (!adapter.deterministicStage || stage !== adapter.deterministicStage) return null;
  const det = (status, extra) => Object.assign({ status, values: null, source_sha256: null, override: [] }, extra);
  if (jevInput.sources_failed.includes(WRITE_CODE_LIST)) return det("copy-failed");
  const copy = jevInput.copies[WRITE_CODE_LIST];
  if (!copy) return det("missing");
  let bytes;
  try { bytes = fs.readFileSync(copy.path); } catch (_e) { return det("copy-failed"); }
  if (sha256(bytes) !== copy.sha256) return det("copy-failed");
  const { parseWriteCodeFiles, computeDeterministic } = require(DET_PATH);
  const list = parseWriteCodeFiles(bytes, repoRoot || null);
  if (list.status !== "ok") return det(list.status, { source_sha256: copy.sha256 });
  return det("ok", { values: computeDeterministic(list), source_sha256: copy.sha256 });
}

// {key: {p}} from the broker's per-signal probabilities, keyed as the adapter asks.
function itemsFrom(jev, adapter, keys) {
  const items = {};
  const probs = jev && jev.probabilities ? jev.probabilities : {};
  const byKey = {};
  for (const id of Object.keys(probs)) byKey[typeof adapter.questionKey === "function" ? adapter.questionKey(id) : id] = probs[id];
  for (const k of keys) items[k] = { p: Object.prototype.hasOwnProperty.call(byKey, k) ? byKey[k] : null };
  return items;
}

function allDelegated(keys) {
  return { adopted: {}, delegated: keys.slice(), unjudged: [], short_circuited: false, result: keys.length ? "need-subagent" : "final" };
}

// Jev is asked only when the CLI records and the required sections are whole; any other path
// (or a Jev failure) delegates every key. A CLI-owned shadow point keeps Jev for the record only.
async function judge(ctx) {
  const { point, entry, sid, jevInput, frozen, keys, adapter, req, overrides } = ctx;
  if (!frozen.record_decision || !req.met) return { jev: broker.jevResult("not-run"), gate: allDelegated(keys) };
  let jev;
  try {
    const pctx = provider.jevCoreInit({ sessionId: sid, overrides });
    jev = await broker.runJev(point, pctx, sid, { state: jevInput.text }, entry);  } catch (_e) {
    jev = broker.jevResult("bad-response");
  }
  if (jev.status !== "ok" || frozen.mode === "shadow") return { jev, gate: allDelegated(keys) };
  // decidesAtStage reads the hits as signals that hold, so it only judges a true short circuit;
  // any other short-circuit answer stays value-based (the registry data alone decides).
  const hooks = typeof adapter.decidesAtStage === "function" && frozen.short_circuit_answer === true
    ? { decides: (ks) => adapter.decidesAtStage(ctx.stage, ks) } : undefined;
  const gate = applyGate(itemsFrom(jev, adapter, keys), {
    confidence_threshold_by_answer: frozen.threshold, short_circuit_answer: frozen.short_circuit_answer,
  }, hooks);
  return { jev, gate };
}

// SOURCES_DIR is where the copies named in the Jev input header are: the Jev input itself is
// sent to Jev, so it never carries a local path.
function stdoutFor(frozen, tid, gate, jevInput, answerFile) {
  const need = gate.delegated.length > 0;
  return [
    `RESULT=${need ? "need-subagent" : "final"}`,
    `TICKET=${tid}`,
    `SUBAGENT=${need ? frozen.backup_subagent : "-"}`,
    `DELEGATED=${need ? gate.delegated.join(",") : "-"}`,
    `JEV_INPUT_FILE=${slashed(jevInput.file)}`,
    `ANSWER_FILE=${need ? slashed(answerFile) : "-"}`,
    `SOURCES_DIR=${need ? slashed(jevInput.sources_dir) : "-"}`,
  ];
}

function inputOf(jevInput, req, required) {
  return {
    bytes: Buffer.byteLength(jevInput.text), sha256: jevInput.sha256, truncated: jevInput.truncated,
    sources: jevInput.included.slice(), sections: jevInput.included.slice(), required: required.slice(),
    missing: req.missing.slice(), exempt: req.exempt.slice(), sources_failed: jevInput.sources_failed.slice(),
    sources_failed_reasons: Object.assign({}, jevInput.sources_failed_reasons),
  };
}

// query(args, opts) -> {exit, stdout_lines}. args: {sid|session, point, stage, repoRoot?};
// opts (module API only, also read from args): resolveEntry, ticketId, failCopyFor, afterCopy,
// maxArtifactBytes, overrides.
async function query(args, optsArg = {}) {
  const a = args || {};
  const opts = Object.assign({}, a, optsArg);
  const sid = a.sid || a.session || a.sessionId;
  const resolveEntry = typeof opts.resolveEntry === "function" ? opts.resolveEntry : registryEntry;
  const entry = isValidId(sid) ? pointStageEntry(a.point, a.stage, resolveEntry) : null;
  if (!entry) return { exit: 2, stdout_lines: [] };
  const tid = typeof opts.ticketId === "string" && TICKET_RE.test(opts.ticketId) ? opts.ticketId : newTicketId();
  const createdMs = Date.now();
  const frozen = freezePolicy(entry);
  const required = (entry.required_sections_by_stage && entry.required_sections_by_stage[a.stage]) || [];
  const planSections = (entry.plan_sections_by_stage && entry.plan_sections_by_stage[a.stage]) || [];
  let jevInput;
  try {
    takeOwnerAtQuery(sid, a.stage, entry, { id: tid, created_ms: createdMs });
    jevInput = buildJevInput(sid, a.stage, tid, required, {
      maxArtifactBytes: opts.maxArtifactBytes, failCopyFor: opts.failCopyFor, afterCopy: opts.afterCopy, repoRoot: a.repoRoot,
      planSections,
    });
  } catch (_e) {
    removeSources(sid, tid);
    return { exit: 3, stdout_lines: [] };
  }
  let adapter = null;
  let keys = [];
  let deterministic = null;
  let req = { met: false, missing: required.concat(planSections), exempt: [] };
  let judged;
  try {
    adapter = require(entry.adapter);
    keys = adapter.keys(entry);
    deterministic = deterministicFor(jevInput, a.stage, adapter, a.repoRoot);
    req = requiredSectionsStatus(sid, required, jevInput.sections, jevInput.sources_failed, planSections);
    judged = await judge({
      point: a.point, stage: a.stage, entry, sid, jevInput, frozen, keys, adapter, req,
      overrides: opts.overrides || ENTRY_OVERRIDES,
    });
  } catch (_e) {
    judged = { jev: broker.jevResult("not-run"), gate: allDelegated(keys) };
  }
  if (!adapter) {
    removeSources(sid, tid);
    return { exit: 3, stdout_lines: [] };
  }
  const gate = judged.gate;
  const answerFile = answerPath(sid, tid);
  const ticket = Object.assign({
    kind: "cli-ticket", point: a.point, stage: a.stage, session_id: sid, ticket: tid, created_ms: createdMs,
  }, entry.target ? { target: entry.target } : {}, frozen, {
    short_circuited: gate.short_circuited, unjudged: gate.unjudged, required, missing: req.missing, exempt: req.exempt,
    sources_failed: jevInput.sources_failed, sources_failed_reasons: jevInput.sources_failed_reasons,
    deterministic, jev: judged.jev, adopted_jev: gate.adopted, delegated: gate.delegated,
    llm_needed: gate.delegated.length > 0, input_insufficient: !req.met,
    jev_input_file: jevInput.file, jev_input_sha256: jevInput.sha256, sources: jevInput.sources, sources_sha256: jevInput.sources_sha256,
    artifacts_sha256: jevInput.artifacts_sha256, answer_file: answerFile, repo_root: a.repoRoot || null, input: inputOf(jevInput, req, required),
  });
  try {
    pending.writePending(sid, tid, ticket);
  } catch (_e) {
    removeSources(sid, tid);
    return { exit: 3, stdout_lines: [] };
  }
  return { exit: 0, stdout_lines: stdoutFor(frozen, tid, gate, jevInput, answerFile) };
}

module.exports = { query, runQuery: query, freezePolicy, deterministicFor };
