"use strict";
// Makes eslint resolvable from a lint root (the directory holding eslint.config.*). `npm ci` runs
// only when the lint root is a worktree top-level of the wrapper's own repository, or
// RUN_ESLINT_PROVISION=1 opts in: npm ci rebuilds node_modules, which must never happen silently
// in someone else's repository. Whether the install matches package-lock.json is one comparison
// against a sha256 stamp the last npm ci left.
const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..");

const STAMP_NAME = ".run-eslint-lock.sha256";
const NPM_TIMEOUT_MS = 300 * 1000;
const LOCK_WAIT_MS = 300 * 1000;
const LOCK_RETRY_MS = 500;
const LOCK_STALE_MS = 600 * 1000;
const GIT_TIMEOUT_MS = 10 * 1000;

const hash = (algo, data) => crypto.createHash(algo).update(data).digest("hex");
const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

function gitOut(cwd, args) {
  const r = spawnSync("git", args, { cwd, encoding: "utf8", timeout: GIT_TIMEOUT_MS });
  if (r.error || r.status !== 0) return null;
  return (r.stdout || "").trim() || null;
}

function canon(p) {
  let out = path.resolve(p);
  try {
    out = fs.realpathSync.native(out);
  } catch {
    // keep the resolved form when the path cannot be canonicalized
  }
  return process.platform === "win32" ? out.toLowerCase() : out;
}

function commonDir(dir) {
  const out = gitOut(dir, ["rev-parse", "--git-common-dir"]);
  return out ? canon(path.resolve(dir, out)) : null;
}

// True when lintRoot is a worktree top-level (main checkout or linked worktree) of the
// repository that holds wrapperRoot.
function isSameRepository(lintRoot, wrapperRoot) {
  const mine = commonDir(wrapperRoot);
  const theirs = commonDir(lintRoot);
  if (!mine || !theirs || mine !== theirs) return false;
  const top = gitOut(lintRoot, ["rev-parse", "--show-toplevel"]);
  return top !== null && canon(top) === canon(lintRoot);
}

function resolveEslint(lintRoot) {
  try {
    return require.resolve("eslint", { paths: [lintRoot] });
  } catch {
    return null;
  }
}

// The copy npm ci installed under lintRoot itself; an ancestor's eslint is not the locked version.
function resolveLocalEslint(lintRoot) {
  const found = resolveEslint(lintRoot);
  if (!found) return null;
  const rel = path.relative(canon(path.join(lintRoot, "node_modules")), canon(found));
  return rel.startsWith("..") || path.isAbsolute(rel) ? null : found;
}

function npmCliPath() {
  if (process.env.RUN_ESLINT_NPM_CLI) return process.env.RUN_ESLINT_NPM_CLI;
  const execDir = path.dirname(process.execPath);
  return process.platform === "win32"
    ? path.join(execDir, "node_modules", "npm", "bin", "npm-cli.js")
    : path.join(execDir, "..", "lib", "node_modules", "npm", "bin", "npm-cli.js");
}

function runNpmCi(lintRoot) {
  const cli = npmCliPath();
  if (!fs.existsSync(cli)) return `npm not found (no ${cli})`;
  process.stderr.write(`run-eslint: npm ci in ${lintRoot}\n`);
  const r = spawnSync(process.execPath, [cli, "ci", "--include=dev", "--no-audit", "--no-fund", "--ignore-scripts"], {
    cwd: lintRoot, encoding: "utf8", timeout: NPM_TIMEOUT_MS, stdio: ["ignore", "pipe", "pipe"], maxBuffer: 64 * 1024 * 1024,
  });
  if (r.error && r.error.code === "ETIMEDOUT") return `npm ci timed out after ${NPM_TIMEOUT_MS / 1000} s in ${lintRoot}`;
  if (r.error) return `npm ci could not start in ${lintRoot}: ${r.error.message}`;
  if (r.status !== 0) {
    const tail = (r.stderr || "").trim().split(/\r?\n/).slice(-5).join(" | ");
    return `npm ci failed in ${lintRoot} (exit ${r.status}): ${tail}`;
  }
  return null;
}

// Returns true when the lock dir was taken, or a skip reason.
function acquireLock(lockDir) {
  const deadline = Date.now() + LOCK_WAIT_MS;
  for (;;) {
    try {
      fs.mkdirSync(lockDir);
      return true;
    } catch (e) {
      if (e.code !== "EEXIST") return `provision lock unavailable (${lockDir}: ${e.code || e.message})`;
    }
    let age;
    try {
      age = Date.now() - fs.statSync(lockDir).mtimeMs;
    } catch {
      continue;
    }
    if (age > LOCK_STALE_MS) {
      fs.rmSync(lockDir, { recursive: true, force: true });
      continue;
    }
    if (Date.now() >= deadline) return `provision lock busy (${lockDir})`;
    sleep(LOCK_RETRY_MS);
  }
}

function readStamp(file) {
  try {
    return fs.readFileSync(file, "utf8").trim();
  } catch {
    return null;
  }
}

function provisionLocked(lintRoot, lockFile) {
  const want = hash("sha256", fs.readFileSync(lockFile));
  const stamp = path.join(lintRoot, "node_modules", STAMP_NAME);
  const found = resolveLocalEslint(lintRoot);
  if (found && readStamp(stamp) === want) return { eslintPath: found };
  const failed = runNpmCi(lintRoot);
  if (failed) return { reason: failed };
  fs.mkdirSync(path.dirname(stamp), { recursive: true });
  fs.writeFileSync(stamp, `${want}\n`);
  const after = resolveLocalEslint(lintRoot);
  return after ? { eslintPath: after } : { reason: `eslint is not resolvable in ${lintRoot} after npm ci` };
}

// provision(lintRoot) -> { eslintPath } | { reason }
function provision(lintRoot) {
  const allowed = process.env.RUN_ESLINT_PROVISION === "1" || isSameRepository(lintRoot, SCRIPT_CHECKOUT_ROOT);
  const lockFile = path.join(lintRoot, "package-lock.json");
  if (!allowed || !fs.existsSync(lockFile)) {
    const found = resolveEslint(lintRoot);
    if (found) return { eslintPath: found };
    return {
      reason: allowed
        ? `no package-lock.json in ${lintRoot}`
        : `eslint not installed in ${lintRoot}; auto-install is limited to the agents repository (set RUN_ESLINT_PROVISION=1 to opt in)`,
    };
  }
  const lockDir = path.join(os.tmpdir(), `run-eslint-${hash("sha1", lintRoot)}.lock`);
  const taken = acquireLock(lockDir);
  if (taken !== true) return { reason: taken };
  try {
    return provisionLocked(lintRoot, lockFile);
  } finally {
    fs.rmSync(lockDir, { recursive: true, force: true });
  }
}

module.exports = { provision, isSameRepository, STAMP_NAME };
