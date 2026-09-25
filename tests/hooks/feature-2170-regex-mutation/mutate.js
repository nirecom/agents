#!/usr/bin/env node
// One-character-off mutation harness: copy a module, neuter ONE regex fragment into a
// never-matching group, load the copy, and report what a probe input now judges. The
// copy lives outside hooks/, so its relative require() specifiers are rewritten to
// absolute paths against the original directory (an unrewritten copy would die on
// MODULE_NOT_FOUND and every probe would "pass" for the wrong reason).
//
// Usage: node mutate.js <module-rel-path> <fragment|--none> <predicate> <input>
// Prints one line: the predicate's verdict, or FRAGMENT_NOT_FOUND / MODULE_MISSING /
// ERROR:<msg>.
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");

const AGENTS_DIR = process.env.AGENTS_DIR || path.join(__dirname, "..", "..");
const [relPath, fragment, predicate, input] = process.argv.slice(2);

const srcPath = path.join(AGENTS_DIR, relPath);
let src;
try {
  src = fs.readFileSync(srcPath, "utf8");
} catch (_e) {
  console.log("MODULE_MISSING");
  process.exit(0);
}

if (fragment !== "--none") {
  const i = src.indexOf(fragment);
  if (i === -1) {
    console.log("FRAGMENT_NOT_FOUND");
    process.exit(0);
  }
  src = src.slice(0, i) + "(?!x)x" + src.slice(i + fragment.length);
}

// Re-anchor relative requires at the ORIGINAL module directory.
const srcDir = path.dirname(srcPath);
src = src.replace(/require\((["'])(\.[^"']*)\1\)/g, (_m, _q, spec) =>
  "require(" + JSON.stringify(path.resolve(srcDir, spec)) + ")");

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "mut2170-"));
const dest = path.join(tmpDir, path.basename(srcPath));
fs.writeFileSync(dest, src);

function say(v) {
  console.log(String(v));
  process.exit(0);
}

try {
  const mod = require(dest);
  if (predicate === "unrecognized") say(mod.commandInvokesUnrecognizedExec(input));
  if (predicate === "egress") say(mod.commandIsEgressTool(input));
  if (predicate === "mask") say(mod.maskDisplayOnlySegments(input) !== input);
  if (predicate === "shape") {
    const { parse } = require(path.join(AGENTS_DIR, "hooks", "lib", "command-ir.js"));
    const ir = parse(input, { preserveSubstitutionSpans: true });
    say(Boolean(mod.detectCaptureEcho(ir)));
  }
  if (predicate === "remedy") {
    // Classify the wording branch: which escape routes the remedy still offers.
    const text = String(mod.buildRemedy({ varNames: ["X"], innerCommandText: input }));
    const bare = text.indexOf("single bare command") !== -1;
    const pad = text.indexOf("scratchpad script") !== -1;
    say(bare && pad ? "both" : bare ? "bare" : pad ? "scratchpad" : "neither");
  }
  say("UNKNOWN_PREDICATE:" + predicate);
} catch (e) {
  console.log("ERROR:" + (e && e.message ? e.message : String(e)));
}
