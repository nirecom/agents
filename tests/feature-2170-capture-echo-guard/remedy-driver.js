"use strict";
// Section C driver: buildRemedy(hit) for one innerCommandText, flattened to a single
// line so bash can pattern-match the wording branch.
//   node remedy-driver.js <innerCommandText>   (env VARS=comma,list overrides varNames)
// Prints "MODULE_MISSING" | "EXPORT_MISSING" | "THREW:<msg>" | "TEXT:<one line>".
// buildRemedy must never throw, so THREW: is itself a failed assertion.

const path = require("path");

const AGENTS_DIR = process.env.AGENTS_DIR || "";

let remedy;
try {
  remedy = require(path.join(AGENTS_DIR, "hooks", "block-capture-echo", "remedy.js"));
} catch (_e) {
  console.log("MODULE_MISSING");
  process.exit(0);
}

if (!remedy || typeof remedy.buildRemedy !== "function") {
  console.log("EXPORT_MISSING");
  process.exit(0);
}

const inner = process.argv[2] === undefined ? "" : process.argv[2];
const vars = (process.env.VARS || "PLANS_DIR").split(",");
const hit = process.env.MALFORMED_HIT === "1"
  ? { varNames: null, innerCommandText: null }
  : { varNames: vars, innerCommandText: inner };

try {
  const r = remedy.buildRemedy(hit);
  const text = typeof r === "string" ? r : JSON.stringify(r);
  console.log("TEXT:" + String(text).split(/\r?\n/).join(" "));
} catch (e) {
  console.log("THREW:" + (e && e.message ? e.message : String(e)));
}
