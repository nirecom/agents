"use strict";
// EXPERIMENTAL (#2585). Trace stub for run-jailed.sh --trace: records who loaded or ran one
// root-decoy file, then behaves like a decoy stub.
const fs = require("fs");
const out = process.env.TRACE_STUB_OUT;
const lines = [
  "=== decoy stub reached: " + __filename,
  "argv=" + JSON.stringify(process.argv),
  "cwd=" + process.cwd(),
  "required_by=" + (module.parent ? module.parent.filename : "(main module)"),
  "stack=" + new Error("trace").stack,
  "env=" + JSON.stringify(Object.fromEntries(Object.entries(process.env).filter(([k]) => /AGENTS|ROOT|CHECKOUT|CFG|CONFIG/i.test(k)))),
  "",
];
try { fs.appendFileSync(out, lines.join("\n")); } catch (_) {}
process.stderr.write("root-decoy: TRACE stub reached\n");
process.exit(97);
