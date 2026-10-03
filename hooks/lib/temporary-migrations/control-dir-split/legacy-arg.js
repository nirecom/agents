"use strict";
// Temporary (#2434): deleted with this folder per the deletion-condition in control-dir.js.
// A CLI called by a flow that loaded the old SKILL text still passes the session-prefixed <name> path in the plans dir.
// legacyArgName accepts that path only (never any other location) and returns <name>.
const path = require("path");

const { normalizeCwd } = require("../../path-normalize");
const { getWorkflowPlansDir } = require("../../workflow-plans-dir");
const { resolveSessionId } = require("../../../workflow-state/session-id");

function canon(p) {
  const abs = path.resolve(normalizeCwd(p) || p);
  return process.platform === "win32" ? abs.toLowerCase() : abs;
}

function legacyArgName(value, sid, names) {
  if (typeof value !== "string" || value === "" || typeof sid !== "string" || sid === "") return null;
  let plans;
  try {
    plans = getWorkflowPlansDir();
  } catch (_) {
    return null;
  }
  if (!plans || canon(path.dirname(value)) !== canon(plans)) return null;
  const base = path.basename(value);
  for (const name of names) {
    if (base === `${sid}-${name}`) return name;
  }
  return null;
}

function legacySessionId(explicit) {
  if (typeof explicit === "string" && explicit !== "") return explicit;
  return resolveSessionId();
}

module.exports = { legacyArgName, legacySessionId };

// CLI for shell callers: legacy-arg.js <value> <sid-or-empty> <name>... -> prints "<sid>\t<name>", else exit 1.
if (require.main === module) {
  const [value, sidArg, ...names] = process.argv.slice(2);
  const sid = legacySessionId(sidArg);
  const name = legacyArgName(value, sid, names);
  if (name === null) process.exit(1);
  process.stdout.write(`${sid}\t${name}\n`);
}
