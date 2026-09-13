#!/usr/bin/env node
"use strict";
// hooks/gate-plan-lang.js — PreToolUse gate: rejects a Write/Edit/MultiEdit/editFiles
// fragment that violates PLAN_LANG before it reaches a plan artifact (#2278).
// Lints each fragment on its own (a MultiEdit element may target another file, and
// an unclosed fence in one fragment must not hide prose in the next). Never reads
// the target file, never writes; every failure path approves (fail-open) so the
// PostToolUse checker check-plan-lang.js stays the backstop.

const path = require("path");
const { readStdinJson, collectEditTargets, approve, block } = require("./lib/pretool-lang-gate");
const {
  isPlanArtifactPath,
  loadPlanPolicy,
  lintPlanArtifactText,
  formatPlanLangViolations,
} = require("./lib/plan-artifact-lang");

function main() {
  const input = readStdinJson();
  if (!input || typeof input !== "object") return approve();
  const targets = collectEditTargets(input.tool_name, input.tool_input);
  if (targets.length === 0) return approve();

  const { policy, tier } = loadPlanPolicy();
  if (tier !== "strict") return approve();

  const hits = [];
  let total = 0;
  for (const t of targets) {
    const resolved = path.resolve(t.filePath);
    if (!isPlanArtifactPath(resolved)) continue;
    const violations = lintPlanArtifactText(t.fragment, policy);
    if (violations.length === 0) continue;
    total += violations.length;
    hits.push({ base: path.basename(resolved), editIndex: t.editIndex, violations });
  }
  if (hits.length === 0) return approve();

  const body = hits.map((h) => {
    const label = h.editIndex === null ? "" : " (edits[" + h.editIndex + "])";
    const lines = formatPlanLangViolations(h.violations).map((s) => "    " + s);
    return "  " + h.base + label + ":\n" + lines.join("\n");
  });
  return block(
    "[gate-plan-lang] PLAN_LANG=" + policy + " — " + total + " violation(s) rejected before write:\n" +
      body.join("\n") +
      "\nRewrite the fragment(s) in " + policy + " before retrying." +
      " Line numbers are relative to the submitted fragment, not to the file on disk.",
  );
}

try {
  main();
} catch (e) {
  approve();
}
