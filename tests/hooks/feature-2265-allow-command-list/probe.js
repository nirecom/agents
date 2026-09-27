"use strict";
// tests/hooks/feature-2265-allow-command-list/probe.js
// Drives hooks/lib/allow-command-list.js in process and prints one normalized line, so the
// shell side compares plain strings. A missing module or export prints <MISSING:...>, and a
// throw prints <THREW:...> -- the loader contract is "never throw, return no targets".
//
//   node probe.js load <root>             -> entries=a,b;bare=x,y   (both sorted)
//   node probe.js interp <root> <entry>   -> bash | node | null

const path = require("path");

const [, , mode, root, entry] = process.argv;
const MOD = path.resolve(__dirname, "..", "..", "..", "hooks", "lib", "allow-command-list.js");

let lib;
try {
  lib = require(MOD);
} catch (e) {
  process.stdout.write("<MISSING:hooks/lib/allow-command-list.js>");
  process.exit(0);
}

const sorted = (xs) => [...xs].map(String).sort().join(",");

try {
  if (mode === "load") {
    if (typeof lib.loadAllowTargets !== "function") {
      process.stdout.write("<MISSING:loadAllowTargets>");
    } else {
      const out = lib.loadAllowTargets(root);
      if (!out || !Array.isArray(out.entries) || !(out.exposedBare instanceof Set)) {
        process.stdout.write("<BAD-SHAPE>");
      } else {
        process.stdout.write(`entries=${sorted(out.entries)};bare=${sorted(out.exposedBare)}`);
      }
    }
  } else if (mode === "interp") {
    if (typeof lib.interpreterOf !== "function") {
      process.stdout.write("<MISSING:interpreterOf>");
    } else {
      const v = lib.interpreterOf(root, entry);
      process.stdout.write(v === null || v === undefined ? "null" : String(v));
    }
  } else {
    process.stdout.write(`<UNKNOWN-MODE:${mode}>`);
  }
} catch (e) {
  process.stdout.write(`<THREW:${e && e.name}>`);
}
