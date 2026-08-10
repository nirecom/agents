"use strict";
// tests/feature-1665-run-outcome/lib-outcome-probe.js
//
// TL1 driver for hooks/workflow-run-tests/outcome.js.
//
// Usage: node lib-outcome-probe.js <agents-root> <mode> <json-input>
//
// Modes:
//   values  — prints RUN_OUTCOME_VALUES joined by ","
//   trusted — prints "true" / "false" from isContractTrusted(<input>)
//   parse   — prints "<status>|<exitCode>" from parseWorkerVerdict(<input>.header)
//   resolve — prints resolveRunOutcome(<input>) ("(null)" for null)
//   sweep   — runs resolveRunOutcome over the FULL cross product described in
//             <input>.axes and prints one "<key>\t<result>" line per combination
//
// Any failure to load the module, or a missing export, prints ERR:<reason> on
// stdout. That is the deliberate RED signal before outcome.js exists — the
// caller's assertion then fails with a message naming the missing entry point,
// never with a silent pass.
//
// This driver deliberately contains NO copy of the decision table. It only
// transports inputs and prints answers; every expectation lives in the .sh cases.

function out(s) {
  process.stdout.write(String(s));
}

function render(v) {
  if (v === null || v === undefined) return "(null)";
  return String(v);
}

const [, , root, mode, rawInput] = process.argv;

let mod;
try {
  mod = require(root + "/hooks/workflow-run-tests/outcome.js");
} catch (e) {
  out("ERR:cannot-require-outcome.js (" + (e && e.code ? e.code : "unknown") + ")");
  process.exit(0);
}

let input = {};
try {
  input = rawInput ? JSON.parse(rawInput) : {};
} catch (e) {
  out("ERR:bad-json-input");
  process.exit(0);
}

function need(name) {
  if (typeof mod[name] !== "function") {
    out("ERR:missing-export:" + name);
    process.exit(0);
  }
  return mod[name];
}

try {
  if (mode === "values") {
    if (!Array.isArray(mod.RUN_OUTCOME_VALUES)) {
      out("ERR:missing-export:RUN_OUTCOME_VALUES");
      process.exit(0);
    }
    out(mod.RUN_OUTCOME_VALUES.join(","));
  } else if (mode === "trusted") {
    out(String(need("isContractTrusted")(input) === true));
  } else if (mode === "parse") {
    const r = need("parseWorkerVerdict")(input.header);
    if (r === null || r === undefined) {
      out("(null)");
    } else {
      out(render(r.status) + "|" + render(r.exitCode));
    }
  } else if (mode === "resolve") {
    out(render(need("resolveRunOutcome")(input)));
  } else if (mode === "sweep") {
    const resolve = need("resolveRunOutcome");
    const a = input.axes;
    const lines = [];
    for (const emitter of a.emitter) {
      for (const ambiguous of a.ambiguous) {
        for (const attributed of a.attributed) {
          for (const vetoed of a.vetoed) {
            for (let ci = 0; ci < a.contract.length; ci++) {
              for (const workerStatus of a.workerStatus) {
                const contract = a.contract[ci];
                const key = [
                  render(emitter), String(ambiguous), String(attributed),
                  String(vetoed), "c" + ci, render(workerStatus),
                ].join(":");
                let res;
                try {
                  res = render(resolve({
                    emitter, ambiguous, attributed, vetoed, contract, workerStatus,
                  }));
                } catch (e) {
                  res = "THREW:" + (e && e.message ? e.message : "unknown");
                }
                lines.push(key + "\t" + res);
              }
            }
          }
        }
      }
    }
    out(lines.join("\n"));
  } else {
    out("ERR:unknown-mode:" + String(mode));
  }
} catch (e) {
  out("ERR:threw:" + (e && e.message ? e.message : "unknown"));
}
