"use strict";
// Sandbox runner for the scan-outbound CLI (#2507). The scanner copy lives outside any git repo,
// so its list anchor falls back to <sandbox>/bin/.. and it reads only the synthetic fixture lists
// written here — never the repository's real lists. Shared by the golden generator and the test.

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const REPO = path.resolve(__dirname, "..", "..", "..");

// Code the CLI may load: the bash entry, its Node side (once it exists), and both lib trees.
const COPY = ["bin/scan-outbound.sh", "bin/scan-outbound.d", "bin/lib", "hooks/lib"];

// The locale a real `git commit` hands its hook on this host (probed: LANG / LC_ALL unset,
// LC_CTYPE=C.UTF-8). The golden is recorded under it, so bash regex is UTF-8 char-wise.
const LOCALE = { LC_CTYPE: "C.UTF-8" };
const LOCALE_DROP = ["LANG", "LC_ALL", "LC_CTYPE", "AGENTS_MAIN_ROOT", "CLAUDE_CODE_SESSION_ID"];

function createSandbox() {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "t2507-scan-")));
  for (const rel of COPY) {
    const src = path.join(REPO, rel);
    if (!fs.existsSync(src)) continue;
    fs.cpSync(src, path.join(root, rel), { recursive: true });
  }
  return root;
}

function setLists(root, lists) {
  for (const [key, name] of [["blocklist", ".private-info-blocklist"], ["allowlist", ".private-info-allowlist"]]) {
    const p = path.join(root, name);
    fs.rmSync(p, { force: true });
    if (lists[key] !== null && lists[key] !== undefined) fs.writeFileSync(p, lists[key]);
  }
}

function baseEnv(extra) {
  const env = { ...process.env };
  for (const k of LOCALE_DROP) delete env[k];
  return { ...env, ...LOCALE, ...(extra || {}) };
}

// locale "C": the one case whose intended behavior bash shows only byte-wise (see corpus.js).
function runCli(root, { argv, stdin, files, env, locale }) {
  if (!env && locale === "C") env = baseEnv({ LC_ALL: "C" });
  for (const [rel, buf] of Object.entries(files || {})) {
    fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
    fs.writeFileSync(path.join(root, rel), buf);
  }
  const r = spawnSync("bash", [path.join(root, "bin", "scan-outbound.sh"), ...argv], {
    cwd: root,
    input: stdin || Buffer.alloc(0),
    env: env || baseEnv(),
    timeout: 60000,
  });
  return { rc: r.status, stdout: normalize(root, r.stdout), stderr: normalize(root, r.stderr), error: r.error };
}

// The sandbox root appears in warnings (list paths) in whatever spelling the shell uses
// (C:\..., C:/..., /c/..., MSYS /tmp/...). Its mkdtemp basename is unique, so fold any
// non-space run ending in it to <SANDBOX>.
function normalize(root, buf) {
  const s = (buf || Buffer.alloc(0)).toString("utf8");
  const base = path.basename(root).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return s.replace(new RegExp(`[^\\s'"]*${base}`, "g"), "<SANDBOX>");
}

function removeSandbox(root) {
  fs.rmSync(root, { recursive: true, force: true });
}

module.exports = { REPO, LOCALE, createSandbox, setLists, baseEnv, runCli, normalize, removeSandbox };
