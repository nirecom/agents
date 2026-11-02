"use strict";
// The rendered Final Report for lane A's no-heading block reason (#2337): the renderer's stdout,
// or null on any failure, in which case the block degrades to carrying no embed.

const path = require("path");

const RENDERER = path.resolve(__dirname, "..", "..", "bin", "render-final-report.js");

function renderFinalReportForReason(sid) {
  try {
    const { spawnSync } = require("child_process");
    const r = spawnSync(process.execPath, [RENDERER, "--session", sid], {
      timeout: 5000,
      stdio: ["ignore", "pipe", "ignore"],
      encoding: "utf8",
    });
    if (!r || r.error || r.status !== 0 || typeof r.stdout !== "string" || !r.stdout.trim()) return null;
    return r.stdout;
  } catch (_) {
    return null;
  }
}

module.exports = { renderFinalReportForReason };
