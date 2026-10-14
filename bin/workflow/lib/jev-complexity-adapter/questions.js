"use strict";
// bin/workflow/lib/jev-complexity-adapter/questions.js — what Jev is asked for complexity-judge
// and how its answers map back: one noul question per JUDGED_SIGNAL_IDS member (the
// deterministic signals are never asked), each carrying its rubric section and the rubric's
// "Judgment rules". Jev's response is untrusted: only the asked keys are read.

const fs = require("fs");
const path = require("path");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..", "..", "..");
const { rubricSection, rubricRules } = require("../jev-request-common.js");
const { SIGNAL_IDS, JUDGED_SIGNAL_IDS } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "workflow-state", "complexity-routing.js"));

const RUBRIC_PATH = path.join(SCRIPT_CHECKOUT_ROOT, "skills", "_shared", "judge-task-complexity.md");

function questionKey(id) {
  return id.toLowerCase().replace(/-/g, "_");
}

// The question keys Jev and the subagent answer for this point (the entry is not consulted:
// every stage asks the same judged signals).
function keys(_entry) {
  return JUDGED_SIGNAL_IDS.map(questionKey);
}

// Throws when a judged signal has no rubric section; the broker then treats the point as unmappable.
function buildQuestions() {
  const rubric = fs.readFileSync(RUBRIC_PATH, "utf8").replace(/\r\n/g, "\n");
  const rules = rubricRules(rubric);
  const questions = {};
  for (const id of JUDGED_SIGNAL_IDS) {
    const body = rubricSection(rubric, id);
    if (!body) throw new Error("rubric section missing for " + id);
    questions[questionKey(id)] = {
      type: "noul",
      instructions: `Judge whether the software task described in the state meets the complexity signal ${id}. ` +
        `Rubric: ${body}` + (rules ? `\nJudgment rules:\n${rules}` : ""),
      criteria: {
        true: `The task meets the ${id} rubric condition.`,
        false: `The task does not meet the ${id} rubric condition.`,
      },
    };
  }
  return questions;
}

// A usable answer: an object whose noul is a probability in [0, 1].
function isAnswer(a) {
  const p = a && typeof a === "object" ? a.noul : undefined;
  return typeof p === "number" && Number.isFinite(p) && p >= 0 && p <= 1;
}

// mapAnswers(response) -> {status: ok|unmappable, items: {questionKey: {p}}, probabilities: {id: p|null}}.
// An unusable answer keeps p null in both, so the gate holds that key for the subagent.
function mapAnswers(response) {
  const answers = response && typeof response === "object" && response.answers && typeof response.answers === "object"
    ? response.answers : {};
  const items = {};
  const probabilities = {};
  let valid = true;
  for (const id of JUDGED_SIGNAL_IDS) {
    const key = questionKey(id);
    const a = Object.prototype.hasOwnProperty.call(answers, key) ? answers[key] : null;
    const p = isAnswer(a) ? a.noul : null;
    if (p === null) valid = false;
    items[key] = { p };
    probabilities[id] = p;
  }
  return { status: valid ? "ok" : "unmappable", items, probabilities };
}

// The contract line for a set of signal ids: SIGNAL_IDS order, "SIGNALS: none" when empty.
function toContractLine(ids) {
  const set = new Set(Array.isArray(ids) ? ids : []);
  const sel = SIGNAL_IDS.filter((id) => set.has(id));
  return sel.length ? "SIGNALS: " + sel.join(", ") : "SIGNALS: none";
}

module.exports = { RUBRIC_PATH, questionKey, keys, buildQuestions, isAnswer, mapAnswers, toContractLine };
