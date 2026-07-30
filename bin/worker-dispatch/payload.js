"use strict";
// bin/worker-dispatch/payload.js
//
// Payload file loading + structural validation.
//
// The payload arrives as a PLANS_DIR-resident JSON *file path* rather than
// inline argv JSON. That is a guard-layer requirement, not a style choice: free
// text (commit bodies, PR titles, test output) would otherwise have to survive
// the main-worktree guard's UNSAFE_ARG_VALUE_RE reject set.
//
// Loading is byte-preserving. Whatever a field's string value was in the JSON
// file is what the worker receives — no trimming, no unescaping, no shell-quote
// handling. Containment and typing are the next module's job (capability.js);
// this module only proves the file is where it claims to be and that the
// document is an object whose keys the worker actually declares.

const fs = require("fs");

const { absPath, isUnder } = require("./anchor");

const MAX_PAYLOAD_BYTES = 4 * 1024 * 1024;

// loadPayload(file) — single-argument form returns the parsed document as-is.
// loadPayload(file, { plansDir }) additionally enforces PLANS_DIR residency.
// Throws on any failure; the dispatcher turns that into `status: failed`.
function loadPayload(file, opts) {
  const abs = absPath(file);
  if (abs === null) throw new Error("payload path must be an absolute path");

  const plansDir = opts && opts.plansDir ? opts.plansDir : null;
  if (plansDir !== null && !isUnder(abs, plansDir, false)) {
    throw new Error("payload file must live under the workflow plans directory");
  }

  let stat = null;
  try {
    stat = fs.statSync(abs);
  } catch (_e) {
    throw new Error("payload file does not exist");
  }
  if (!stat.isFile()) throw new Error("payload path is not a regular file");
  if (stat.size > MAX_PAYLOAD_BYTES) throw new Error("payload file is too large");

  const raw = fs.readFileSync(abs, "utf8");
  let parsed = null;
  try {
    parsed = JSON.parse(raw);
  } catch (_e) {
    throw new Error("payload file is not valid JSON");
  }
  return parsed;
}

// Structural gate only: shape of the document and the key set. Value typing is
// capability.js, deliberately kept as a separate wall — a key that merely exists
// has proven nothing about what it is allowed to cause.
function validateStructure(payload, entry) {
  const errors = [];
  if (payload === null || typeof payload !== "object" || Array.isArray(payload)) {
    return { ok: false, errors: ["payload must be a JSON object"] };
  }
  const spec = entry && entry.payloadSpec ? entry.payloadSpec : {};
  for (const key of Object.keys(payload)) {
    if (!Object.prototype.hasOwnProperty.call(spec, key)) {
      errors.push(`unknown field '${key}'`);
    }
  }
  return { ok: errors.length === 0, errors };
}

module.exports = { loadPayload, validateStructure, MAX_PAYLOAD_BYTES };
