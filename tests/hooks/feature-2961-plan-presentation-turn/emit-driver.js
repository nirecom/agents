"use strict";
// #2961 child driver: runs show-plan-link's emitForArtifacts (it exits the process) on the scene's
// plans with an injected sync result, so the after-write duty text is built from real readiness.
// Input: F2961_EMIT = {root, sid, plans, result, cwd}.
const path = require("path");

const s = JSON.parse(process.env.F2961_EMIT);
const h = require(path.join(s.root, "hooks/show-plan-link.js"));
h.emitForArtifacts(s.plans, { session_id: s.sid, cwd: s.cwd, tool_name: "Write" }, { sync: () => s.result, budgetMs: 20000 });
