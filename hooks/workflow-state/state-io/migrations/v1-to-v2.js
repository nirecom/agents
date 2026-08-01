"use strict";

// Stage 2 of the state-file migration chain: the keyed v1 `steps` map and the
// timestamped v1 top-level facts become an append-only v2 event stream (#1733).
//
// The conversion is a PURE function of its input — no clock, no randomness, no
// filesystem — so two processes migrating the same file agree byte-for-byte and
// `seq` stays a shared identifier for the same event.

const { applyV1FieldBackfill } = require("./v1-field-backfill");
const { STEP_ANNOTATION_KEYS } = require("../events");

const ORIGIN = "migration-v1-to-v2";

// Fields of a v1 step entry that are structure, not annotation. `started_at`
// (retired with #1640) is deliberately in this list: it is dropped, not carried.
const ENTRY_META_KEYS = ["status", "updated_at", "started_at"];

// Deterministic annotation order for one step entry: known keys in
// STEP_ANNOTATION_KEYS order, then everything else alphabetically. Shared with
// session inheritance so the two can never drift (CPR-4).
function orderedAnnotationKeys(entry) {
  if (!entry || typeof entry !== "object") return [];
  const known = [];
  const unknown = [];
  for (const key of Object.keys(entry)) {
    if (ENTRY_META_KEYS.includes(key)) continue;
    if (STEP_ANNOTATION_KEYS.includes(key)) known.push(key);
    else unknown.push(key);
  }
  known.sort((a, b) => STEP_ANNOTATION_KEYS.indexOf(a) - STEP_ANNOTATION_KEYS.indexOf(b));
  unknown.sort();
  return known.concat(unknown);
}

// --- BEGIN temporary: verdict(opus|sonnet) -> level(high|low) migration ---
// Pre-#1733 state files recorded the complexity call as `verdict` (a model name).
// The v2 vocabulary records `level`; translating here is what keeps the legacy
// value alive, since after migration `level` is always present and the reader-side
// shim in skip-signal-resolver.js can no longer recognise the legacy shape.
// An unknown legacy verdict maps to null so validation rejects it (fail-open).
const LEGACY_VERDICT_TO_LEVEL = { opus: "high", sonnet: "low" };

function complexityLevel(complexity) {
  if (!("level" in complexity) && typeof complexity.verdict === "string") {
    const mapped = LEGACY_VERDICT_TO_LEVEL[complexity.verdict];
    return mapped === undefined ? null : mapped;
  }
  return complexity.level !== undefined ? complexity.level : null;
}
// --- END temporary: verdict(opus|sonnet) -> level(high|low) migration ---

function innerRecordedAt(value) {
  if (value && typeof value === "object" && !Array.isArray(value) && typeof value.recorded_at === "string") {
    return value.recorded_at;
  }
  return null;
}

// One v1 step entry -> the events it becomes, in emission order.
function convertV1AnnotationsToEvents(step, entry, opts = {}) {
  const createdAt = opts.createdAt || null;
  const hasTimestamp = typeof entry.updated_at === "string" && entry.updated_at.length > 0;
  const statusAt = hasTimestamp ? entry.updated_at : createdAt;
  const events = [];

  for (const key of orderedAnnotationKeys(entry)) {
    const value = entry[key];
    const recordedAt = innerRecordedAt(value);
    const event = {
      kind: "step_annotation",
      step,
      key,
      value: value === undefined ? null : value,
      at: recordedAt || statusAt,
      // An inner recorded_at is a real observation; without one the timestamp is
      // whatever the entry carried, and with neither it is reconstructed.
      provenance: recordedAt || hasTimestamp ? "observed" : "backfilled",
      origin: ORIGIN,
    };
    if (!recordedAt && !hasTimestamp) event.at_estimated = true;
    events.push(event);
  }
  return events;
}

function stepIndex(step) {
  const { VALID_STEPS } = require("../core");
  const i = VALID_STEPS.indexOf(step);
  return i === -1 ? VALID_STEPS.length : i;
}

function sortGroups(groups) {
  return groups
    .map((g, i) => ({ g, i }))
    .sort((a, b) => {
      const at = String(a.g.at || "");
      const bt = String(b.g.at || "");
      if (at !== bt) return at < bt ? -1 : 1;
      // Within one instant: reconstructed timestamps first (they are the least
      // precise, so they belong at the head of the group they were folded into).
      if (a.g.estimated !== b.g.estimated) return a.g.estimated ? -1 : 1;
      if (a.g.rank !== b.g.rank) return a.g.rank - b.g.rank;
      if (a.g.stepIndex !== b.g.stepIndex) return a.g.stepIndex - b.g.stepIndex;
      return a.i - b.i;
    })
    .map((x) => x.g);
}

// migrateV1ToV2(v1State) -> a fresh v2 state object. `v1State` is never mutated.
function migrateV1ToV2(v1State) {
  const src = applyV1FieldBackfill(JSON.parse(JSON.stringify(v1State)));
  const createdAt =
    typeof src.created_at === "string" && src.created_at ? src.created_at : "1970-01-01T00:00:00.000Z";

  const groups = [];

  // ── step entries ──────────────────────────────────────────────────────────
  const steps = src.steps && typeof src.steps === "object" ? src.steps : {};
  const { VALID_STEPS, VALID_STATUSES } = require("../core");
  for (const step of Object.keys(steps)) {
    // This migration is the ONE event producer that does not run through
    // validateEvent, so it must not emit anything validateEvent would later
    // reject: a v1 file may be hand-edited, or written by a future release with
    // a wider vocabulary. An unknown step is dropped rather than folded into the
    // projection, where it would leak into consumers that scan Object.values().
    if (!VALID_STEPS.includes(step)) continue;
    const entry = steps[step] && typeof steps[step] === "object" ? steps[step] : {};
    const annotationKeys = orderedAnnotationKeys(entry);
    const hasTimestamp = typeof entry.updated_at === "string" && entry.updated_at.length > 0;
    const isPending = entry.status === "pending" || entry.status === undefined || entry.status === null;

    // An entry that says nothing beyond the projection default carries no
    // information: dropping it keeps the stream free of no-op events.
    if (isPending && !hasTimestamp && annotationKeys.length === 0) continue;

    const statusAt = hasTimestamp ? entry.updated_at : createdAt;
    const events = [];
    // An out-of-vocabulary status emits nothing: leaving the step at the
    // projection default (`pending`) is recoverable, whereas a stream that
    // assertStreamIntegrity rejects wedges the file with no in-band repair.
    const emitStatus =
      !(isPending && !hasTimestamp) && VALID_STATUSES.includes(entry.status);
    if (emitStatus) {
      const statusEvent = {
        kind: "step_status",
        step,
        status: entry.status,
        at: statusAt,
        provenance: hasTimestamp ? "observed" : "backfilled",
        origin: ORIGIN,
      };
      if (!hasTimestamp) statusEvent.at_estimated = true;
      events.push(statusEvent);
    }

    const annotationEvents = convertV1AnnotationsToEvents(step, entry, { createdAt });
    for (const e of annotationEvents) events.push(e);

    let groupAt = statusAt;
    if (!emitStatus) {
      groupAt = null;
      for (const e of annotationEvents) {
        if (groupAt === null || String(e.at) < String(groupAt)) groupAt = e.at;
      }
      if (groupAt === null) groupAt = createdAt;
    }
    groups.push({
      at: groupAt,
      estimated: emitStatus ? !hasTimestamp : false,
      rank: 1,
      stepIndex: stepIndex(step),
      events,
    });
  }

  // ── timestamped top-level facts ───────────────────────────────────────────
  const fact = (at, event) => {
    groups.push({ at, estimated: false, rank: 0, stepIndex: -1, events: [event] });
  };

  if (typeof src.worktree_entered_at === "string") {
    fact(src.worktree_entered_at, {
      kind: "worktree",
      transition: "entered",
      git_branch: src.git_branch !== undefined ? src.git_branch : null,
      cwd: src.cwd !== undefined ? src.cwd : null,
      // v1 never recorded which path was entered or where the path came from.
      worktree_path: null,
      path_source: "migration-unknown",
      at: src.worktree_entered_at,
      provenance: "backfilled",
      origin: ORIGIN,
    });
  }
  if (typeof src.worktree_exited_at === "string") {
    fact(src.worktree_exited_at, {
      kind: "worktree",
      transition: "exited",
      git_branch: src.git_branch !== undefined ? src.git_branch : null,
      cwd: src.cwd !== undefined ? src.cwd : null,
      worktree_path: null,
      path_source: "migration-unknown",
      at: src.worktree_exited_at,
      provenance: "backfilled",
      origin: ORIGIN,
    });
  }

  const model = src.session_model;
  if (model && typeof model === "object") {
    const at = typeof model.recorded_at === "string" ? model.recorded_at : createdAt;
    fact(at, {
      kind: "session_model",
      id: model.id !== undefined ? model.id : null,
      source: model.source !== undefined ? model.source : null,
      at,
      provenance: "backfilled",
      origin: ORIGIN,
    });
  }

  const complexity = src.complexity_evaluation;
  if (complexity && typeof complexity === "object") {
    // A v1 blob with no recorded_at never carried an observation timestamp;
    // fabricating one would make "no evaluation was ever recorded" (which callers
    // read as fail-open) indistinguishable from "recorded at the epoch". The event
    // keeps `at` null while group ordering falls back to created_at.
    const recordedAt = typeof complexity.recorded_at === "string" ? complexity.recorded_at : null;
    groups.push({
      at: recordedAt || createdAt,
      estimated: false,
      rank: 0,
      stepIndex: -1,
      events: [
        {
          kind: "complexity_evaluation",
          level: complexityLevel(complexity),
          signals: Array.isArray(complexity.signals) ? complexity.signals : [],
          at: recordedAt,
          provenance: "backfilled",
          origin: ORIGIN,
        },
      ],
    });
  }

  const approvals = src.plan_approvals;
  if (approvals && typeof approvals === "object") {
    for (const step of Object.keys(approvals).sort()) {
      if (!VALID_STEPS.includes(step)) continue; // same reason as the steps loop
      const approval = approvals[step] || {};
      const at = typeof approval.recorded_at === "string" ? approval.recorded_at : createdAt;
      groups.push({
        at,
        estimated: false,
        rank: 0,
        stepIndex: stepIndex(step),
        events: [
          {
            kind: "plan_approval",
            step,
            source: approval.source !== undefined ? approval.source : null,
            reason: approval.reason !== undefined ? approval.reason : null,
            artifact_sha256: approval.artifact_sha256 !== undefined ? approval.artifact_sha256 : null,
            artifact_session_id:
              approval.artifact_session_id !== undefined ? approval.artifact_session_id : null,
            artifact_hash_status:
              approval.artifact_hash_status !== undefined ? approval.artifact_hash_status : null,
            at,
            provenance: "backfilled",
            origin: ORIGIN,
          },
        ],
      });
    }
  }

  const events = [];
  for (const group of sortGroups(groups)) {
    for (const event of group.events) {
      event.seq = events.length + 1;
      events.push(event);
    }
  }

  const result = { version: 2 };
  if (src.session_id !== undefined) result.session_id = src.session_id;
  result.created_at = createdAt;
  result.session_start_context = {
    cwd: src.cwd !== undefined ? src.cwd : null,
    git_branch: src.git_branch !== undefined ? src.git_branch : null,
  };
  if (src.workflow_type !== undefined) result.workflow_type = src.workflow_type;
  if (src.closes_issues !== undefined) result.closes_issues = src.closes_issues;
  if (src.last_pushed_sha !== undefined) result.last_pushed_sha = src.last_pushed_sha;
  if (src.session_worktree !== undefined) result.session_worktree = src.session_worktree;
  if (src.verbose_prompt !== undefined) result.verbose_prompt = src.verbose_prompt;
  result.events = events;
  return result;
}

module.exports = { migrateV1ToV2, orderedAnnotationKeys, convertV1AnnotationsToEvents };
