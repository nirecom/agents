"use strict";
const { hasCJK } = require("./detect-cjk");
const { classifyPolicy } = require("./lang-config");
const { canonicalizeHeading } = require("./plan-schema");
const ENGLISH_RUN_RE = /(?:\b[A-Za-z]{2,}\b[^\S\n]+){3,}\b[A-Za-z]{2,}\b/;
// keep in sync with skills/clarify-intent/SKILL.md Path C
const SENTINEL_PATH_C_NONE = "(none — pending issue creation or NON_GITHUB)";

function stripCodeFences(text) {
  return text
    .replace(/```[\s\S]*?```/g, "")
    .replace(/`[^`\n]*`/g, "");
}

// H2 schema-heading canonical check. Runs regardless of PLAN_LANG policy: a
// heading whose text resolves to a canonical section but is not the canonical
// English literal (= a localized variant) is a violation (#2338). Unknown H2
// text (custom sub-sections) resolves to null and is left alone.
function lintHeadings(stripped) {
  const violations = [];
  stripped.split(/\r?\n/).forEach((line, idx) => {
    const m = /^##\s+(.+?)\s*$/.exec(line);
    if (!m) return;
    const text = m[1].trim();
    const canonical = canonicalizeHeading(text);
    if (canonical !== null && text !== canonical) {
      violations.push({
        lineNumber: idx + 1,
        line: line.trim(),
        reason: "schema heading must use canonical English name",
        canonical,
      });
    }
  });
  return violations;
}

// artifactType (optional): when provided, canonical-heading checks run regardless
// of policy. Body language checks still run only under a strict policy.
function lintPlanLang(content, policy, artifactType) {
  if (!content) return [];
  const tier = classifyPolicy(policy);
  const stripped = stripCodeFences(content);
  const violations = [];

  if (artifactType) {
    violations.push(...lintHeadings(stripped));
  }

  if (tier === "strict") {
    stripped.split(/\r?\n/).forEach((line, idx) => {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) return;
      if (trimmed === SENTINEL_PATH_C_NONE) return;
      const lineToCheck = trimmed.replace(/^(-\s*)#\d+:.*$/, "$1");
      if (policy === "english" && hasCJK(line)) {
        violations.push({ lineNumber: idx + 1, line: trimmed, reason: "CJK in english-policy file" });
      } else if (policy === "japanese" && !hasCJK(lineToCheck) && ENGLISH_RUN_RE.test(lineToCheck)) {
        violations.push({ lineNumber: idx + 1, line: trimmed, reason: "English-only run in japanese-policy file" });
      }
    });
  }

  // Deterministic order: violations sorted by line number so heading and body
  // findings interleave in file order regardless of which pass produced them.
  violations.sort((a, b) => a.lineNumber - b.lineNumber);
  return violations;
}

module.exports = { lintPlanLang, stripCodeFences, ENGLISH_RUN_RE };
