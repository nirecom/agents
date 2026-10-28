"use strict";
// One run of a gate CLI for hooks/block-case-markers.js. Every CLI shares one output shape
// (HIGH: / WARN: ... code=) and one call form: `--rel <rel> [--head <head-copy>] <tmpFile>` from
// the repo root. Design: docs/architecture/claude-code/case-marker-gate.md.

const path = require("path");
const { spawnSync } = require("child_process");

const CHECK_TIMEOUT_MS = 8000;

function shellPath(p) {
  return p.split(path.sep).join("/");
}

// runChecker — {high, warn} lines of one CLI run. HIGH lines count only with rc 1; WARN lines
// count at any exit. A spawn error, a timeout or no stdout yields nothing (fail-open). Lines
// name rel; a leftover temp path is rewritten anyway.
function runChecker({ cli, rel, tmpFile, headCopy, top }) {
  const args = [shellPath(cli), "--rel", rel];
  if (headCopy) args.push("--head", shellPath(headCopy));
  args.push(shellPath(tmpFile));
  const r = spawnSync("bash", args, { cwd: top, encoding: "utf8", timeout: CHECK_TIMEOUT_MS });
  if (r.error || typeof r.stdout !== "string") return { high: [], warn: [] };
  const temps = [tmpFile, headCopy].filter(Boolean);
  const lines = r.stdout.split(/\r?\n/).map((l) => temps.reduce((s, t) => s.split(shellPath(t)).join(rel).split(t).join(rel), l));
  return {
    high: r.status === 1 ? lines.filter((l) => /^HIGH: .* code=/.test(l)) : [],
    warn: lines.filter((l) => /^WARN: .* code=/.test(l)),
  };
}

module.exports = { runChecker, shellPath, CHECK_TIMEOUT_MS };
