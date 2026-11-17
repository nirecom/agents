"use strict";
// #2961 child driver: stageReadiness under the same env (preloads, .env root) as the gate child it is
// compared with. Input: F2961_READ = {root, sid, step, gate}. Output: one JSON line, the readiness
// result, or {missing} when hooks/lib/presentation-readiness.js or its export is not there yet.
const path = require("path");

const q = JSON.parse(process.env.F2961_READ);
let out;
try {
  const m = require(path.join(q.root, "hooks/lib/presentation-readiness"));
  out = typeof m.stageReadiness === "function"
    ? m.stageReadiness(q.sid, q.step, { gate: q.gate })
    : { missing: "no export stageReadiness" };
} catch (e) {
  out = { missing: (e && e.code) || String(e && e.message) };
}
process.stdout.write(JSON.stringify(out));
