"use strict";
// agents-repo-gates check (#2507, D7): runs each registry gate's CLI module in process, in order,
// with a section marker per gate. rc 0 is clean, rc 1/2 blocks with the gate's report, and any
// other outcome (missing module, throw, other rc) fails closed. Wording is the former bash lib's.
// readStaged hands a gate the snapshot's staged blobs; a gate that ignores it reads git itself.

const path = require("path");
const { marker, out, err, linesOf } = require("../output");
const { fromCfg, captureStreams } = require("../lib/support");
const { AGENTS_REPO_GATES } = require("../registry");

const FAIL_CLOSED = "Commit blocked: the agents-repo gate fails closed. Emergency bypass: git commit --no-verify";
const RULES_MD = /^rules\/.*\.md$/;
const RULES_POLICY = "hooks/lib/rules-injection-policy.js";

function extraArgs(gate, files) {
  if (gate.module === "bin/lib/check-on-demand-rules.js") return files.filter((f) => RULES_MD.test(f) || f === RULES_POLICY);
  if (gate.module === "bin/lib/check-migration-blocks.js") return files.filter((f) => !RULES_MD.test(f) && !/^tests\//.test(f));
  return [];
}

function closed(lines) {
  return { verdict: "block", messages: [...lines.map(err), err(FAIL_CLOSED)] };
}

async function runGate(gate, context, files, snapshot, narrowed) {
  const at = path.join(context.cfgDir, gate.module);
  let mod;
  try {
    mod = fromCfg(context.cfgDir, gate.module);
    if (!mod || typeof mod.run !== "function") throw new Error("no run() export");
  } catch (e) {
    return closed([`pre-commit: ${gate.cliPath} missing or not runnable (${String((e && e.message) || e).split(/\r?\n/)[0]}) at ${at}.`]);
  }
  const cap = captureStreams();
  let rc;
  try {
    const readStaged = snapshot ? (rel) => snapshot.content(rel) : null;
    const stagedPaths = narrowed ? files : null;
    rc = await mod.run({ argv: [...gate.args, ...extraArgs(gate, files)], cwd: context.repoTop, env: context.env || process.env, stdout: cap.stdout, stderr: cap.stderr, readStaged, stagedPaths });
  } catch (e) {
    return closed([...linesOf(cap.text()), `pre-commit: ${gate.cliPath} failed (${(e && e.message) || e}).`]);
  }
  if (rc === 0) return null;
  if (rc === 1 || rc === 2) {
    const messages = [...linesOf(cap.text()).map(out), out(""), out(`Commit blocked: ${gate.what} (checker rc=${rc}).`)];
    if (gate.doc) messages.push(out(`See ${gate.doc}.`));
    return { verdict: "block", messages };
  }
  return closed([...linesOf(cap.text()), `pre-commit: ${gate.cliPath} rc=${rc} is not a verdict (0 clean, 1 or 2 violation).`]);
}

async function run({ context, snapshot, files, narrowed = false }) {
  for (const gate of AGENTS_REPO_GATES) {
    marker(gate.name);
    const r = await runGate(gate, context, files || [], snapshot, narrowed);
    if (r) return r;
  }
  return { verdict: "pass", messages: [] };
}

module.exports = { run, FAIL_CLOSED };
