"use strict";
// Per-workflow-stage complexity routing table (#2099).
//
// Complexity used to be ONE high/low judgment shared by every stage, so
// `write_tests` inherited `write_code`'s threshold. Routing authority now lives
// here — one frozen table, three stages — so a stage's threshold moves alone.
// The judging prompt emits SIGNALS only; level derivation is code-side.

// require() must ALWAYS succeed: this module is reached through the
// hooks/workflow-state.js barrel that unrelated hooks require. Validation runs
// at load but only RECORDS its verdict; derivation throws at CALL time instead,
// and each caller owns its own fail-open direction.

const { isSecretShaped } = require("./complexity-routing/secret-shape");

const ROUTING_STAGES = Object.freeze(["detail", "write_tests", "write_code"]);

// Signal vocabulary. S1-S6 keep the rubric's spellings since #1350;
// S1b-wide-change is new in #2099 (>=8 files; implies S1 — a rubric-side rule,
// deliberately not enforced here).
const SIGNAL_IDS = Object.freeze([
  "S1-multi-file",
  "S1b-wide-change",
  "S2-architecture",
  "S3-security",
  "S4-installer",
  "S5-breaking",
  "S6-long-plan",
]);

// Reserved token meaning "the judge could not decide". Never a member of
// SIGNAL_IDS: its presence routes to the stage's undecidable_level rather than
// participating in escalation matching.
const UNDECIDABLE_SIGNAL = "S0-undecidable";

const LEVELS = Object.freeze(["high", "low"]);

// Three DISTINCT escalation kinds, deliberately not collapsed:
//   solo_escalation              — one signal alone escalates; genuinely solo.
//   legacy_equivalent_escalation — arrays of ONE element, behaviourally identical
//     to solo_escalation, named apart to mark them as kept only to preserve the
//     legacy 1-signal rule (trimmable later). NOT "needs a combination".
//   combination_escalation       — every element of an inner array must be present.
// Authoring convention (validator only requires "non-empty array"):
// combination_escalation entries are always length >= 2; a length-1
// solo-equivalent case belongs in legacy_equivalent_escalation.
const STAGE_ROUTING = Object.freeze({
  detail: Object.freeze({
    default_level: "low",
    solo_escalation: Object.freeze(["S2-architecture", "S5-breaking"]),
    legacy_equivalent_escalation: Object.freeze([]),
    combination_escalation: Object.freeze([Object.freeze(["S1b-wide-change", "S6-long-plan"])]),
    undecidable_level: "high",
  }),
  write_tests: Object.freeze({
    default_level: "low",
    solo_escalation: Object.freeze([
      "S1b-wide-change",
      "S2-architecture",
      "S3-security",
      "S4-installer",
      "S5-breaking",
    ]),
    legacy_equivalent_escalation: Object.freeze([]),
    combination_escalation: Object.freeze([]),
    undecidable_level: "high",
  }),
  // Bit-for-bit equivalent to the legacy "1+ signals -> high" rule.
  // S3-security's structural separation into solo_escalation is a confirmed
  // Scope requirement from issue #2099 — do not merge it back into
  // legacy_equivalent_escalation.
  write_code: Object.freeze({
    default_level: "low",
    solo_escalation: Object.freeze(["S3-security"]),
    legacy_equivalent_escalation: Object.freeze([
      Object.freeze(["S1-multi-file"]),
      Object.freeze(["S1b-wide-change"]),
      Object.freeze(["S2-architecture"]),
      Object.freeze(["S4-installer"]),
      Object.freeze(["S5-breaking"]),
      Object.freeze(["S6-long-plan"]),
    ]),
    combination_escalation: Object.freeze([]),
    undecidable_level: "high",
  }),
});

class RoutingTableUnavailableError extends Error {
  constructor(message) {
    super(message || "STAGE_ROUTING failed validation; level derivation is unavailable");
    this.name = "RoutingTableUnavailableError";
  }
}

const isPlainObject = (v) => typeof v === "object" && v !== null && !Array.isArray(v);
const isLevel = (v) => typeof v === "string" && LEVELS.includes(v);

// validateRoutingTable(table): PURE and TOTAL — accepts any value, never throws.
// Returns { valid, errors }; `errors` names the failing field, never a value.
function validateRoutingTable(table = STAGE_ROUTING) {
  const errors = [];
  try {
    if (!isPlainObject(table)) {
      return { valid: false, errors: ["table must be a plain object (non-null, non-array)"] };
    }
    const keys = Object.keys(table);
    const missing = ROUTING_STAGES.filter((s) => !keys.includes(s));
    const extra = keys.filter((k) => !ROUTING_STAGES.includes(k));
    if (missing.length) errors.push("table is missing stage(s): " + missing.join(", "));
    if (extra.length) errors.push("table has unknown stage(s): " + extra.join(", "));

    for (const stage of ROUTING_STAGES) {
      if (!keys.includes(stage)) continue;
      const entry = table[stage];
      if (!isPlainObject(entry)) {
        errors.push(`${stage}: entry must be a plain object (non-null, non-array)`);
        continue;
      }
      for (const field of ["default_level", "undecidable_level"]) {
        if (!isLevel(entry[field])) errors.push(`${stage}.${field} must be "high" or "low"`);
      }

      // Flat array of signal IDs; empty is valid ("no solo signals for this stage").
      if (!Array.isArray(entry.solo_escalation)) {
        errors.push(`${stage}.solo_escalation must be an array`);
      } else {
        for (const id of entry.solo_escalation) {
          if (!SIGNAL_IDS.includes(id)) errors.push(`${stage}.solo_escalation contains a non-SIGNAL_IDS member`);
        }
      }

      // Arrays of NON-EMPTY arrays. An empty inner array would vacuously satisfy
      // "all elements present" and silently escalate every input to high.
      for (const field of ["legacy_equivalent_escalation", "combination_escalation"]) {
        const value = entry[field];
        if (!Array.isArray(value)) {
          errors.push(`${stage}.${field} must be an array`);
          continue;
        }
        const minLength = field === "combination_escalation" ? 2 : 1;
        for (const group of value) {
          if (!Array.isArray(group)) {
            errors.push(`${stage}.${field} must contain only arrays`);
            continue;
          }
          if (group.length < minLength) {
            errors.push(
              field === "combination_escalation"
                ? `${stage}.${field} must contain at least 2 signal ids`
                : `${stage}.${field} contains an empty inner array`
            );
            continue;
          }
          for (const id of group) {
            if (!SIGNAL_IDS.includes(id)) errors.push(`${stage}.${field} contains a non-SIGNAL_IDS member`);
          }
        }
      }
    }
  } catch (e) {
    errors.push("validation threw: " + (e && e.message ? e.message : String(e)));
  }
  return { valid: errors.length === 0, errors };
}

const LOAD_VALIDATION = validateRoutingTable(STAGE_ROUTING);
const ROUTING_TABLE_VALID = LOAD_VALIDATION.valid;
const ROUTING_TABLE_ERRORS = Object.freeze(LOAD_VALIDATION.errors.slice());

function assertTableUsable() {
  if (!ROUTING_TABLE_VALID) {
    throw new RoutingTableUnavailableError(
      "STAGE_ROUTING failed validation: " + ROUTING_TABLE_ERRORS.join("; ")
    );
  }
}

// Normalizes raw signal input to a Set, or null when the input is
// undecidable/unrecognized (caller then routes to undecidable_level).
function normalizeSignals(signals) {
  const set = new Set();
  for (const raw of signals) {
    const token = String(raw).trim();
    if (token.length === 0) continue;
    if (token === UNDECIDABLE_SIGNAL) return null;
    if (!SIGNAL_IDS.includes(token)) return null;
    set.add(token);
  }
  return set;
}

// canonicalizeSignalsForPersistence(signals) -> string[]. Storage-shape
// canonicalization for the PERSISTED signals field ONLY (level derivation
// keeps consuming the raw array so a malformed input still fails high).
// All-recognized input -> deduplicated tokens, first-occurrence order
// (#2099 H-SIG). Otherwise a token is dropped whole if it has a control char,
// embeds the record CLI's own receipt marker, or matches a known provider
// hard-secret shape (#2099 Finding A/LI-3/LI-6) — see isSecretShaped. A
// benign unrecognized token with none of those traits is kept verbatim.
function canonicalizeSignalsForPersistence(signals) {
  if (!Array.isArray(signals)) return [];
  const present = normalizeSignals(signals);
  if (present !== null) return Array.from(present);
  const CONTROL_CHAR_RE = /[\x00-\x1F\x7F]/;
  const RECEIPT_MARKER = "RECORDED_COMPLEXITY";
  return signals
    .map((raw) => String(raw).trim())
    .filter((token) =>
      token.length > 0 &&
      !CONTROL_CHAR_RE.test(token) &&
      !token.includes(RECEIPT_MARKER) &&
      !isSecretShaped(token)
    );
}

// deriveStageLevel(stage, signals) -> "high" | "low". Decision order is FIXED
// (pinned by tests): table health, stage validity, input shape, undecidable or
// unknown tokens, solo, legacy-equivalent, combination, default.
function deriveStageLevel(stage, signals) {
  assertTableUsable();
  if (!ROUTING_STAGES.includes(stage)) {
    // A programming error, not a fail-open case: unrelated to table health.
    throw new TypeError(`deriveStageLevel: stage must be one of ${ROUTING_STAGES.join(", ")}`);
  }
  const rule = STAGE_ROUTING[stage];
  if (!Array.isArray(signals)) return rule.undecidable_level;

  const present = normalizeSignals(signals);
  if (present === null) return rule.undecidable_level;

  if (rule.solo_escalation.some((id) => present.has(id))) return "high";
  if (rule.legacy_equivalent_escalation.some((g) => g.length === 1 && present.has(g[0]))) return "high";
  if (rule.combination_escalation.some((g) => g.every((id) => present.has(id)))) return "high";
  return rule.default_level;
}

// deriveStageLevels(signals) -> frozen { detail, write_tests, write_code }.
function deriveStageLevels(signals) {
  assertTableUsable();
  const out = {};
  for (const stage of ROUTING_STAGES) out[stage] = deriveStageLevel(stage, signals);
  return Object.freeze(out);
}

// deriveAggregateLevel(signals) -> the LEGACY common rule: any signal -> high.
// SSOT for the CI-C1c auto-skip invariant. Deliberately NOT derived from
// levels.write_code: a future write_code narrowing must not silently move the
// auto-skip boundary.
function deriveAggregateLevel(signals) {
  assertTableUsable();
  if (!Array.isArray(signals)) return "high";
  const present = normalizeSignals(signals);
  if (present === null) return "high";
  return present.size > 0 ? "high" : "low";
}

// deriveLegacyStageLevels(level, signals) -> frozen levels object, for records
// written before `levels` existed. Signals present -> derive normally (L1).
// Signals empty but aggregate level high -> round ALL stages up to high (L2):
// an old high record carries no signal detail, and silently downgrading an
// in-flight session is worse than over-routing it.
function deriveLegacyStageLevels(level, signals) {
  assertTableUsable();
  const list = Array.isArray(signals) ? signals : [];
  if (list.length === 0 && level === "high") {
    const out = {};
    for (const stage of ROUTING_STAGES) out[stage] = "high";
    return Object.freeze(out);
  }
  return deriveStageLevels(list);
}

// isZeroSignalLow(ce): single-sourced truth table for the "provably trivial"
// condition CI-C1c / MOP-C1 auto-skip on.
function isZeroSignalLow(ce) {
  assertTableUsable();
  if (!ce || typeof ce !== "object" || Array.isArray(ce)) return false;
  if (ce.level !== "low") return false;
  if (!Array.isArray(ce.signals)) return false;
  return ce.signals.length === 0;
}

// describeStageRouting(stage): human-readable diagnostic string (mirrors the
// single-joined-string shape of skip-signal-resolver.js describeSkipSignal).
function describeStageRouting(stage) {
  if (!ROUTING_STAGES.includes(stage)) return "";
  const rule = STAGE_ROUTING[stage];
  const parts = [`stage: ${stage}`, `default level = ${rule.default_level}`];
  parts.push(
    rule.solo_escalation.length
      ? `any one of (${rule.solo_escalation.join(", ")}) alone ⇒ high`
      : "no solo-escalation signals"
  );
  parts.push(
    rule.legacy_equivalent_escalation.length
      ? `legacy 1-signal equivalence: any one of (${rule.legacy_equivalent_escalation.map((g) => g.join("+")).join(", ")}) ⇒ high`
      : "no legacy-equivalent escalation"
  );
  parts.push(
    rule.combination_escalation.length
      ? `all of (${rule.combination_escalation.map((g) => g.join(" + ")).join(") or all of (")}) ⇒ high`
      : "no combination escalation"
  );
  parts.push(`undecidable or unrecognized signal ⇒ ${rule.undecidable_level}`);
  return parts.join("; ");
}

const NONE_CELL = "—";
const cell = (list) => (list.length ? list.join("<br>") : NONE_CELL);

// renderStageRoutingMarkdown(): generated block 1 for the rubric doc.
function renderStageRoutingMarkdown() {
  const lines = [
    "| Stage | Default | Solo escalation (`solo_escalation`) | Legacy-equivalent escalation (`legacy_equivalent_escalation`) | Combination escalation (`combination_escalation`) | Undecidable |",
    "|-------|---------|-----------------|------------------------------|------------------------|-------------|",
  ];
  for (const stage of ROUTING_STAGES) {
    const rule = STAGE_ROUTING[stage];
    lines.push(
      "| `" + stage + "` | " + rule.default_level + " | " +
        cell(rule.solo_escalation.map((id) => "`" + id + "`")) + " | " +
        cell(rule.legacy_equivalent_escalation.map((g) => g.map((id) => "`" + id + "`").join(" + "))) + " | " +
        cell(rule.combination_escalation.map((g) => g.map((id) => "`" + id + "`").join(" + "))) + " | " +
        rule.undecidable_level + " |"
    );
  }
  return lines.join("\n");
}

// renderSignalIdsMarkdown(): generated block 2 for the rubric doc.
function renderSignalIdsMarkdown() {
  const lines = SIGNAL_IDS.map((id) => "- `" + id + "`");
  lines.push("- `" + UNDECIDABLE_SIGNAL + "` (reserved: judge could not decide)");
  return lines.join("\n");
}

module.exports = {
  ROUTING_STAGES,
  SIGNAL_IDS,
  UNDECIDABLE_SIGNAL,
  STAGE_ROUTING,
  ROUTING_TABLE_VALID,
  ROUTING_TABLE_ERRORS,
  RoutingTableUnavailableError,
  validateRoutingTable,
  deriveStageLevel,
  deriveStageLevels,
  deriveAggregateLevel,
  canonicalizeSignalsForPersistence,
  deriveLegacyStageLevels,
  isZeroSignalLow,
  describeStageRouting,
  renderStageRoutingMarkdown,
  renderSignalIdsMarkdown,
};
