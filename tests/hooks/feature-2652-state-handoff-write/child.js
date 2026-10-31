"use strict";
// Child process for tests/hooks/feature-2652-state-handoff-write.js. The parent pins
// WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR and passes them through the environment.
//   node child.js append <sid> <json-input>  -> prints {result} (or {threw}) on stdout
//   node child.js race   <sid> <json-input>  -> deletes the state file right after the entry's
//                                               lock-free state check, then prints {fired, result}
//   node child.js fanout <sid> <n> <per>     -> runs <n> `burst` children at once, prints their outputs
//   node child.js burst  <sid> <tag> <per>   -> writes <per> records with distinct keys, prints results

const fs = require("node:fs");
const path = require("node:path");
const { spawn } = require("node:child_process");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const [mode, sid, a1, a2] = process.argv.slice(2);
const print = (v) => process.stdout.write(JSON.stringify(v) + "\n");
const entry = () => require(path.join(ROOT, "hooks", "lib", "state-handoff-record")).appendStateHandoffRecord;

function call(input) {
  try { return { result: entry()(sid, input) }; } catch (e) { return { threw: String(e && e.message ? e.message : e).split("\n")[0] }; }
}

if (mode === "append") {
  print(call(JSON.parse(a1)));
} else if (mode === "race") {
  // Patch before the entry is loaded, so every binding the entry takes sees the patch. Fire only
  // while no lock file exists: that is the window between the lock-free check and the builder.
  const core = require(path.join(ROOT, "hooks", "workflow-state", "state-io", "core"));
  const real = core.readRawState;
  let fired = false;
  core.readRawState = function patched(id) {
    const got = real.apply(this, arguments);
    const file = core.getStatePath(id);
    if (!fired && got && id === sid && !fs.existsSync(file + ".lock")) {
      fired = true;
      fs.unlinkSync(file);
    }
    return got;
  };
  print(Object.assign({ fired: null }, call(JSON.parse(a1)), { fired }));
} else if (mode === "burst") {
  const out = [];
  for (let i = 0; i < Number(a2); i += 1) {
    out.push(call({ cls: "D", step: "write_tests", key: `burst.${a1}.${i}`, summary: `burst ${a1} ${i}`, pointer: "-", origin: "auto-record" }));
  }
  print(out);
} else if (mode === "fanout") {
  const n = Number(a1);
  const runs = Array.from({ length: n }, (_, k) => new Promise((resolve) => {
    const child = spawn(process.execPath, [__filename, "burst", sid, String(k), a2], { env: process.env, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => { stdout += d; });
    child.stderr.on("data", (d) => { stderr += d; });
    child.on("close", (code) => resolve({ code, stdout: stdout.trim(), stderr: stderr.trim().slice(0, 300) }));
  }));
  Promise.all(runs).then(print);
} else {
  process.stderr.write(`unknown mode: ${mode}\n`);
  process.exit(2);
}
