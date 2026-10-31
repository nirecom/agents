"use strict";
// settings-effort-unstage check (#2507): unstages the root settings.json when its only staged
// change is effortLevel, and reports indexChanged so the snapshot is rebuilt.

const { out } = require("../output");
const { git } = require("../lib/support");

const SETTINGS = "settings.json";

function stripEffort(buf) {
  if (buf === null || buf === undefined) return "";
  try {
    const j = JSON.parse(Buffer.from(buf).toString("utf8"));
    if (j && typeof j === "object") delete j.effortLevel;
    return JSON.stringify(j);
  } catch (_) {
    return "";
  }
}

async function run({ context, snapshot, files }) {
  if (!files.includes(SETTINGS)) return { verdict: "pass", messages: [] };
  const headClean = stripEffort(await snapshot.headContent(SETTINGS));
  const stagedClean = stripEffort(await snapshot.content(SETTINGS));
  if (!headClean || headClean !== stagedClean) return { verdict: "pass", messages: [] };
  const r = git(context.repoTop, ["reset", "-q", "HEAD", "--", SETTINGS], { env: context.env });
  // A mixed reset may answer rc 1 for remaining unstaged changes; only a failed spawn stops here.
  if (r.error || r.status === null) return { verdict: "pass", messages: [] };
  return { verdict: "pass", messages: [out(`pre-commit: auto-unstaged ${SETTINGS} (effortLevel-only change)`)], indexChanged: true };
}

module.exports = { run };
