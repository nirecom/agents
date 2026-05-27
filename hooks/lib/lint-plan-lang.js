"use strict";
const { hasCJK } = require("./detect-cjk");
const ENGLISH_RUN_RE = /(?:\b[A-Za-z]{2,}\b[^\S\n]+){3,}\b[A-Za-z]{2,}\b/;

function stripCodeFences(text) {
  return text
    .replace(/```[\s\S]*?```/g, "")
    .replace(/`[^`\n]*`/g, "");
}

function lintPlanLang(content, policy) {
  if (!content || policy === "any") return [];
  const stripped = stripCodeFences(content);
  const violations = [];
  stripped.split(/\r?\n/).forEach((line, idx) => {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) return;
    if (policy === "english" && hasCJK(line)) {
      violations.push({ lineNumber: idx + 1, line: trimmed, reason: "CJK in english-policy file" });
    } else if (policy === "japanese" && !hasCJK(line) && ENGLISH_RUN_RE.test(trimmed)) {
      violations.push({ lineNumber: idx + 1, line: trimmed, reason: "English-only run in japanese-policy file" });
    }
  });
  return violations;
}

module.exports = { lintPlanLang, stripCodeFences };
