"use strict";
// tests/feature-1643-worker-dispatch-lib/spawn-stub.js
//
// `node -r` preload for the #1643 worker-dispatch behaviour tests.
//
// It replaces exactly one function — bin/worker-dispatch/spawn.js's `run` — before
// bin/worker-dispatch.js is loaded, so the external-process boundary is canned
// while argv parsing, anchor resolution, the payload wall, the capability wall,
// fsguard containment, emit rendering and the exit code all stay real.
//
// A PATH shim cannot do this job on Windows: spawn.js runs shell:false, so an
// extensionless script is never executable and Node's PATH search skips .cmd
// stubs. Stubbing the seam itself is portable and, unlike a PATH shim, also
// records the exact argv each worker asked for.
//
// Environment (read from the dispatcher process, NOT from a child — the child env
// allowlist is irrelevant here):
//   WD_SPAWN_MODULE  absolute path to bin/worker-dispatch/spawn.js
//   WD_CANNED        JSON file holding an ARRAY of rules, first match wins:
//                      { match?, status?, stdout?, stderr?, timedOut?, spawnError? }
//                    `match` is a substring of "<command> <script> <args...>";
//                    a rule with no `match` is the catch-all.
//   WD_CALL_LOG      JSONL file; one line per intercepted spawn.

const fs = require("fs");

const mod = require(process.env.WD_SPAWN_MODULE);

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
    }) + "\n"
  );

  const rules = JSON.parse(fs.readFileSync(process.env.WD_CANNED, "utf8"));
  for (const rule of rules) {
    if (rule.match === undefined || rule.match === null) return norm(rule);
    if (line.indexOf(rule.match) !== -1) return norm(rule);
  }
  return norm({});
};
