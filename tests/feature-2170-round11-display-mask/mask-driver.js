"use strict";
// Driver for tests/feature-2170-round11-display-mask.sh.
// Modes:
//   --mask <line>        maskDisplayOnlySegments(line) -> JSON.stringify of the result,
//                        so a blanked segment and a run of spaces stay visible and the
//                        value survives the shell round-trip unambiguously.
//   --mask-raw <line>    the same result unquoted (for substring assertions).
//   --nonstring <null|number|undefined|array>  the non-string input contract.
// MODULE_MISSING / EXPORT_MISSING are the pre-implementation tokens; THREW:<msg> means
// an exception escaped, itself a contract violation — the mask feeds guard predicates
// that must never throw on arbitrary body text.

const path = require("path");

const AGENTS_DIR = process.env.AGENTS_DIR || "";
const mode = process.argv[2];
const arg = process.argv[3] === undefined ? "" : process.argv[3];

function emit(v) {
  console.log(v);
  process.exit(0);
}

let mod;
try {
  mod = require(path.join(AGENTS_DIR, "hooks", "lib", "display-only-mask.js"));
} catch (_e) {
  emit("MODULE_MISSING");
}
if (!mod || typeof mod.maskDisplayOnlySegments !== "function") emit("EXPORT_MISSING");

const NON_STRING = {
  null: null,
  undefined: undefined,
  number: 42,
  array: ["echo hi"],
  object: {},
};

function run(value, stringify) {
  try {
    const out = mod.maskDisplayOnlySegments(value);
    return stringify ? JSON.stringify(out) : out;
  } catch (e) {
    return "THREW:" + (e && e.message ? e.message : String(e));
  }
}

switch (mode) {
  case "--mask":
    emit(run(arg, true));
    break;
  case "--mask-raw":
    emit(run(arg, false));
    break;
  case "--nonstring":
    if (!(arg in NON_STRING)) emit("BAD_KIND:" + arg);
    emit(run(NON_STRING[arg], true));
    break;
  default:
    emit("BAD_MODE:" + String(mode));
}
