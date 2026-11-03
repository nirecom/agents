"use strict";
// Output of hooks/workflow-mark.js (#2824). Every handler message carries a severity:
// INFO (applied, or a notice) travels the normal channel; one UNAPPLIED message (a sentinel or
// grant that changed nothing) switches the whole output to the strong channel, so a refusal is
// never as quiet as a success. STRONG_CHANNEL was settled by the TL3 probe
// (tests/hooks/TL3-hook-posttooluse-output-channels.sh): exit 2 + stderr reaches the model.

const fs = require("fs");

const SEVERITY = Object.freeze({ INFO: "info", UNAPPLIED: "unapplied" });
const STRONG_CHANNEL = "exit2";
const PREFIX = "[NOT APPLIED] ";

function createSink() {
  const messages = [];
  return {
    messages,
    pushMessage: (text) => messages.push({ severity: SEVERITY.INFO, text: String(text) }),
    pushUnapplied: (text) => messages.push({ severity: SEVERITY.UNAPPLIED, text: String(text) }),
  };
}

const lineOf = (m) => (m.severity === SEVERITY.UNAPPLIED ? PREFIX + m.text : m.text);

function withConvLang(text) {
  return require("../lib/conv-lang").withConvLang(text);
}

// renderOutput(messages, channel) -> {stdout, stderr, exitCode}; pure apart from the conv-lang read.
function renderOutput(messages, channel = STRONG_CHANNEL) {
  const list = Array.isArray(messages) ? messages : [];
  if (list.length === 0) return { stdout: "{}", stderr: "", exitCode: 0 };
  const unapplied = list.filter((m) => m.severity === SEVERITY.UNAPPLIED).length;
  if (unapplied === 0) {
    const text = list.map(lineOf).join("\n");
    return {
      stdout: JSON.stringify({
        systemMessage: text,
        hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: withConvLang(text) },
      }),
      stderr: "",
      exitCode: 0,
    };
  }
  const summary = `workflow-mark: ${unapplied} sentinel(s) NOT applied — state unchanged for those; ` +
    "read each [NOT APPLIED] line for the reason and the next action.";
  const body = [summary, ...list.map(lineOf)].join("\n");
  if (channel === "block-decision") {
    return {
      stdout: JSON.stringify({
        decision: "block",
        reason: body,
        systemMessage: summary,
        hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: withConvLang(body) },
      }),
      stderr: "",
      exitCode: 0,
    };
  }
  return { stdout: "", stderr: body + "\n", exitCode: 2 };
}

function flush(messages) {
  const r = renderOutput(messages, STRONG_CHANNEL);
  try {
    if (r.stdout) fs.writeSync(1, r.stdout + "\n");
    if (r.stderr) fs.writeSync(2, r.stderr);
  } catch (_e) { /* a closed pipe must not change the exit code */ }
  process.exit(r.exitCode);
}

module.exports = { SEVERITY, STRONG_CHANNEL, PREFIX, createSink, renderOutput, flush };
