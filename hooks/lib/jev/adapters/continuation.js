"use strict";
// hooks/lib/jev/adapters/continuation.js — the continuation point's adapter: per direction a
// fixed set of yes/no keys asked about the current turn. A key adopted true means "intervene":
// wait-on-invoke holds the next skill back, continue-on-stop keeps going.
// The reason shown to the model is the key's fixed text, never transcript content.

const { mapKeys } = require("./answers");

const DIRECTIONS = Object.freeze({
  "wait-on-invoke": Object.freeze([
    Object.freeze({
      key: "asked-user",
      question: "In the latest assistant message of the current turn, did the assistant ask the user a question or ask the user to choose or confirm something, without the user answering yet?",
      reason: "the assistant asked the user a question that is not answered yet",
    }),
    Object.freeze({
      key: "reported-blocker",
      question: "In the current turn, did the assistant report a blocker, a failure or an unexpected result that it has not resolved and that the user should see before work continues?",
      reason: "the assistant reported an unresolved blocker the user should see first",
    }),
    Object.freeze({
      key: "user-said-wait",
      question: "In the current turn, did the user tell the assistant to stop, wait, pause, or not proceed to the next step on its own?",
      reason: "the user asked to wait before the next step",
    }),
  ]),
  "continue-on-stop": Object.freeze([
    Object.freeze({
      key: "announced-next-action",
      question: "Does the latest assistant message of the current turn announce a concrete next action the assistant is about to take itself, without asking the user anything?",
      reason: "the assistant announced its next action but stopped before taking it",
    }),
    Object.freeze({
      key: "work-remaining",
      question: "Does the current turn show work the user asked for that the assistant can still do on its own and has not finished, with no question to the user pending?",
      reason: "work the user asked for remains and needs no user input",
    }),
  ]),
});

function specsOf(ctx) {
  const specs = ctx && Object.prototype.hasOwnProperty.call(DIRECTIONS, ctx.direction) ? DIRECTIONS[ctx.direction] : null;
  if (!specs) throw new Error("unknown continuation direction");
  return specs;
}

function keysFor(ctx) {
  return specsOf(ctx).map((s) => s.key);
}

function buildQuestions(ctx) {
  const questions = {};
  for (const s of specsOf(ctx)) {
    questions[s.key] = {
      type: "noul",
      instructions: `Read the conversation turn in the state and answer: ${s.question}`,
      criteria: { true: "Yes, clearly.", false: "No, or it is unclear." },
    };
  }
  return questions;
}

// mapAnswers(response, ctx) -> {status: ok|unmappable, items: {key: {p}}, probabilities: {key: p|null}}.
function mapAnswers(response, ctx) {
  return mapKeys(response, keysFor(ctx));
}

// decide(adopted, ctx) -> {used, keys, final}: the adopted-true keys in the fixed order.
function decide(adopted, ctx) {
  const keys = keysFor(ctx).filter((k) => adopted[k] === true);
  return { used: keys.length > 0, keys, final: { direction: ctx.direction, intervene: keys.length > 0, keys } };
}

function idleFinal(ctx) {
  return { direction: ctx && typeof ctx.direction === "string" ? ctx.direction : null, intervene: false, keys: [] };
}

// The fixed reason texts of the known keys, in the fixed order, joined (null when none is known).
function reasonOf(keys) {
  const want = new Set(Array.isArray(keys) ? keys : []);
  const texts = Object.values(DIRECTIONS).flat().filter((s) => want.has(s.key)).map((s) => s.reason);
  return texts.length ? texts.join("; ") : null;
}

module.exports = { DIRECTIONS, keysFor, buildQuestions, mapAnswers, decide, idleFinal, reasonOf };
