#!/usr/bin/env node
// Layer③ of model identification (#1611): record the model's OWN self-report
// into the session state, for backends where the SessionStart payload carries
// no usable `model` field and SESSION_MODEL_ID is not configured.
//
// Usage:
//   node bin/record-session-model.js --session <sid> --self-report-text "<sentence>"
//   node bin/record-session-model.js --session <sid> <model-id>
//
// This command both RECORDS and INJECTS: when the recorded model arms the
// verbose-prompt flag, the hardening line is written to stdout. A Bash tool
// result lands in the conversation, so the recording turn is also the first
// injection turn — without this there would be a gap until the next
// SessionStart or compaction. The text still has exactly one definition, in
// hooks/lib/verbose-prompt.js.
//
// Always exits 0. A bad invocation, an unrecorded model or an unwritable state
// directory must never break the model's turn — they just produce no output.

"use strict";
const path = require("path");

const HOOKS_LIB = path.join(__dirname, "..", "hooks", "lib");

function parseArgs(argv) {
  const parsed = { session: null, selfReportText: null, modelId: null };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--session") {
      parsed.session = argv[++i] ?? null;
    } else if (arg === "--self-report-text") {
      parsed.selfReportText = argv[++i] ?? null;
    } else if (!arg.startsWith("--") && parsed.modelId === null) {
      parsed.modelId = arg;
    }
  }
  return parsed;
}

try {
  const args = parseArgs(process.argv.slice(2));
  if (!args.session) process.exit(0);

  // --self-report-text carries the raw sentence; the shared matcher owns the
  // extraction rule. A bare positional argument is an already-extracted id.
  let modelId = args.modelId;
  if (args.selfReportText) {
    const { extractModelIdFromSelfReport } = require(path.join(HOOKS_LIB, "model-match.js"));
    modelId = extractModelIdFromSelfReport(args.selfReportText) || modelId;
  }
  if (!modelId) process.exit(0);

  const { recordSessionModel } = require(path.join(HOOKS_LIB, "workflow-state.js"));
  const result = recordSessionModel(args.session, { modelId, source: "self-report" });
  if (result && result.recorded && result.verbosePrompt) {
    const { VERBOSE_PROMPT_TEXT } = require(path.join(HOOKS_LIB, "verbose-prompt.js"));
    process.stdout.write(`${VERBOSE_PROMPT_TEXT}\n`);
  }
} catch (_) {
  // fail-open
}
process.exit(0);
