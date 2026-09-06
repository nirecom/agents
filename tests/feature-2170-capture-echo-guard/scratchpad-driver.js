"use strict";
// Section D driver. Modes:
//   --invoke <cmdText>     isAllowedScratchpadInvocation -> allow | deny
//   --invoke-exec <cmdText> <script>   same verdict, but an allow is ACTED ON
//   --root                 getCurrentSessionScratchpadRootNorm -> null | path:<p> | session:<id>
//   --legacy-target <p>    isAllowedScratchpadTarget (EXISTING fn, findRepoRoot stub) -> true|false
//   --lexical-under <root> <p>   precondition helper -> yes | no
// Pre-implementation tokens: MODULE_MISSING (new module absent), EXPORT_MISSING
// (new export absent). ERROR:<msg> means an exception escaped the predicate, which
// is itself a contract violation (the predicate must fail-to-ask, never throw).

const path = require("path");

const AGENTS_DIR = process.env.AGENTS_DIR || "";
const mode = process.argv[2];

function baseModule() {
  return require(path.join(AGENTS_DIR, "hooks", "lib", "claude-scratchpad-base.js"));
}

if (mode === "--lexical-under") {
  const root = path.resolve(process.argv[3] || "");
  const p = path.resolve(process.argv[4] || "");
  console.log(p.startsWith(root + path.sep) ? "yes" : "no");
  process.exit(0);
}

if (mode === "--legacy-target") {
  try {
    const { isAllowedScratchpadTarget } = baseModule();
    console.log(isAllowedScratchpadTarget(process.argv[3] || "", () => null) ? "true" : "false");
  } catch (e) {
    console.log("ERROR:" + (e && e.message ? e.message : String(e)));
  }
  process.exit(0);
}

if (mode === "--root") {
  let base;
  try {
    base = baseModule();
  } catch (_e) {
    console.log("MODULE_MISSING");
    process.exit(0);
  }
  if (typeof base.getCurrentSessionScratchpadRootNorm !== "function") {
    console.log("EXPORT_MISSING");
    process.exit(0);
  }
  try {
    const r = base.getCurrentSessionScratchpadRootNorm();
    if (r === null || r === undefined) console.log("null");
    else if (r.kind === "path") console.log("path:" + r.root);
    else if (r.kind === "session") console.log("session:" + r.sessionId);
    else console.log("other:" + JSON.stringify(r));
  } catch (e) {
    console.log("ERROR:" + (e && e.message ? e.message : String(e)));
  }
  process.exit(0);
}

// --invoke / --invoke-exec
let mod;
try {
  mod = require(path.join(AGENTS_DIR, "hooks", "preuse-auto-approve", "scratchpad-script.js"));
} catch (_e) {
  console.log("MODULE_MISSING");
  process.exit(0);
}
if (!mod || typeof mod.isAllowedScratchpadInvocation !== "function") {
  console.log("EXPORT_MISSING");
  process.exit(0);
}
// --invoke-exec closes the vacuity hole: under plain --invoke nothing ever executes, so
// "the escape target was not executed" would hold even if the predicate had ALLOWED it.
// Here an allow verdict is carried out — the caller's script really runs — so a marker
// left by that script appears exactly when the predicate says allow.
function runIt(script) {
  const { spawnSync } = require("child_process");
  spawnSync("bash", [script], { stdio: "ignore" });
}

try {
  const cmdText = process.argv[3] === undefined ? "" : process.argv[3];
  const allowed = mod.isAllowedScratchpadInvocation(cmdText);
  if (allowed && mode === "--invoke-exec" && process.argv[4]) runIt(process.argv[4]);
  console.log(allowed ? "allow" : "deny");
} catch (e) {
  console.log("ERROR:" + (e && e.message ? e.message : String(e)));
}
