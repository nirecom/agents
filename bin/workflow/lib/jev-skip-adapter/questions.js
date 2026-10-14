"use strict";
// bin/workflow/lib/jev-skip-adapter/questions.js — what Jev is asked for outline-skip and
// detail-skip, and how its answers map back: one noul question per CONDITION_SCHEMAS[target]
// key whose yes side is "the criterion holds (skip allowed)", each carrying its rubric section
// and the rubric's "Judgment rules". Jev's response is untrusted: only the asked keys are read.

const fs = require("fs");
const path = require("path");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..", "..", "..");
const { rubricSection, rubricRules } = require("../jev-request-common.js");
const { CONDITION_SCHEMAS } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "workflow-state", "skip-signal-resolver", "condition-schemas.js"));

const RUBRIC_PATH = path.join(SCRIPT_CHECKOUT_ROOT, "skills", "_shared", "judge-plan-skip.md");
const LINE_PREFIX = "SKIP_CONDITIONS:";

function targetOf(entry) {
  const t = entry && entry.target;
  if (!Object.prototype.hasOwnProperty.call(CONDITION_SCHEMAS, t)) throw new Error("unknown skip target");
  return t;
}

function questionKey(key) {
  return key;
}

function keys(entry) {
  return CONDITION_SCHEMAS[targetOf(entry)].slice();
}

// Throws when a key has no rubric section; the broker then treats the point as unmappable.
function buildQuestions(entry) {
  const target = targetOf(entry);
  const rubric = fs.readFileSync(RUBRIC_PATH, "utf8").replace(/\r\n/g, "\n");
  const rules = rubricRules(rubric);
  const questions = {};
  for (const key of CONDITION_SCHEMAS[target]) {
    const body = rubricSection(rubric, key);
    if (!body) throw new Error("rubric section missing for " + key);
    questions[key] = {
      type: "noul",
      instructions: `Judge whether the ${target} planning stage of the software task described in the state ` +
        `meets the skip criterion ${key}. Rubric: ${body}` + (rules ? `\nJudgment rules:\n${rules}` : ""),
      criteria: {
        true: `The task meets the ${key} criterion: the ${target} stage may be skipped on this key.`,
        false: `The task does not meet the ${key} criterion, or it is unclear: the ${target} stage must run.`,
      },
    };
  }
  return questions;
}

function isAnswer(a) {
  const p = a && typeof a === "object" ? a.noul : undefined;
  return typeof p === "number" && Number.isFinite(p) && p >= 0 && p <= 1;
}

// mapAnswers(response, entry) -> {status: ok|unmappable, items: {key: {p}}, probabilities: {key: p|null}}.
function mapAnswers(response, entry) {
  const answers = response && typeof response === "object" && response.answers && typeof response.answers === "object"
    ? response.answers : {};
  const items = {};
  const probabilities = {};
  let valid = true;
  for (const key of keys(entry)) {
    const a = Object.prototype.hasOwnProperty.call(answers, key) ? answers[key] : null;
    const p = isAnswer(a) ? a.noul : null;
    if (p === null) valid = false;
    items[key] = { p };
    probabilities[key] = p;
  }
  return { status: valid ? "ok" : "unmappable", items, probabilities };
}

// The canonical answer line: every key of the target in schema order, true when in trueKeys.
function toContractLine(trueKeys, entry) {
  const set = new Set(Array.isArray(trueKeys) ? trueKeys : []);
  return `${LINE_PREFIX} ` + keys(entry).map((k) => `${k}=${set.has(k)}`).join(", ");
}

module.exports = { RUBRIC_PATH, LINE_PREFIX, questionKey, keys, buildQuestions, isAnswer, mapAnswers, toContractLine };
