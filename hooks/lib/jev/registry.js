"use strict";
// hooks/lib/jev/registry.js — data only: the judgment points the broker may judge, and the
// schema check every entry passes before a caller may use it.
// Paths resolve from __dirname, so a worktree's hooks load that worktree's adapter.
// normalizer: a module whose normalize(raw) the broker requires and calls in-process.
// confidence_threshold_by_answer: per answer direction ("true" = the adapter's yes side),
// the lowest confidence max(p, 1-p) at which a Jev answer is adopted (null = never adopted).
// short_circuit_answer: the key value that, once adopted from Jev, decides the point on
// its own (null = never short-circuits); explicit, so a missing key is invalid.
// required_sections_by_stage: per stage, the snapshot sections that must be present in
// full before a Jev answer is adopted.

const path = require("path");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..", "..");
const LIB_DIR = path.join(SCRIPT_CHECKOUT_ROOT, "bin", "workflow", "lib");

const MODES = Object.freeze(["production", "shadow"]);
const THRESHOLD_MIN = 0.5;
const THRESHOLD_MAX = 1;
// Sections every stage of every point requires (CPR-ORTH: the judge never decides
// without the intent and the issue it was written from).
const ALWAYS_REQUIRED_SECTIONS = Object.freeze(["intent", "issue body"]);

const freezeDeep = (o) => {
  for (const v of Object.values(o)) if (v && typeof v === "object") freezeDeep(v);
  return Object.freeze(o);
};

const SKIP_ADAPTER = path.join(LIB_DIR, "jev-skip-adapter.js");

const REGISTRY = freezeDeep({
  "complexity-judge": {
    adapter: path.join(LIB_DIR, "jev-complexity-adapter.js"),
    normalizer: path.join(SCRIPT_CHECKOUT_ROOT, "bin", "workflow", "normalize-judge-signals"),
    mode: "production",
    confidence_threshold_by_answer: { true: 0.7, false: null },
    short_circuit_answer: true,
    backup_subagent: "complexity-judge",
    subagent_type: "complexity-judge",
    fallback: "S0-undecidable",
    stages: ["complexity", "outline", "detail", "write-tests", "write-code"],
    required_sections_by_stage: {
      complexity: ["intent", "issue body"],
      outline: ["intent", "issue body"],
      detail: ["intent", "outline", "issue body"],
      "write-tests": ["intent", "outline", "detail", "issue body"],
      "write-code": ["intent", "outline", "detail", "issue body"],
    },
  },
  "outline-skip": {
    adapter: SKIP_ADAPTER,
    target: "outline",
    mode: "production",
    confidence_threshold_by_answer: { true: 0.9, false: 0.7 },
    short_circuit_answer: false,
    backup_subagent: "plan-skip-judge",
    fallback: "run",
    stages: ["complexity", "outline"],
    required_sections_by_stage: {
      complexity: ["intent", "issue body"],
      outline: ["intent", "issue body"],
    },
  },
  "detail-skip": {
    adapter: SKIP_ADAPTER,
    target: "detail",
    mode: "production",
    confidence_threshold_by_answer: { true: 0.9, false: 0.7 },
    short_circuit_answer: false,
    backup_subagent: "plan-skip-judge",
    fallback: "run",
    stages: ["outline"],
    required_sections_by_stage: {
      outline: ["intent", "outline", "issue body"],
    },
  },
});

const own = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
const isObj = (v) => Boolean(v) && typeof v === "object" && !Array.isArray(v);
const isNonEmptyStr = (v) => typeof v === "string" && v !== "";

// STAGE_SOURCE_SECTIONS lives with the request builder (the sections a snapshot carries);
// loaded lazily so loading the registry never pulls the request module in.
let stageSourceSections = null;
function sourceSections() {
  if (!stageSourceSections) stageSourceSections = require(path.join(LIB_DIR, "jev-request-common.js")).STAGE_SOURCE_SECTIONS;
  return stageSourceSections;
}

function thresholdErrors(t) {
  if (!isObj(t)) return ["confidence_threshold_by_answer must be an object"];
  const keys = Object.keys(t).sort();
  if (keys.length !== 2 || keys[0] !== "false" || keys[1] !== "true") {
    return ['confidence_threshold_by_answer keys must be exactly "true" and "false"'];
  }
  // A point that can adopt nothing is a misconfiguration: mode "shadow" is how to never adopt.
  if (keys.every((k) => t[k] === null)) return ["confidence_threshold_by_answer must not be null in both directions"];
  return keys
    .filter((k) => t[k] !== null
      && (typeof t[k] !== "number" || !Number.isFinite(t[k]) || t[k] < THRESHOLD_MIN || t[k] > THRESHOLD_MAX))
    .map((k) => `confidence_threshold_by_answer.${k} must be a number in ${THRESHOLD_MIN}..${THRESHOLD_MAX} or null`);
}

function sectionErrors(entry, sections) {
  const req = entry.required_sections_by_stage;
  if (!isObj(req)) return ["required_sections_by_stage must be an object"];
  if (!Array.isArray(entry.stages)) return [];
  const errors = [];
  const keys = Object.keys(req);
  if (keys.length !== entry.stages.length || !entry.stages.every((s) => own(req, s))) {
    errors.push("required_sections_by_stage keys must equal stages");
  }
  for (const stage of keys) {
    const list = req[stage];
    const allowed = own(sections, stage) ? sections[stage] : [];
    if (!Array.isArray(list) || list.length === 0) {
      errors.push(`required_sections_by_stage.${stage} must be a non-empty array`);
    } else if (!list.every((s) => allowed.includes(s))) {
      errors.push(`required_sections_by_stage.${stage} holds a section outside STAGE_SOURCE_SECTIONS`);
    } else if (!ALWAYS_REQUIRED_SECTIONS.every((s) => list.includes(s))) {
      errors.push(`required_sections_by_stage.${stage} must include ${ALWAYS_REQUIRED_SECTIONS.join(" and ")}`);
    }
  }
  return errors;
}

// The list of schema violations of one entry ([] = valid).
function validateRegistry(entry) {
  if (!isObj(entry)) return ["entry must be an object"];
  const sections = sourceSections();
  const errors = [];
  for (const k of ["adapter", "backup_subagent", "fallback"]) {
    if (!isNonEmptyStr(entry[k])) errors.push(`${k} must be a non-empty string`);
  }
  for (const k of ["target", "normalizer", "subagent_type"]) {
    if (own(entry, k) && !isNonEmptyStr(entry[k])) errors.push(`${k} must be a non-empty string when present`);
  }
  if (!MODES.includes(entry.mode)) errors.push(`mode must be one of ${MODES.join("|")}`);
  if (!Array.isArray(entry.stages) || entry.stages.length === 0
    || !entry.stages.every((s) => typeof s === "string" && own(sections, s))
    || new Set(entry.stages).size !== entry.stages.length) {
    errors.push("stages must be a non-empty list of known stage names");
  }
  errors.push(...thresholdErrors(entry.confidence_threshold_by_answer));
  if (!own(entry, "short_circuit_answer") || ![true, false, null].includes(entry.short_circuit_answer)) {
    errors.push("short_circuit_answer must be true, false or null");
  }
  errors.push(...sectionErrors(entry, sections));
  for (const k of ["confidence_threshold", "required_sections", "sampling_rate"]) {
    if (own(entry, k)) errors.push(`${k} is a retired key`);
  }
  return errors;
}

// Validated once per point: the registry is frozen data, so the verdict cannot change.
const validity = new Map();

// The entry for a point name, or null when unknown or invalid (fail-safe: an invalid
// point is never judged). Own keys only: a name read from a file or a payload
// ("constructor", "__proto__") must not resolve to an inherited property.
function registryEntry(point) {
  if (typeof point !== "string" || !own(REGISTRY, point)) return null;
  if (!validity.has(point)) validity.set(point, validateRegistry(REGISTRY[point]).length === 0);
  return validity.get(point) ? REGISTRY[point] : null;
}

// Who writes the decision record for a judgment: the hook pair observes only a shadow
// point it can match by subagent_type; every other point is recorded by the CLI.
function recordingOwner(entry) {
  return isObj(entry) && entry.mode === "shadow" && isNonEmptyStr(entry.subagent_type) ? "hook" : "cli";
}

module.exports = { REGISTRY, SCRIPT_CHECKOUT_ROOT, MODES, registryEntry, validateRegistry, recordingOwner };
