#!/usr/bin/env node
// PostToolUse(AskUserQuestion) hook — writer 2 of the finding-filing approval record (#2019 S1-4).
// Takes the pending entry pre-tool-use-askuser-jev.js left for this tool_use_id. Only a human answer
// (route not `answered`, no answers in the input, answers in the response) to an approval dialog
// becomes one askuser-answer record of the `[k:<8hex>]` keys of the chosen labels. Anything else
// writes nothing beyond removing the pending entry. Fail-open for the tool: always exit 0.
// Contract: lib/finding-approval.js.
"use strict";

const fs = require("fs");
const { readHookInput } = require("./lib/read-stdin");
const fa = require("./lib/finding-approval");

const SID_RE = /^[A-Za-z0-9_-]+$/;

function answerKeys(answers) {
  if (!answers || typeof answers !== "object" || Array.isArray(answers)) return [];
  const keys = [];
  for (const value of Object.values(answers)) {
    for (const k of fa.labelKeys(value)) if (!keys.includes(k)) keys.push(k);
  }
  return keys;
}

function run(input) {
  if (!input || input.tool_name !== "AskUserQuestion") return;
  const sid = typeof input.session_id === "string" ? input.session_id : "";
  const toolUseId = typeof input.tool_use_id === "string" ? input.tool_use_id : "";
  if (!SID_RE.test(sid) || !toolUseId) return;
  const resp = input.tool_response && typeof input.tool_response === "object" ? input.tool_response : {};
  fa.takePendingAndRecord(sid, toolUseId, (p) => {
    if (p.route === "answered" || p.input_had_answers !== false || !fa.isApprovalDialog(p.dialog_id)) return null;
    const keys = answerKeys(resp.answers);
    if (keys.length === 0) return null;
    return { type: "askuser-answer", dialog_id: p.dialog_id, keys, at: new Date().toISOString() };
  });
}

if (require.main === module) {
  try {
    const r = readHookInput();
    if (r.kind === "ok") run(r.input);
  } catch (_e) { /* fail-open */ }
  try { fs.writeSync(1, JSON.stringify({}) + "\n"); } catch (_e) { /* fail-open */ }
}

module.exports = { answerKeys, run };
