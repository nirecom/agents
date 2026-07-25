"use strict";
// SSOT for model identification (#1611). Three rules that used to live in three
// places (skills/issue-create/SKILL.md prose, bin/github-issues/issue-create.sh
// `case`, and ad-hoc hook code) are consolidated here:
//   1. how the system-prompt self-report sentence is parsed,
//   2. how a model id is matched against a keyword list,
//   3. the reporter-model:* label table (its ORDER is behaviour).
// Pure functions only, no I/O. Every error path returns null / [] (fail-open).

// The two extraction rules. Keep each on ONE line as a `const NAME = /re/flags;`
// declaration — tests/feature-1611-model-match.sh mutates exactly this shape to
// prove the parser cases depend on the regexes.
const MODEL_ID_RE = /The exact model ID is\s+([^\r\n]*?)\s*\.?\s*$/m;
const MODEL_NAME_RE = /You are powered by the model named\s+([^\r\n]*?)\s*\.?\s*$/m;
const CONTROL_CHAR_RE = /[\u0000-\u001f\u007f]/;

// Extract the model identifier from the system prompt's self-report sentence:
// `You are powered by the model named <name>. The exact model ID is <id>.`
// Falls back to <name> when the ID clause is absent. Returns null when neither
// clause is present or the input is not a string.
function extractModelIdFromSelfReport(text) {
  if (typeof text !== "string" || !text) return null;
  const byId = MODEL_ID_RE.exec(text);
  if (byId && byId[1] && byId[1].trim()) return byId[1].trim();
  const byName = MODEL_NAME_RE.exec(text);
  if (byName && byName[1] && byName[1].trim()) return byName[1].trim();
  return null;
}

// Canonical comparison form: trimmed + lowercased. Control characters make the
// value untrustworthy → null.
function normalizeModelId(raw) {
  if (typeof raw !== "string") return null;
  if (CONTROL_CHAR_RE.test(raw)) return null;
  const norm = raw.trim().toLowerCase();
  return norm || null;
}

// `;`-separated keyword list (the .env format). Each entry trimmed + lowercased,
// empties dropped. Non-string input yields an empty list.
function parseKeywordList(raw) {
  if (typeof raw !== "string") return [];
  return raw
    .split(";")
    .map((k) => k.trim().toLowerCase())
    .filter((k) => k.length > 0);
}

// First keyword (in the GIVEN order) that occurs in the normalized model id.
// Order is behaviour — callers rely on earlier entries winning.
function matchKeyword(modelId, keywords) {
  const norm = normalizeModelId(modelId);
  if (!norm || !Array.isArray(keywords)) return null;
  for (const keyword of keywords) {
    if (typeof keyword !== "string" || !keyword) continue;
    if (norm.includes(keyword.toLowerCase())) return keyword;
  }
  return null;
}

// keyword → label. Order preserved from the pre-#1611 `case` block in
// bin/github-issues/issue-create.sh; `ds4` must stay ahead of `deepseek`.
// RHS values must exist in .github/labels.yml (pinned by
// tests/fix-1579-reporter-model-keyword-scan.sh T15).
const REPORTER_MODEL_LABELS = [
  ["fable", "reporter-model:fable"],
  ["opus", "reporter-model:opus"],
  ["sonnet", "reporter-model:sonnet"],
  ["ds4", "reporter-model:ds4"],
  ["deepseek", "reporter-model:ds4"],
  ["devstral", "reporter-model:devstral"],
  ["qwen", "reporter-model:qwen-coder"],
];

// reporter-model:* label for a model id, or null when no keyword matches.
function resolveReporterModelLabel(modelId) {
  const hit = matchKeyword(modelId, REPORTER_MODEL_LABELS.map((p) => p[0]));
  if (!hit) return null;
  const row = REPORTER_MODEL_LABELS.find((p) => p[0] === hit);
  return row ? row[1] : null;
}

module.exports = {
  extractModelIdFromSelfReport,
  normalizeModelId,
  parseKeywordList,
  matchKeyword,
  REPORTER_MODEL_LABELS,
  resolveReporterModelLabel,
};
