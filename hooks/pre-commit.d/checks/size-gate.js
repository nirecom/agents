"use strict";
// File-size commit gate (#2631), chained after agents-repo-gates in its section (no registry row,
// no marker, as the bash hook ran it): one bin/size-check child judges every staged file against
// hooks/lib/size-limits.js. A child, not a require: the CLI sets process.exitCode at load and is
// stubbed by exit-only scripts (D7 exception). rc 1 HARD, rc 2 usage and any other rc block.

const path = require("path");
const { spawnSync } = require("../../lib/limited-child-process");
const { toWindowsPath } = require("../../lib/branch-diff");
const { out, err, linesOf } = require("../output");

const TIMEOUT_MS = 120000;
const RECORD = /^(WARN|SHRINK)\t/;
const HARD_RECORD = /^(HARD|WARN|SHRINK)\t/;

function spawnSizeCheck(context) {
  const script = path.join(toWindowsPath(context.cfgDir), "bin", "size-check");
  return spawnSync(process.execPath, [script, "--staged-auto", "--session-gate"], {
    cwd: toWindowsPath(context.repoTop), env: context.env || process.env, encoding: "utf8",
    timeout: TIMEOUT_MS, maxBuffer: 64 * 1024 * 1024, windowsHide: true,
  });
}

// run({ context }) -> null when the commit may go on, else { verdict: "block", messages }.
function run({ context }) {
  const r = spawnSizeCheck(context);
  const childErr = linesOf(r.stderr).map(err);
  const lines = linesOf(r.stdout);
  const rc = r.error ? `${r.error.code || r.error.message}` : (r.status === null ? r.signal : r.status);
  if (rc === 0) return { verdict: "pass", messages: [...childErr, ...lines.filter((l) => RECORD.test(l)).map(err)] };
  if (rc === 1) {
    return { verdict: "block", messages: [...childErr, ...lines.filter((l) => HARD_RECORD.test(l)).map(out), out(""),
      out("Commit blocked: staged files exceed the HARD size limit (record: verdict value pre warn hard unit path)."),
      out("Shrink or split them — see rules/coding/file-split.md.")] };
  }
  if (rc === 2) return { verdict: "block", messages: [...childErr, err("Commit blocked: size-check usage error (rc=2) — the size gate is misinstalled.")] };
  return { verdict: "block", messages: [...childErr,
    err(`Commit blocked: size-check could not finish (rc=${rc}, infrastructure error) — the size gate fails closed.`),
    err("Fix the git/read error reported above and commit again.")] };
}

// after(check) — check, then this gate when check did not block; messages keep that order.
function after(check) {
  return {
    async run(args) {
      const first = (await check.run(args)) || { verdict: "pass", messages: [] };
      if (first.verdict === "block") return first;
      const size = run(args);
      return { ...first, verdict: size.verdict === "block" ? "block" : first.verdict, messages: [...(first.messages || []), ...size.messages] };
    },
  };
}

module.exports = { run, after };
