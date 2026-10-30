"use strict";
// Runs the registry entries in order (#2507, D4): marker first, then the check over the snapshot's
// staged files, its messages, and its verdict. Returns rc 0 pass, 1 block, 10 CONFIRM_WARN.
// Fail modes: a closed check that throws blocks the commit; an open one prints a diagnostic.

const output = require("./output");

const RC_PASS = 0;
const RC_BLOCK = 1;
const RC_CONFIRM_WARN = 10;

const errText = (e) => (e && e.message ? e.message : String(e));

// filesFor(entry, all, merge) -> { files, narrowed }; narrowed is true only when a merge took the
// merge-incoming paths out, so a check that scans more than the staged files keeps that scope otherwise.
function filesFor(entry, all, merge) {
  if (!entry.mergeNarrowable || !merge || merge.state !== "merging" || !merge.paths) return { files: all, narrowed: false };
  return { files: all.filter((p) => !merge.paths.has(p)), narrowed: true };
}

function killProbe(context) {
  try {
    if (context && context.visibility && typeof context.visibility.kill === "function") context.visibility.kill();
  } catch (_) {
    // The probe is advisory; a failed kill leaves only a stray child.
  }
}

async function runEntry(entry, { context, snapshot, loadCheck }) {
  try {
    const check = loadCheck(entry);
    if (!check || typeof check.run !== "function") throw new Error(`checks/${entry.name}.js exports no run()`);
    const all = await snapshot.files();
    const { files, narrowed } = filesFor(entry, all, context.merge);
    const result = await check.run({ context, snapshot, files, narrowed });
    return result || { verdict: "pass", messages: [] };
  } catch (e) {
    if (entry.failMode === "open") {
      return { verdict: "pass", messages: [output.err(`pre-commit: ${entry.name} skipped (${errText(e)}) — check failed open (commit continues)`)] };
    }
    return { verdict: "block", messages: [output.err(`pre-commit: ${entry.name} failed (${errText(e)}). Commit blocked.`)] };
  }
}

async function run({ entries, context, snapshot, loadCheck }) {
  let confirm = false;
  for (const entry of entries) {
    output.marker(entry.name);
    if (entry.agentsRepoOnly && !context.isAgentsRepo) continue;
    const result = await runEntry(entry, { context, snapshot, loadCheck });
    output.writeMessages(result.messages);
    if (entry.mutatesIndex && result.indexChanged) await snapshot.invalidate();
    switch (result.verdict) {
      case "block":
        killProbe(context);
        return RC_BLOCK;
      case "skip-rest":
        return confirm ? RC_CONFIRM_WARN : RC_PASS;
      case "confirm-warn":
        confirm = true;
        break;
      default:
        break;
    }
  }
  return confirm ? RC_CONFIRM_WARN : RC_PASS;
}

module.exports = { run, RC_PASS, RC_BLOCK, RC_CONFIRM_WARN };
