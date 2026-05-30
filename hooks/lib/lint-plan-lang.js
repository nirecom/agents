"use strict";
const { hasCJK } = require("./detect-cjk");
const { classifyPolicy } = require("./lang-config");
const ENGLISH_RUN_RE = /(?:\b[A-Za-z]{2,}\b[^\S\n]+){3,}\b[A-Za-z]{2,}\b/;

function stripCodeFences(text) {
  return text
    .replace(/```[\s\S]*?```/g, "")
    .replace(/`[^`\n]*`/g, "");
}

function lintPlanLang(content, policy) {
  const tier = classifyPolicy(policy);
  if (tier !== "strict" || !content) return [];
  const stripped = stripCodeFences(content);
  const violations = [];
  stripped.split(/\r?\n/).forEach((line, idx) => {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) return;
    const lineToCheck = trimmed.replace(/^(-\s*)#\d+:.*$/, "$1");
    if (policy === "english" && hasCJK(line)) {
      violations.push({ lineNumber: idx + 1, line: trimmed, reason: "CJK in english-policy file" });
    } else if (policy === "japanese" && !hasCJK(lineToCheck) && ENGLISH_RUN_RE.test(lineToCheck)) {
      violations.push({ lineNumber: idx + 1, line: trimmed, reason: "English-only run in japanese-policy file" });
    }
  });
  return violations;
}

module.exports = { lintPlanLang, stripCodeFences, ENGLISH_RUN_RE };
