"use strict";
// hooks/lib/cygpath-locate.js — find Git for Windows' cygpath.exe and wrap it as the
// converter that planRepair (shell-snapshot-path.js) expects (#2221). The hook runs while
// the snapshot PATH may be broken, so cygpath is located from the Windows side, never via
// the snapshot. Not win32 -> no converter (the repair reports cygpath-unavailable).

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { MSYS_HEAD_CANDIDATES } = require("./shell-snapshot-path");

const w = path.win32;

function pathElements(env) {
  const raw = env.PATH !== undefined ? env.PATH : (env.Path !== undefined ? env.Path : "");
  return String(raw || "").split(";").map((s) => s.trim().replace(/^"(.*)"$/, "$1")).filter((s) => s !== "");
}

// Candidates in order: CLAUDE_CODE_GIT_BASH_PATH, cygpath.exe on PATH, <git>\cmd\git.exe
// on PATH, %ProgramFiles%\Git. The first that exists wins.
function resolveCygpath({ env = process.env, platform = process.platform, existsSync = fs.existsSync } = {}) {
  if (platform !== "win32") return null;
  const tryOne = (p) => { try { return existsSync(p) ? p : null; } catch (_) { return null; } };
  const gb = env.CLAUDE_CODE_GIT_BASH_PATH;
  if (gb) {
    const d = w.dirname(String(gb));
    const hit = /[\\/]usr[\\/]bin$/i.test(d) ? tryOne(w.join(d, "cygpath.exe"))
      : (/[\\/]bin$/i.test(d) ? tryOne(w.join(w.dirname(d), "usr", "bin", "cygpath.exe")) : null);
    if (hit) return hit;
  }
  const els = pathElements(env);
  for (const e of els) {
    const hit = tryOne(w.join(e, "cygpath.exe"));
    if (hit) return hit;
  }
  for (const e of els) {
    if (!/[\\/]cmd[\\/]?$/i.test(e) || !tryOne(w.join(e, "git.exe"))) continue;
    const hit = tryOne(w.join(w.dirname(e.replace(/[\\/]+$/, "")), "usr", "bin", "cygpath.exe"));
    if (hit) return hit;
  }
  if (env.ProgramFiles) {
    const hit = tryOne(w.join(String(env.ProgramFiles), "Git", "usr", "bin", "cygpath.exe"));
    if (hit) return hit;
  }
  return null;
}

function budgetError() {
  const e = new Error("cygpath skipped: time budget exhausted");
  e.code = "time-budget";
  return e;
}

// timeoutFor() gives each spawn its slice of the hook budget; 0 means do not spawn.
function makeCygpathDeps(exe, { timeoutFor = () => 2000, existsSync = fs.existsSync, spawn = spawnSync } = {}) {
  let heads = null;
  const run = (args) => {
    const t = Math.floor(Number(timeoutFor()) || 0);
    if (t <= 0) throw budgetError();
    const r = spawn(exe, args, { encoding: "utf8", timeout: t, windowsHide: true, stdio: ["ignore", "pipe", "ignore"] });
    if (r.error || r.status !== 0 || typeof r.stdout !== "string") throw new Error("cygpath failed: " + String((r.error && r.error.code) || r.status));
    return r.stdout.replace(/\r?\n$/, "");
  };
  return {
    toPosixList(list) { return run(["-u", "-p", "--", list]); },
    msysHeadExisting() {
      if (!heads) {
        const out = run(["-w", "--"].concat(MSYS_HEAD_CANDIDATES)).split(/\r?\n/);
        heads = MSYS_HEAD_CANDIDATES.filter((h, i) => {
          const p = (out[i] || "").trim();
          try { return p !== "" && existsSync(p); } catch (_) { return false; }
        });
      }
      return heads.slice();
    },
  };
}

module.exports = { resolveCygpath, makeCygpathDeps };
