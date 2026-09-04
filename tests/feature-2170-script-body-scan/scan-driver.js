"use strict";
// Driver for tests/feature-2170-script-body-scan.sh (#2170 round-2 security fix).
// Modes: --line <text> (suspect|safe), --logical-file <path> (JSON array),
//   --body <path> (suspect|safe), --const <NAME>, --invoke <cmdText> (allow|deny),
//   --indirect-cred <text> (hit|miss; literal "\n" is unescaped first, so a whole
//   multi-line body travels in one argv element).
// MODULE_MISSING / EXPORT_MISSING are the pre-implementation tokens; ERROR:<msg>
// means an exception escaped a predicate, itself a contract violation.

const fs = require("fs");
const path = require("path");

const AGENTS_DIR = process.env.AGENTS_DIR || "";
const mode = process.argv[2];

function load(rel) {
  try {
    return require(path.join(AGENTS_DIR, rel));
  } catch (_e) {
    return null;
  }
}

function emit(v) {
  console.log(v);
  process.exit(0);
}

if (mode === "--invoke") {
  const mod = load("hooks/preuse-auto-approve/scratchpad-script.js");
  if (!mod) emit("MODULE_MISSING");
  if (typeof mod.isAllowedScratchpadInvocation !== "function") emit("EXPORT_MISSING");
  try {
    emit(mod.isAllowedScratchpadInvocation(process.argv[3] === undefined ? "" : process.argv[3]) ? "allow" : "deny");
  } catch (e) {
    emit("ERROR:" + (e && e.message ? e.message : String(e)));
  }
}

if (mode === "--indirect-cred") {
  const cred = load("hooks/lib/credential-check.js");
  if (!cred) emit("MODULE_MISSING");
  if (typeof cred.textHoldsIndirectCredentialAccess !== "function") emit("EXPORT_MISSING");
  const text = (process.argv[3] === undefined ? "" : process.argv[3]).split("\\n").join("\n");
  try {
    emit(cred.textHoldsIndirectCredentialAccess(text) ? "hit" : "miss");
  } catch (e) {
    emit("ERROR:" + (e && e.message ? e.message : String(e)));
  }
}

const scan = load("hooks/preuse-auto-approve/script-body-scan.js");
if (!scan) emit("MODULE_MISSING");

if (mode === "--line") {
  if (typeof scan.lineIsSuspect !== "function") emit("EXPORT_MISSING");
  try {
    emit(scan.lineIsSuspect(process.argv[3] === undefined ? "" : process.argv[3]) ? "suspect" : "safe");
  } catch (e) {
    emit("ERROR:" + (e && e.message ? e.message : String(e)));
  }
}

if (mode === "--logical-file") {
  if (typeof scan.toLogicalLines !== "function") emit("EXPORT_MISSING");
  try {
    emit(JSON.stringify(scan.toLogicalLines(fs.readFileSync(process.argv[3], "utf8"))));
  } catch (e) {
    emit("ERROR:" + (e && e.message ? e.message : String(e)));
  }
}

if (mode === "--body") {
  if (typeof scan.scriptBodyIsSuspect !== "function") emit("EXPORT_MISSING");
  try {
    emit(scan.scriptBodyIsSuspect(process.argv[3]) ? "suspect" : "safe");
  } catch (e) {
    emit("ERROR:" + (e && e.message ? e.message : String(e)));
  }
}

if (mode === "--const") {
  const name = process.argv[3];
  if (!(name in scan)) emit("EXPORT_MISSING");
  emit(String(scan[name]));
}

emit("BAD_MODE:" + String(mode));
