"use strict";
// bin/worker-dispatch/spawn.js
//
// Fixed-binary execution: shell:false argv, a binary from the registry's fixed
// table, and an allowlisted child env. What/Why (the three invariants, anchors,
// envScope, stdin `input`):
// docs/architecture/claude-code/worker-dispatch/spawn.md

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const registryData = require("../../hooks/lib/worker-dispatch-registry");
const { realAbs, samePath } = require("./anchor");

const DEFAULT_TIMEOUT_MS = 120000;
const MAX_BUFFER = 32 * 1024 * 1024;

// `familyCwd` must already have passed assertCwdInFamily — anchorRoot trusts it.
// `family-worktree` is the one anchor that resolves into unreviewed code, and the
// only one that can serve a worker whose job IS to run the branch under review.
// Why that widening is safe and bounded: see spawn.md "Anchors".
function anchorRoot(anchorName, anchors, familyCwd) {
  if (anchorName === "acd") return anchors.acd;
  if (anchorName === "main-root") return anchors.mainRoot;
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

// envScope narrows entry.envPassthrough to what one call needs (e.g. SSH_AUTH_SOCK
// only for commit-push's push/fetch steps). Omitted -> unchanged full-set behavior.
//
// A present-but-not-an-array envScope THROWS rather than falling back to the full
// set: a typo such as `envScope: "SSH_AUTH_SOCK"` would otherwise silently widen
// the call back to full passthrough — every credential the entry declares reaching
// a child the author meant to starve, at a call site that reads as if it were
// scoped. Only omission means "no narrowing intended". See spawn.md "envScope".
function buildEnv(entry, anchors, extraEnv, envScope) {
  if (envScope !== undefined && !Array.isArray(envScope)) {
    throw new Error("child env scope must be an array of env var names");
  }
  const full = Array.isArray(entry.envPassthrough) ? entry.envPassthrough : [];
  const declared = envScope === undefined ? full : full.filter((name) => envScope.includes(name));
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

// run(entry, { anchors, command, script, args, cwd, timeoutMs, extraEnv, envScope, input })
// Returns { status, signal, timedOut, spawnError, stdout, stderr }.
//
// `input` is the ONLY way payload-derived free text reaches a child, and opting in
// is per-call: with `input` omitted the child gets stdio[0] = "ignore" exactly as
// before. Why stdin rather than argv: spawn.md "Why `input` (stdin) exists".
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

  const hasInput = opts.input !== undefined && opts.input !== null;
  if (hasInput && typeof opts.input !== "string" && !Buffer.isBuffer(opts.input)) {
    throw new Error("child stdin input must be a string or Buffer");
  }

  const spawnOpts = {
    cwd,
    env: buildEnv(entry, anchors, opts.extraEnv, opts.envScope),
    shell: false,
    encoding: "utf8",
    timeout,
    windowsHide: true,
    maxBuffer: MAX_BUFFER,
    stdio: [hasInput ? "pipe" : "ignore", "pipe", "pipe"],
  };
  // Set only when opted in: spawnSync treats a present-but-undefined `input` the
  // same as an absent one today, but relying on that would make the no-input path
  // depend on an implementation detail instead of on the option being absent.
  if (hasInput) spawnOpts.input = opts.input;

  const res = spawnSync(opts.command, argv, spawnOpts);

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
