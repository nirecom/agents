"use strict";
// Deadline-bounded child process (#2658): on timeout the whole process tree is killed.

const { spawn } = require("node:child_process");

// killTree — on Windows taskkill /T needs about a second to walk the tree, so it runs
// detached and the deadline returns at once; elsewhere the process group dies synchronously.
function killTree(child) {
  if (process.platform === "win32") {
    try {
      spawn("taskkill", ["/T", "/F", "/PID", String(child.pid)], { stdio: "ignore", windowsHide: true, detached: true }).unref();
    } catch (_) { /* taskkill missing: nothing more to do */ }
    return;
  }
  try {
    process.kill(-child.pid, "SIGKILL");
  } catch (_) {
    try { child.kill("SIGKILL"); } catch (_e) { /* already gone */ }
  }
}

function run(cmd, args, { deadlineMs, env, cwd } = {}) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, {
      env: env || process.env, cwd, windowsHide: true,
      // detached everywhere: a process group on POSIX; on Windows it keeps the tree out of
      // node's kill-on-exit job, so the background taskkill can still walk it.
      detached: true, stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    let settled = false;
    const finish = (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ code, timedOut, stdout, stderr });
    };
    const timer = deadlineMs > 0 ? setTimeout(() => {
      timedOut = true;
      killTree(child);
      // A dying tree must not hold this process open through its pipes.
      child.stdout.destroy();
      child.stderr.destroy();
      child.unref();
      finish(null);
    }, deadlineMs) : null;
    child.stdout.on("data", (d) => { stdout += d; });
    child.stderr.on("data", (d) => { stderr += d; });
    child.on("error", (e) => { stderr += String(e.message); finish(null); });
    child.on("close", (code) => finish(timedOut ? null : code));
  });
}

module.exports = { run, killTree };
