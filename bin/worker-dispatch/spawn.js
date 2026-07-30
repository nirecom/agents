"use strict";
// bin/worker-dispatch/spawn.js
//
// Fixed-binary execution.
//
// Three properties hold for every child process this dispatcher ever starts:
//   1. shell:false with an argv array. No string is ever handed to a shell, so
//      quoting, `$(...)`, backticks and `;`/`&&`/`|` in payload text are inert
//      by construction rather than by escaping.
//   2. The binary comes from the registry's fixed table — an external command
//      the worker declared, or a script resolved from an anchor plus a hardcoded
//      relative path. The payload never names an executable.
//   3. The child env is an allowlist. AGENTS_CONFIG_DIR is set explicitly from
//      the resolved ACD anchor and is never inherited, so a poisoned parent env
//      cannot redirect a child at a planted checkout.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const registryData = require("../../hooks/lib/worker-dispatch-registry");
const { realAbs, samePath } = require("./anchor");

const DEFAULT_TIMEOUT_MS = 120000;
const MAX_BUFFER = 32 * 1024 * 1024;

// `familyCwd` must already have passed assertCwdInFamily — anchorRoot trusts it.
function anchorRoot(anchorName, anchors, familyCwd) {
  if (anchorName === "acd") return anchors.acd;
  if (anchorName === "main-root") return anchors.mainRoot;
  // The one anchor that deliberately resolves into unreviewed code, and the only
  // one that can serve a worker whose job IS to execute the branch under review.
  // tests/run-all.sh derives its test directory from its own location, so a
  // main-root-anchored script runs main's suite no matter what cwd it is given —
  // i.e. it silently verifies the wrong tree. Widening is bounded: the root is
  // the validated family worktree, never an arbitrary path from the payload.
  if (anchorName === "family-worktree") return familyCwd || null;
  return null;
}

function resolveScript(entry, scriptKey, anchors, familyCwd) {
  const scripts = entry.binaries && entry.binaries.scripts ? entry.binaries.scripts : {};
  if (!Object.prototype.hasOwnProperty.call(scripts, scriptKey)) {
    throw new Error(`worker '${entry.name}' does not declare a script '${scriptKey}'`);
  }
  const decl = scripts[scriptKey];
  const root = anchorRoot(decl.anchor, anchors, familyCwd);
  if (!root) throw new Error(`script '${scriptKey}' names an unresolvable anchor`);
  const abs = realAbs(path.join(root, decl.rel));
  if (abs === null) throw new Error(`script '${scriptKey}' could not be resolved`);
  return abs;
}

function assertCommandAllowed(entry, command) {
  const declared = entry.binaries && Array.isArray(entry.binaries.external) ? entry.binaries.external : [];
  if (!registryData.EXTERNAL_COMMANDS.includes(command)) {
    throw new Error(`command '${command}' is not in the dispatcher's external command table`);
  }
  if (!declared.includes(command)) {
    throw new Error(`worker '${entry.name}' does not declare the command '${command}'`);
  }
}

function buildEnv(entry, anchors, extraEnv) {
  const declared = Array.isArray(entry.envPassthrough) ? entry.envPassthrough : [];
  const allowed = registryData.CHILD_ENV_ALLOWLIST.concat(declared);
  const env = {};
  for (const name of allowed) {
    const v = process.env[name];
    if (typeof v === "string") env[name] = v;
  }
  if (extraEnv) {
    for (const name of Object.keys(extraEnv)) {
      if (!declared.includes(name)) {
        throw new Error(`worker '${entry.name}' does not declare the child env var '${name}'`);
      }
      env[name] = String(extraEnv[name]);
    }
  }
  env.AGENTS_CONFIG_DIR = anchors.acd;
  return env;
}

function assertCwdInFamily(cwd, anchors) {
  const abs = realAbs(cwd);
  if (abs === null) throw new Error("child working directory must be an absolute path");
  const ok = (anchors.family || []).some((f) => samePath(f, abs));
  if (!ok) throw new Error("child working directory is not a worktree of the main-root family");
  return abs;
}

// run(entry, { anchors, command, script, args, cwd, timeoutMs, extraEnv })
// Returns { status, signal, timedOut, spawnError, stdout, stderr }.
function run(entry, opts) {
  const anchors = opts.anchors;
  assertCommandAllowed(entry, opts.command);

  // cwd is validated FIRST: a family-worktree-anchored script resolves against it,
  // so it must be a proven family member before it can act as a script root.
  const cwd = assertCwdInFamily(opts.cwd, anchors);

  const argv = [];
  if (opts.script) argv.push(resolveScript(entry, opts.script, anchors, cwd));
  for (const a of opts.args || []) {
    if (typeof a !== "string") throw new Error("child arguments must all be strings");
    argv.push(a);
  }

  const timeout = typeof opts.timeoutMs === "number" && opts.timeoutMs > 0 ? opts.timeoutMs : DEFAULT_TIMEOUT_MS;

  const res = spawnSync(opts.command, argv, {
    cwd,
    env: buildEnv(entry, anchors, opts.extraEnv),
    shell: false,
    encoding: "utf8",
    timeout,
    windowsHide: true,
    maxBuffer: MAX_BUFFER,
    stdio: ["ignore", "pipe", "pipe"],
  });

  const timedOut =
    (res.error && res.error.code === "ETIMEDOUT") ||
    (res.signal !== null && res.signal !== undefined && res.status === null);

  return {
    status: typeof res.status === "number" ? res.status : null,
    signal: res.signal || null,
    timedOut: Boolean(timedOut),
    spawnError: res.error && !timedOut ? String(res.error.message || res.error.code) : null,
    stdout: String(res.stdout === null || res.stdout === undefined ? "" : res.stdout),
    stderr: String(res.stderr === null || res.stderr === undefined ? "" : res.stderr),
  };
}

// `cwd` is only consulted by family-worktree-anchored scripts, but it is validated
// unconditionally so that a caller cannot probe an out-of-family path for existence.
function scriptExists(entry, scriptKey, anchors, cwd) {
  let abs = null;
  try {
    abs = resolveScript(entry, scriptKey, anchors, assertCwdInFamily(cwd, anchors));
  } catch (_e) {
    return null;
  }
  try {
    return fs.statSync(abs).isFile() ? abs : null;
  } catch (_e) {
    return null;
  }
}

module.exports = { run, resolveScript, scriptExists, buildEnv, DEFAULT_TIMEOUT_MS };
