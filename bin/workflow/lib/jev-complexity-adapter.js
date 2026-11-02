"use strict";
// bin/workflow/lib/jev-complexity-adapter.js — the complexity-judge adapter the Jev broker
// loads (registry entry `adapter`): dispatch and re-export only. Questions and answer mapping
// live in ./jev-complexity-adapter/questions.js, the LLM side in ./llm.js, the shadow request
// in ./request.js. JEV_TICKET_STAGE_OF_STEP maps a workflow step to its Jev ticket stage for the
// shadow path only; the CLI takes the ticket stage from its ticket.

const { MAX_STATE_CHARS, MAX_ARTIFACT_READ_BYTES, notesSessionId } = require("./jev-request-common.js");
const questions = require("./jev-complexity-adapter/questions.js");
const llm = require("./jev-complexity-adapter/llm.js");
const { buildRequest } = require("./jev-complexity-adapter/request.js");
const { decidesAtStage } = require("./jev-complexity-adapter/decisive.js");

const JEV_TICKET_STAGE_OF_STEP = Object.freeze({
  workflow_init: "cos1",
  clarify_intent: "cos1",
  outline: "outline",
  detail: "detail",
  write_tests: "write_tests",
  write_code: "write_code",
});

function jevTicketStageOfStep(step) {
  return typeof step === "string" && Object.prototype.hasOwnProperty.call(JEV_TICKET_STAGE_OF_STEP, step)
    ? JEV_TICKET_STAGE_OF_STEP[step] : "unknown";
}

module.exports = {
  JEV_TICKET_STAGE_OF_STEP,
  MAX_STATE_CHARS,
  MAX_ARTIFACT_READ_BYTES,
  jevTicketStageOfStep,
  notesSessionId,
  buildRequest,
  questionKey: questions.questionKey,
  buildQuestions: questions.buildQuestions,
  isAnswer: questions.isAnswer,
  mapAnswers: questions.mapAnswers,
  toContractLine: questions.toContractLine,
  keys: questions.keys,
  // The only stage whose S1b / S4 are computed from the write-code list, never judged.
  deterministicStage: "write-code",
  decidesAtStage,
  parseSubagent: llm.parseSubagent,
  extractLlmText: llm.extractLlmText,
  parserSelectedLine: llm.parserSelectedLine,
  classifyLlm: llm.classifyLlm,
  frontmatterModel: llm.frontmatterModel,
  resolveExecutorModel: llm.resolveExecutorModel,
  stripDeterministicTokens: llm.stripDeterministicTokens,
};
