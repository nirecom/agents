"use strict";
// Required-runner gate of the tests-frontmatter check (#2863). The staged blob of every staged test
// entrypoint, new or already in a parent (case-markers-gate's placedTargets, #2865), is judged in
// memory by lib/test-gates/test-runner.js. An unreadable blob or an op failure fails open for that
// file with a stderr line. The parents note is left to the case-marker gate, which runs first.

const S = require("../../../lib/test-gates/source");
const { judge, runnerHint } = require("../../../lib/test-gates/test-runner");
const { out, err } = require("../../output");
const { placedTargets } = require("./case-markers-gate");

function gate({ context, snapshot, files }) {
  const targets = placedTargets({ context, snapshot, files });
  if (!targets) return { block: false, messages: [err("pre-commit: test language registry not readable — test-runner check skipped (commit continues)")] };
  const messages = [];
  const high = [];
  const hints = [];
  for (const { rel, entry } of targets) {
    const blob = snapshot.content(rel);
    if (!blob) {
      messages.push(err(`pre-commit: cannot read staged blob for ${rel} — test-runner check skipped for it`));
      continue;
    }
    const j = judge(S.mem(rel, blob), rel);
    for (const l of j.lines) {
      if (l.text.startsWith("HIGH:")) high.push(l.text);
      else messages.push(err(l.text));
    }
    const h = j.high && runnerHint(entry);
    if (h && !hints.includes(h)) hints.push(h);
  }
  if (high.length === 0) return { block: false, messages };
  return { block: true, messages: [...messages, ...high.map(out), out(""), out("Commit blocked: test file(s) do not run under their language's required runner."), ...hints.map(out)] };
}

module.exports = { gate };
