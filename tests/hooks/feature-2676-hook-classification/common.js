"use strict";
// Shared by the three entrypoints of #2676 (feature-2676-hook-classification.js, -limits.js,
// -registration.js). Require it only after the entrypoint's isolate(): it loads fixture.js.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const fx = require("./fixture");
const table = require("./table");

const HOOKS = path.join(table.REPO, "hooks");

const loaded = () => {
  const { rows, error } = table.readClassification();
  assert.ok(!error, error || "");
  assert.ok(rows.length > 0, "the classification table has rows");
  return rows;
};
// The entrypoint is hooks/<name>.js; under file-split Pattern A its logic may sit in hooks/<name>/.
function entrypointSources(hookName) {
  const files = [path.join(HOOKS, `${hookName}.js`)];
  const walk = (dir) => {
    if (!fs.existsSync(dir)) return;
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith(".js")) files.push(full);
    }
  };
  walk(path.join(HOOKS, hookName));
  return files.filter((file) => fs.existsSync(file)).map((file) => fs.readFileSync(file, "utf8"));
}
const armsLimit = (hookName) => entrypointSources(hookName).some((source) => /armDecisionTimeLimit\s*\(/.test(source));

// --- Step 5: each heavy hook as a real process at a shrunken decision time limit ----------------
// Small enough to be reached inside one slowed child, large enough for the hook to start.
const LIMIT_MS = "1500";
const SESSION = "00000000-0000-4000-8000-000000002540";
const bash = (command, cwd) => ({ session_id: SESSION, tool_name: "Bash", tool_input: cwd ? { command, cwd } : { command } });

// limitAsk(run, hookName, checkPattern): the slowed child really ran, and the hook asked in time.
function limitAsk(run, hookName, checkPattern) {
  assert.ok(run.calls.some((call) => call.mode === "slow"), `a slowed child was started: ${JSON.stringify(run.calls)}`);
  assert.strictEqual(run.signal, null, `${hookName} answered before the ${fx.WAIT_CAP_MS} ms wait cap (stderr: ${run.stderr})`);
  assert.strictEqual(run.decision, "ask", `${hookName} asks at the limit; got ${run.decision}: ${run.reason || run.stdout}`);
  assertLimitReason(run.reason, hookName, checkPattern);
  assert.strictEqual(run.status, 0);
}
// assertLimitReason: the whole fixed format, "<hookName>: decision time limit (<ms> ms) reached
// before <checkName> finished; asking instead of deciding", with <checkName> naming the check.
function assertLimitReason(reason, hookName, checkPattern) {
  const escaped = hookName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const format = new RegExp(`^${escaped}: decision time limit \\(${LIMIT_MS} ms\\) reached before (.+) finished; asking instead of deciding$`);
  const matched = format.exec(reason);
  assert.ok(matched, `reason follows the fixed format: ${reason}`);
  assert.match(matched[1], checkPattern, "<checkName> names the check");
}
const decided = (run, decision) => {
  assert.strictEqual(run.signal, null, `answered before the wait cap (stderr: ${run.stderr})`);
  assert.strictEqual(run.decision, decision, `got ${run.decision}: ${run.reason || run.stdout}`);
};

module.exports = { loaded, armsLimit, LIMIT_MS, SESSION, bash, limitAsk, assertLimitReason, decided };
