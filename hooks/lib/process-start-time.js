"use strict";
// The start time of a process (#2942): the PM lock tells a live holder from a reused pid by it.
// startTimeOf(pid, {timeoutMs, platform?, spawnSync?, readFileSync?}) -> {ok:true, ms} | {ok:false, reason}.
// linux reads /proc (no spawn); darwin runs ps; win32 runs PowerShell Get-Process. Any failure is
// {ok:false}, which the caller reads as "cannot tell", never as "dead".

const LINUX_CLK_TCK = 100;
const START_FIELD = 22;

function linux(pid, readFileSync) {
  const stat = String(readFileSync(`/proc/${pid}/stat`, "utf8"));
  // Fields after the last ")" start at field 3 (the comm field may hold spaces and parentheses).
  const rest = stat.slice(stat.lastIndexOf(")") + 1).trim().split(/\s+/);
  const ticks = Number(rest[START_FIELD - 3]);
  const m = /^btime\s+(\d+)/m.exec(String(readFileSync("/proc/stat", "utf8")));
  if (!Number.isFinite(ticks) || !m) return { ok: false, reason: "parse_failed" };
  return { ok: true, ms: Number(m[1]) * 1000 + ticks * (1000 / LINUX_CLK_TCK) };
}

function spawned(r, parse) {
  if (!r || r.error) return { ok: false, reason: r && r.error && r.error.code === "ETIMEDOUT" ? "timeout" : "spawn_failed" };
  if (r.status !== 0) return { ok: false, reason: "no_such_process" };
  const ms = parse(String(r.stdout || "").trim());
  return Number.isFinite(ms) ? { ok: true, ms } : { ok: false, reason: "parse_failed" };
}

function startTimeOf(pid, opts) {
  const o = opts || {};
  const platform = o.platform || process.platform;
  const spawnSync = o.spawnSync || require("child_process").spawnSync;
  const readFileSync = o.readFileSync || require("fs").readFileSync;
  const timeout = Number.isFinite(o.timeoutMs) ? o.timeoutMs : 1000;
  if (!Number.isInteger(Number(pid)) || Number(pid) <= 0) return { ok: false, reason: "bad_pid" };
  try {
    if (platform === "linux") return linux(Number(pid), readFileSync);
    if (platform === "darwin") {
      return spawned(spawnSync("ps", ["-o", "lstart=", "-p", String(pid)], { encoding: "utf8", timeout, windowsHide: true }), (s) => new Date(s).getTime());
    }
    if (platform === "win32") {
      const cmd = `(Get-Process -Id ${Number(pid)}).StartTime.ToUniversalTime().ToString('o')`;
      return spawned(spawnSync("powershell", ["-NoProfile", "-NonInteractive", "-Command", cmd], { encoding: "utf8", timeout, windowsHide: true }), (s) => (s ? Date.parse(s) : NaN));
    }
    return { ok: false, reason: "unsupported_platform" };
  } catch (e) {
    return { ok: false, reason: `read_failed: ${e.message}` };
  }
}

// selfStartTimeMs() -> this process's start time, without spawning anything.
const selfStartTimeMs = () => Date.now() - process.uptime() * 1000;

module.exports = { startTimeOf, selfStartTimeMs };
