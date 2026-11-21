"use strict";
// Child driver of tests/hooks/feature-3019-pm-instructions.js (#3019). No case markers.
// Loads hooks/lib/pm-instructions.js in a process whose cwd, PATH and pinned dirs are the world's, calls
// getPmInstructionsInjection once and prints {out, ms} as JSON.
// argv[2] = JSON {sid, timing?, issues?, deadline?: "zero" | "hook"}: "zero" is a deadline whose every
// slice is 0; "hook" is createDeadline with the 5 s SessionStart / PostCompact budget.
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const req = JSON.parse(process.argv[2]);
const lib = require(path.join(ROOT, "hooks", "lib", "pm-instructions.js"));
const opts = {};
if (req.timing) opts.timing = req.timing;
if (req.issues) opts.issues = req.issues;
if (req.deadline === "zero") opts.deadline = { remainingMs: () => 0, sliceMs: () => 0, deadlineAt: Date.now() };
if (req.deadline === "hook") opts.deadline = require(path.join(ROOT, "hooks", "lib", "hook-deadline.js")).createDeadline({ hookTimeoutMs: 5000 });
const t0 = Date.now();
const out = lib.getPmInstructionsInjection(req.sid, opts);
process.stdout.write(JSON.stringify({ out: out === undefined ? "__undefined__" : out, ms: Date.now() - t0 }));
