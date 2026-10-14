"use strict";
// bin/workflow/lib/jev-skip-adapter.js — the outline-skip / detail-skip adapter the Jev broker
// and jev-judge load (registry entry `adapter`): dispatch and re-export only. Questions and
// answer mapping live in ./jev-skip-adapter/questions.js, the subagent side in ./answer.js.
// Keys always come from CONDITION_SCHEMAS[entry.target]; there is no deterministic stage.

const questions = require("./jev-skip-adapter/questions.js");
const answer = require("./jev-skip-adapter/answer.js");

module.exports = {
  executor: answer.EXECUTOR,
  questionKey: questions.questionKey,
  keys: questions.keys,
  buildQuestions: questions.buildQuestions,
  isAnswer: questions.isAnswer,
  mapAnswers: questions.mapAnswers,
  toContractLine: questions.toContractLine,
  parseSubagent: answer.parseSubagent,
  fillConditions: answer.fillConditions,
  ADOPTED_TO_SOURCE: answer.ADOPTED_TO_SOURCE,
  frontmatterModel: answer.frontmatterModel,
  resolveExecutorModel: answer.resolveExecutorModel,
};
