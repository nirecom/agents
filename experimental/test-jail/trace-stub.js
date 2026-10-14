"use strict";
// EXPERIMENTAL (#2585). Trace stub for run-jailed.sh --trace: records who loaded or ran one
// root-decoy file, then behaves like a decoy stub.
const fs = require("fs");
const out = process.env.TRACE_STUB_OUT;
// The four current root names (docs/architecture/claude-code/root-names.md); run-jailed.sh hands
// the retired ones in TRACE_STUB_NAMES. Exact names only: a pattern would record unrelated
// settings. The names are only reported here, never read as roots.
const ROOT_NAMES = ["AGENTS_MAIN_ROOT", "SCRIPT_CHECKOUT_ROOT", "TARGET_MAIN_ROOT", "TARGET_CHECKOUT_ROOT"];
const traced = new Set([...ROOT_NAMES, ...(process.env.TRACE_STUB_NAMES || "").split(/\s+/).filter(Boolean)]);
const lines = [
  "=== decoy stub reached: " + __filename,
  "argv=" + JSON.stringify(process.argv),
  "cwd=" + process.cwd(),
  "required_by=" + (module.parent ? module.parent.filename : "(main module)"),
  "stack=" + new Error("trace").stack,
  "env=" + JSON.stringify(Object.fromEntries(Object.entries(process.env).filter(([k]) => traced.has(k)))),
  "",
];
try { fs.appendFileSync(out, lines.join("\n")); } catch (_) {}
process.stderr.write("root-decoy: TRACE stub reached\n");
process.exit(97);
