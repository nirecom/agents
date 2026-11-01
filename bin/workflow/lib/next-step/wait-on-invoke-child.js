#!/usr/bin/env node
"use strict";
// The wait-on-invoke query, run by wait-on-invoke.js in its own process so the parent
// can kill it at its timeout (#2461). argv: <sid> <step> <turnId> <transcriptPath>.
// Only a verdict Jev actually gave is cached; an outage leaves the turn unanswered.

const path = require("path");
const HOOKS = path.join(__dirname, "..", "..", "..", "..", "hooks");
// Taken before anything loads load-env, as every Jev entrypoint does (test-overrides.js).
const OVERRIDES = require(path.join(HOOKS, "lib", "jev", "test-overrides")).captureTestOverrides(process.env);
const { judgeConversation } = require(path.join(HOOKS, "lib", "jev", "conversation-point"));
const { writeVerdict } = require("./wait-on-invoke");

const ANSWERED = new Set([null, "below-threshold"]);

async function main() {
  const [sid, step, turnId, transcriptPath] = process.argv.slice(2);
  if (!sid || !step || !turnId || !transcriptPath) return 1;
  const r = await judgeConversation({
    point: "continuation",
    direction: "wait-on-invoke",
    sessionId: sid,
    transcriptPath,
    judgedIn: { kind: "cli", name: "next-step" },
    overrides: OVERRIDES,
  });
  if (!r || !r.final || !ANSWERED.has(r.fallback_reason)) return 0;
  writeVerdict(sid, step, turnId, { intervene: r.used === true, keys: r.keys });
  return 0;
}

if (require.main === module) main().then((code) => process.exit(code), () => process.exit(1));
