"use strict";
// hooks/lib/jev/sanitize.js — terminal-safe renderers for decision-record values shown by
// bin/jev-report: only known enum shapes and vocabulary signal ids pass through.

const { SIGNAL_IDS, UNDECIDABLE_SIGNAL } = require("../../workflow-state/complexity-routing");

const VOCAB = new Set([...SIGNAL_IDS, UNDECIDABLE_SIGNAL || "S0-undecidable"]);
const ENUM_RE = /^[a-z0-9_-]{1,32}$/;

function sanitizeAnswerIds(csv) {
  if (csv === null || csv === undefined) return "-";
  const kept = String(csv).split(",").map((s) => s.trim()).filter((s) => VOCAB.has(s));
  return kept.length ? kept.join(",") : "(none)";
}

function sanitizeEnum(v) {
  return typeof v === "string" && ENUM_RE.test(v) ? v : "-";
}

module.exports = { sanitizeEnum, sanitizeAnswerIds };
