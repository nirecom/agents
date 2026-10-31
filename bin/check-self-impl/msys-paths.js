"use strict";
// A manifest written by a Git Bash caller names its copies in MSYS form (/tmp/..., drive letters as /c), which
// MSYS converts for argv but never inside a file. nativeMap(paths, env) -> Map(original -> path
// Node can open): one cygpath -m call on win32, the identity elsewhere or when cygpath is absent.

const { resolveCygpath } = require("../../hooks/lib/cygpath-locate");
const { toWindowsPath } = require("../../hooks/lib/branch-diff");

const TIMEOUT_MS = 10000;
const MSYS_ONLY = /^\/(?![a-zA-Z](\/|$))/;

function nativeMap(paths, env, platform = process.platform) {
  const map = new Map();
  const todo = [];
  for (const p of paths) {
    if (!p || map.has(p)) continue;
    map.set(p, toWindowsPath(p));
    if (platform === "win32" && MSYS_ONLY.test(p)) todo.push(p);
  }
  if (todo.length === 0) return map;
  const exe = resolveCygpath({ env, platform });
  if (!exe) return map;
  const cp = require("node:child_process");
  const r = cp.spawnSync(exe, ["-m", "--", ...todo], { encoding: "utf8", timeout: TIMEOUT_MS, windowsHide: true });
  if (r.error || r.status !== 0) return map;
  const out = String(r.stdout || "").split(/\r?\n/);
  todo.forEach((p, i) => { if (out[i]) map.set(p, out[i]); });
  return map;
}

module.exports = { nativeMap };
