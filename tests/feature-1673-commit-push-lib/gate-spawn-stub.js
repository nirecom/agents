"use strict";
// tests/feature-1673-commit-push-lib/gate-spawn-stub.js
//
// `node -r` preload for the #1673 commit-push worker behaviour tests.
//
// Same seam as tests/feature-1643-worker-dispatch-lib/spawn-stub.js, with ONE
// addition that the #1643 stub cannot provide: it records `opts.input`, the
// stdin payload the worker hands to hooks/workflow-gate.js (D1). The whole point
// of the gate reproduction is *what bytes reach the gate*, so a stub that drops
// the stdin channel could not tell a correct synthetic PreToolUse payload from
// an empty one.
//
// Everything up to the process boundary stays real: argv parsing, anchor
// resolution, the payload wall, the capability wall, fsguard, emit, exit code.
//
// Environment (read from the dispatcher process, not from a child):
//   WD_SPAWN_MODULE  absolute path to bin/worker-dispatch/spawn.js
//   WD_CANNED        JSON file holding an ARRAY of rules, first match wins:
//                      { match?, nth?, status?, stdout?, stderr?, timedOut?, spawnError? }
//                    `match` is a substring of "<command> <script> <args...>";
//                    a rule with no `match` is the catch-all.
//                    `nth` (1-based) selects a single occurrence of that
//                    substring within one dispatch — required because D1 drives
//                    the SAME gate binary twice (before commit, before push) and
//                    the two calls differ only in their stdin.
//   WD_CALL_LOG      JSONL file; one line per intercepted spawn.

const fs = require("fs");

const mod = require(process.env.WD_SPAWN_MODULE);

// Per-dispatch occurrence counters, keyed by rule `match` substring.
const counters = new Map();

function norm(rule) {
  return {
    status: typeof rule.status === "number" ? rule.status : 0,
    signal: null,
    timedOut: rule.timedOut === true,
    spawnError: typeof rule.spawnError === "string" ? rule.spawnError : null,
    stdout: typeof rule.stdout === "string" ? rule.stdout : "",
    stderr: typeof rule.stderr === "string" ? rule.stderr : "",
  };
}

mod.run = function stubbedRun(entry, opts) {
  const args = (opts.args || []).map(String);
  const line = [opts.command, opts.script || ""].concat(args).join(" ");

  fs.appendFileSync(
    process.env.WD_CALL_LOG,
    JSON.stringify({
      worker: entry && entry.name ? entry.name : null,
      command: opts.command,
      script: opts.script || null,
      args,
      cwd: opts.cwd,
      extraEnv: opts.extraEnv || null,
      // Recorded as-is so an OMITTED envScope (full declared set) stays
      // distinguishable from an explicit `[]` (no declared var at all).
      envScope: opts.envScope === undefined ? null : opts.envScope,
      input: typeof opts.input === "string" ? opts.input : null,
    }) + "\n"
  );

  const rules = JSON.parse(fs.readFileSync(process.env.WD_CANNED, "utf8"));

  // Count this line against every distinct substring the rule set cares about,
  // once per line, so `nth` numbers occurrences of the substring rather than
  // occurrences of the rule.
  const seen = new Set();
  for (const rule of rules) {
    const key = rule.match;
    if (key === undefined || key === null || seen.has(key)) continue;
    seen.add(key);
    if (line.indexOf(key) !== -1) counters.set(key, (counters.get(key) || 0) + 1);
  }

  for (const rule of rules) {
    if (rule.match === undefined || rule.match === null) return norm(rule);
    if (line.indexOf(rule.match) === -1) continue;
    if (rule.nth !== undefined && rule.nth !== counters.get(rule.match)) continue;
    return norm(rule);
  }
  return norm({});
};
