"use strict";
// Schema and limits of the state_handoff_record event kind (#2652): the machine-written handoff
// facts that live in the state stream. events.js validateEvent delegates the kind check here.

const CLASSES = Object.freeze(["A", "B", "C", "D", "E", "F", "G"]);
const ORIGINS = Object.freeze(["procedure-point", "gate-block", "auto-record"]);
const KEY_VALID_RE = /^[A-Za-z0-9_.:-]+$/;
const KEY_MAX_CHARS = 120;
const NO_STEP = "-";

const MAX_FIELD_CHARS = 300;
const EVENT_MAX_BYTES = 2048;
const MAX_RECORDS = 300;
const MAX_TOTAL_BYTES = 65536;
const SEQ_RESERVE_DIGITS = 10;
const OVERFLOW_KEY = "state-handoff:overflow";

const RESERVED_SEQ = Number("9".repeat(SEQ_RESERVE_DIGITS));

// Byte size of the event as stored: compact JSON with a seq of SEQ_RESERVE_DIGITS digits, so the
// count is the same before and after appendEvents assigns the real seq.
function storedEventBytes(event) {
  return Buffer.byteLength(JSON.stringify(Object.assign({}, event, { seq: RESERVED_SEQ })), "utf8");
}

function isValidKey(key) {
  return typeof key === "string" && key.length <= KEY_MAX_CHARS && KEY_VALID_RE.test(key);
}

function isValidAtStep(step) {
  if (step === NO_STEP) return true;
  const { VALID_STEPS } = require("./core");
  return typeof step === "string" && VALID_STEPS.includes(step);
}

// Returns null when `event` satisfies the kind's rules, else a message naming the failing field.
function stateHandoffRecordError(event) {
  if (!CLASSES.includes(event.cls)) return `event.cls must be one of: ${CLASSES.join(", ")}`;
  if (!ORIGINS.includes(event.origin)) return `event.origin must be one of: ${ORIGINS.join(", ")}`;
  if (!isValidAtStep(event.at_step)) return `event.at_step is outside VALID_STEPS and "${NO_STEP}"`;
  if (!isValidKey(event.record_key)) {
    return `event.record_key must match ${KEY_VALID_RE} and be at most ${KEY_MAX_CHARS} characters`;
  }
  for (const field of ["summary", "pointer"]) {
    if (typeof event[field] !== "string") return `event.${field} must be a string`;
  }
  return null;
}

module.exports = {
  CLASSES,
  ORIGINS,
  KEY_VALID_RE,
  KEY_MAX_CHARS,
  NO_STEP,
  MAX_FIELD_CHARS,
  EVENT_MAX_BYTES,
  MAX_RECORDS,
  MAX_TOTAL_BYTES,
  SEQ_RESERVE_DIGITS,
  OVERFLOW_KEY,
  storedEventBytes,
  isValidKey,
  isValidAtStep,
  stateHandoffRecordError,
};
