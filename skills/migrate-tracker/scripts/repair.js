#!/usr/bin/env node
"use strict";
// The migrate-tracker repair path for a tracker-done board (#3135):
//   (a) the judge says NEEDED (a field is missing): prepare the board, judge again (fail-closed: still missing
//       or undecidable fails the step, no backfill), then backfill;
//   (b) only the unbackfilled diagnostic: backfill alone. Anything else touches nothing.
//   repair({judge, ensure, backfill}) -> {ok, reason?, steps:[...], diagnostics:[...]}
// CLI: repair.js --repo <owner/repo> — prints REPAIR=ok|failed (+ REASON=), the diagnostics on stderr,
// exits 0 / 1 (2 on bad arguments). run-issue-setup.sh --step repair runs it.

const path = require("path");
const { spawnSync } = require("child_process");

const undecidable = (j) => (j.diagnostics || []).some((d) => d.kind === "undecidable");
const unbackfilled = (j) => (j.diagnostics || []).some((d) => d.kind === "unbackfilled");

function repair(io) {
  const steps = [];
  const j = io.judge();
  steps.push("judge");
  const diagnostics = (j && j.diagnostics) || [];
  const fail = (reason) => ({ ok: false, reason, steps, diagnostics });
  if (!j) return fail("judge gave no answer");
  if (j.needed) {
    steps.push("ensure");
    const e = io.ensure();
    if (!e || !e.ok) return fail(`board preparation failed (${(e && e.reason) || "unknown"})`);
    const again = io.judge();
    steps.push("judge");
    if (!again || again.needed) return fail(`still missing after the board preparation: ${((again && again.missing) || []).join(", ")}`);
    if (undecidable(again)) return fail("the board could not be read again after the preparation");
  } else if (!unbackfilled(j)) {
    return { ok: true, steps, diagnostics };
  }
  steps.push("backfill");
  const b = io.backfill();
  if (!b || !b.ok) return Object.assign(fail(`backfill failed (${(b && b.reason) || "unknown"})`), { backfill: b });
  return { ok: true, steps, diagnostics, backfill: b };
}

const ENSURE = path.join(__dirname, "..", "..", "..", "bin", "github-issues", "lib", "ensure-project-ready.sh");

function cliEnsure(repo) {
  const { toMsys2Posix } = require("../../../bin/workflow/lib/workflow-init/spawn-env");
  // stdout goes to stderr too: the board preparation's messages must not mix into REPAIR=.
  const r = spawnSync("bash", ["-c", '. "$0" && ensure_project_ready "$1"', toMsys2Posix(ENSURE), repo], { stdio: ["ignore", 2, 2], windowsHide: true });
  return r.status === 0 ? { ok: true } : { ok: false, reason: r.error ? r.error.message : `ensure_project_ready exited ${r.status}` };
}

function main(argv) {
  const i = argv.indexOf("--repo");
  const repo = i >= 0 ? argv[i + 1] : "";
  if (!/^[A-Za-z0-9_.][A-Za-z0-9_.-]*\/[A-Za-z0-9_.][A-Za-z0-9_.-]*$/.test(repo || "")) {
    process.stderr.write("usage: repair.js --repo <owner/repo>\n");
    return 2;
  }
  const { judgeRepo } = require("../../../bin/lib/tracker-fields/judge");
  const { backfillPm } = require("../../../bin/lib/tracker-fields/backfill");
  const r = repair({ judge: () => judgeRepo(repo), ensure: () => cliEnsure(repo), backfill: () => backfillPm({ repo }) });
  for (const d of r.diagnostics) process.stderr.write(`repair: ${d.kind}: ${d.message}\n`);
  const b = r.backfill || {};
  for (const s of b.skipped || []) process.stderr.write(`repair: backfill skipped ${s.issue}: ${s.reason}\n`);
  for (const f of b.failed || []) process.stderr.write(`repair: backfill failed ${f.issue}: ${f.reason}\n`);
  if (b.written) process.stderr.write(`repair: backfill wrote ${b.written.length} field value(s)\n`);
  process.stdout.write(`REPAIR=${r.ok ? "ok" : "failed"}\n${r.reason ? `REASON=${r.reason}\n` : ""}`);
  return r.ok ? 0 : 1;
}

if (require.main === module) process.exitCode = main(process.argv.slice(2));

module.exports = { repair };
