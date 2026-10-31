"use strict";
// appendStateHandoffRecord — the one write entry for state_handoff_record events (#2652).
// Every producer (procedure-point CLI, gate-block, auto-record) comes through here, so the
// recording period, the budget and the redaction hold for every origin at once (CPR-ORTH).

const path = require("path");
const STATE_IO = path.join(__dirname, "..", "..", "workflow-state", "state-io");
const core = require(path.join(STATE_IO, "core"));
const { appendEvents } = require(path.join(STATE_IO, "events"));
const { StateLockTimeoutError } = require(path.join(STATE_IO, "state-lock"));
const SCHEMA = require(path.join(STATE_IO, "state-handoff-record-schema"));
const { sanitizeUntrustedField } = require("../output-sanitize");

const KIND = "state_handoff_record";
const ELLIPSIS = "...";
const REDACTED_KEY = "redacted-key";
// Same length as every stamped `at`, so a record fitted with it still fits once decide() stamps it.
const AT_PLACEHOLDER = "1970-01-01T00:00:00.000Z";
const ISO_AT_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

// Never throws: { ok, event } or { ok:false }.
function buildEvent(input) {
  if (!input || typeof input !== "object") return { ok: false };
  const { cls, step, key, origin } = input;
  if (!SCHEMA.CLASSES.includes(cls) || !SCHEMA.ORIGINS.includes(origin)) return { ok: false };
  if (!SCHEMA.isValidAtStep(step) || !SCHEMA.isValidKey(key) || key === SCHEMA.OVERFLOW_KEY) return { ok: false };
  // A key that looks like a secret is replaced, not dropped: its redacted form would fail KEY_VALID_RE.
  const storedKey = sanitizeUntrustedField(key, SCHEMA.KEY_MAX_CHARS) === key ? key : REDACTED_KEY;
  const event = {
    kind: KIND,
    cls,
    at_step: step,
    record_key: storedKey,
    summary: sanitizeUntrustedField(input.summary, SCHEMA.MAX_FIELD_CHARS),
    pointer: sanitizeUntrustedField(input.pointer === undefined ? "-" : input.pointer, SCHEMA.MAX_FIELD_CHARS),
    origin,
    provenance: origin === "procedure-point" ? "declared" : "observed",
    at: AT_PLACEHOLDER,
  };
  return { ok: true, event: fitOneRecord(event) };
}

// Shrinks the summary at a character boundary (with a trailing "...") until the stored form
// fits EVENT_MAX_BYTES; the pointer is left whole.
function fitOneRecord(event) {
  if (SCHEMA.storedEventBytes(event) <= SCHEMA.EVENT_MAX_BYTES) return event;
  const chars = Array.from(event.summary.endsWith(ELLIPSIS) ? event.summary.slice(0, -ELLIPSIS.length) : event.summary);
  for (let n = chars.length - 1; n >= 0; n -= 1) {
    const candidate = Object.assign({}, event, { summary: chars.slice(0, n).join("") + ELLIPSIS });
    if (SCHEMA.storedEventBytes(candidate) <= SCHEMA.EVENT_MAX_BYTES) return candidate;
  }
  return Object.assign({}, event, { summary: ELLIPSIS });
}

function inRecordingPeriod(projection) {
  const steps = (projection && projection.steps) || {};
  if (!steps.workflow_init || steps.workflow_init.status !== "complete") return false;
  return !core.TERMINAL_STEPS.some((s) => steps[s] && steps[s].status === "complete");
}

const SAME_FIELDS = ["origin", "at_step", "record_key", "summary", "pointer"];

// `at` is taken under the lock so seq order is at order (readers sort by `at`); never earlier
// than the session's latest own record, so a clock rollback cannot make an old record the latest.
function stampAt(own) {
  return own.reduce((latest, e) => (typeof e.at === "string" && ISO_AT_RE.test(e.at) && e.at > latest ? e.at : latest),
    new Date().toISOString());
}

// Decides inside the lock. Sets outcome.reason; returns the events to append.
function decide(events, projection, built, sid, outcome) {
  // appendEvents synthesizes an initial state when the file is gone (a cleanup between the
  // lock-free check and the lock); returning [] then keeps it from being created.
  const raw = core.readRawState(sid);
  if (!raw) { outcome.reason = "no-state"; return []; }
  if (!inRecordingPeriod(projection)) { outcome.reason = "outside-period"; return []; }
  const boundary = raw && Number.isInteger(raw.upstream_copy_seq) ? raw.upstream_copy_seq : 0;
  const own = events.filter((e) => e && e.kind === KIND && !(Number.isInteger(e.seq) && e.seq <= boundary));
  const event = Object.assign({}, built, { at: stampAt(own) });
  const budgeted = own.filter((e) => e.record_key !== SCHEMA.OVERFLOW_KEY);
  const lastSameCls = budgeted.filter((e) => e.cls === event.cls).pop();
  if (lastSameCls && SAME_FIELDS.every((f) => lastSameCls[f] === event[f])) { outcome.reason = "noop-identical"; return []; }
  // Overflow is sticky: once recorded, a smaller record that would still fit is refused too.
  if (own.some((e) => e.record_key === SCHEMA.OVERFLOW_KEY)) { outcome.reason = "overflow"; return []; }
  const used = budgeted.reduce((sum, e) => sum + SCHEMA.storedEventBytes(e), 0);
  if (budgeted.length < SCHEMA.MAX_RECORDS && used + SCHEMA.storedEventBytes(event) <= SCHEMA.MAX_TOTAL_BYTES) {
    outcome.reason = "written";
    outcome.written = true;
    return [event];
  }
  outcome.reason = "overflow";
  return [{
    kind: KIND, cls: "B", at_step: SCHEMA.NO_STEP, record_key: SCHEMA.OVERFLOW_KEY,
    summary: `state handoff budget reached: ${budgeted.length} records, ${used} bytes; later records are not stored`,
    pointer: "-", origin: event.origin, provenance: event.provenance, at: event.at,
  }];
}

function reportDropped(reason, input) {
  try {
    const cls = sanitizeUntrustedField(input && input.cls, 8);
    const key = sanitizeUntrustedField(input && input.key, SCHEMA.KEY_MAX_CHARS);
    process.stderr.write(`[state-handoff] record dropped: ${reason} cls=${cls} key=${key}\n`);
  } catch (_e) { /* the report is best effort */ }
}

// appendStateHandoffRecord(sid, {cls, step, key, summary, pointer, origin}, {timeoutMs}) -> {written, reason}.
// reason: written | invalid | no-state | outside-period | noop-identical | overflow | lock-timeout | io-error.
// Never throws; lock-timeout and io-error also print one `record dropped` line on stderr.
function appendStateHandoffRecord(sid, input, options) {
  if (typeof sid !== "string" || !core.SESSION_ID_VALID_RE.test(sid)) return { written: false, reason: "invalid" };
  const built = buildEvent(input);
  if (!built.ok) return { written: false, reason: "invalid" };
  const outcome = { written: false, reason: "io-error" };
  try {
    // Lock-free shortcut only; the builder re-checks under the lock.
    if (!core.readRawState(sid)) return { written: false, reason: "no-state" };
    const opts = {};
    if (options && Number.isInteger(options.timeoutMs)) opts.timeoutMs = options.timeoutMs;
    appendEvents(sid, (events, projection) => decide(events, projection, built.event, sid, outcome), opts);
    return { written: outcome.written, reason: outcome.reason };
  } catch (e) {
    const reason = e instanceof StateLockTimeoutError ? "lock-timeout" : "io-error";
    reportDropped(reason, input);
    return { written: false, reason };
  }
}

module.exports = { appendStateHandoffRecord };
