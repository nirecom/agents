"use strict";
// #2961 child driver: reads the clarify_intent gate through probesFor().gateFor and each scene
// session's readiness through probesFor().readinessFor, under the caller's .env root.
// Input: F2961_SCENE = {root, sids}. Output: one JSON line {gate, readiness: [state per sid]}.
const path = require("path");

const scene = JSON.parse(process.env.F2961_SCENE);
const PT = require(path.join(scene.root, "hooks/lib/presentation-turn"));
const p = PT.probesFor(Date.now() + 20000);
const out = { gate: p.gateFor("clarify_intent") };
out.readiness = typeof p.readinessFor === "function"
  ? scene.sids.map((sid) => p.readinessFor(sid, "clarify_intent"))
  : "MISSING:readinessFor";
process.stdout.write(JSON.stringify(out));
