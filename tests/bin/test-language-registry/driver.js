// Node side of tests/bin/test-language-registry.sh: drives the registry reader.
// Usage: node driver.js <command> <reader.js> [args...]
//   match <list>   -> "<line>\t<id>\t<status>" ("-" when no entry matches)
//   selfid <list>  -> "<line>\t0|1"            strip <list> -> "<line>\t<stripped>"
//   dump | hml | parts | tryload | globs <id> | load <file>
// List lines may be paths; only the basename is matched. Exit 3 = reader missing.
"use strict";
const fs = require("fs");

const [, , cmd, readerPath, arg] = process.argv;
let r;
try {
  r = require(readerPath);
} catch (e) {
  process.stdout.write("MODULE_MISSING\n");
  process.exit(3);
}
const base = (p) => p.split("/").pop();
const lines = (f) => fs.readFileSync(f, "utf8").split("\n").filter((l) => l !== "");
const out = [];

switch (cmd) {
  case "match":
    for (const l of lines(arg)) {
      const m = r.matchBasename(base(l));
      out.push(m ? `${l}\t${m.id}\t${m.status}` : `${l}\t-\t-`);
    }
    break;
  case "selfid":
    for (const l of lines(arg)) out.push(`${l}\t${r.matchesSelfIdentifying(base(l)) ? 1 : 0}`);
    break;
  case "strip":
    for (const l of lines(arg)) out.push(`${l}\t${r.stripName(base(l))}`);
    break;
  case "dump":
    process.stdout.write(r.toShellDump());
    process.exit(0);
    break;
  case "hml":
    out.push(String(r.headerMaxLines()));
    break;
  case "globs": {
    const e = r.loadRegistry().entries.find((x) => x.id === arg);
    out.push(...(e ? r.globsOf(e) : ["NO_ENTRY"]));
    break;
  }
  case "parts":
    for (const e of r.loadRegistry().entries) {
      for (const f of ["caseMarkerReader", "tableDrivenDetector"]) {
        if (e[f]) out.push(`${e.id}\t${f}\t${e[f].file}\t${e[f].function}`);
      }
    }
    break;
  case "load":
    try {
      r.loadRegistry(arg || undefined);
      out.push("OK");
    } catch (e) {
      out.push("THROW");
    }
    break;
  case "tryload":
    out.push(r.tryLoadRegistry() === null ? "NULL" : "OBJECT");
    break;
  default:
    process.stderr.write(`driver.js: unknown command ${cmd}\n`);
    process.exit(2);
}
process.stdout.write(out.length ? out.join("\n") + "\n" : "");
