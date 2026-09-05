"use strict";
// Section A driver: parse one command string and ask detectCaptureEcho about it.
// Prints exactly one line: "reject" | "allow" | "MODULE_MISSING" | "ERROR:<msg>".
// "<NL>" in the input argument is decoded to a real newline so the bash case table
// can keep every case on one grep-able row (literal "\n" stays literal).
// "<PIPE>" is decoded to "|" so the table can use the prescribed IFS='|' delimiter
// (parser-regex-tests.md) even for cases that carry a literal pipe.

const path = require("path");

const AGENTS_DIR = process.env.AGENTS_DIR || "";
const args = process.argv.slice(2);
const fieldsMode = args[0] === "--fields";
const raw = (fieldsMode ? args[1] : args[0]) || "";
const cmd = raw.split("<NL>").join("\n").split("<PIPE>").join("|");

let shape;
try {
  shape = require(path.join(AGENTS_DIR, "hooks", "block-capture-echo", "shape.js"));
} catch (_e) {
  console.log("MODULE_MISSING");
  process.exit(0);
}

if (!shape || typeof shape.detectCaptureEcho !== "function") {
  console.log("EXPORT_MISSING");
  process.exit(0);
}

try {
  const { parse } = require(path.join(AGENTS_DIR, "hooks", "lib", "command-ir.js"));
  const ir = parse(cmd, { preserveSubstitutionSpans: true });
  const hit = shape.detectCaptureEcho(ir);
  if (!fieldsMode) {
    console.log(hit ? "reject" : "allow");
  } else if (!hit) {
    console.log("null");
  } else {
    const vars = Array.isArray(hit.varNames) ? hit.varNames.join(",") : String(hit.varNames);
    console.log("vars=" + vars + " inner=" + String(hit.innerCommandText));
  }
} catch (e) {
  console.log("ERROR:" + (e && e.message ? e.message : String(e)));
}
