"use strict";
// World of tests/hooks/feat-pm-hook-budget.js (#3152). No case markers.
// A virtual clock (Date.now) and a fake spawnSync (deps.spawnSync) that answers every spawn of one hook run:
// git remote get-url, gh (a read is answered by ../../bin/feature-2941-pm-state-cli/fake-gh.js, spawned with the
// real spawnSync and its own run time taken off the clock; a GraphQL mutation is answered in process), and the
// board scripts (resolve-board.sh, ensure-board-card.sh). Each call sleeps delay(call) virtual ms; past
// opts.timeout it is killed (ETIMEDOUT). Load this before any hook module: it wraps child_process so a spawn
// that bypasses deps.spawnSync is recorded as a stray (and still runs, against the fake gh on PATH).
const cp = require("node:child_process");
const path = require("node:path");
const { performance } = require("node:perf_hooks");

const FAKE_GH = path.join(__dirname, "..", "..", "bin", "feature-2941-pm-state-cli", "fake-gh.js");
const real = { spawnSync: cp.spawnSync, execFileSync: cp.execFileSync, execSync: cp.execSync, spawn: cp.spawn, execFile: cp.execFile, exec: cp.exec };
const strays = [];
let armed = false;
for (const k of Object.keys(real)) {
  cp[k] = function guarded(cmd, args) {
    if (armed) strays.push({ kind: kindOf(cmd, Array.isArray(args) ? args : []), line: `${k}: ${[cmd].concat(Array.isArray(args) ? args : []).join(" ")}` });
    return real[k].apply(cp, arguments);
  };
}

const kill = (code) => Object.assign(new Error(`spawnSync ${code}`), { code, errno: code, syscall: "spawnSync" });

// ghArgsOf(cmd, args) -> the gh argv of a gh spawn (bare gh, or buildGhSpawn's bash -c 'exec "$0" "$@"' gh ...), else null.
function ghArgsOf(cmd, a) {
  if (cmd === "gh") return a;
  if (cmd === "bash" && a[0] === "-c" && a[2] === "gh") return a.slice(3);
  return null;
}
function kindOf(cmd, a) {
  const gh = ghArgsOf(cmd, a);
  if (gh) return gh[0] === "api" && gh[1] === "graphql" ? "graphql" : "gh-other";
  if (cmd === "git" || (cmd === "bash" && a[0] === "-c" && a[2] === "git")) return "git";
  if (cmd === "bash" && /resolve-board\.sh$/.test(String(a[0] || ""))) return "resolve-board";
  if (cmd === "bash" && /ensure-board-card\.sh$/.test(String(a[0] || ""))) return "ensure-card";
  return "other";
}

// mutationAliases(body) -> [{alias, clear, itemId, text}] of a `m<i>: update|clearProjectV2ItemFieldValue(...)` mutation,
// the input written inline or as a variable.
function mutationAliases(body) {
  const q = String(body.query || "");
  const vars = body.variables || {};
  const unq = (s) => JSON.parse(`"${s}"`);
  const pick = (seg, key) => {
    const m = new RegExp(`${key}\\s*:\\s*(?:"((?:[^"\\\\]|\\\\.)*)"|\\$(\\w+))`).exec(seg);
    if (!m) return undefined;
    return m[1] !== undefined ? unq(m[1]) : vars[m[2]];
  };
  const parts = q.split(/\b(m\d+)\s*:\s*(update|clear)ProjectV2ItemFieldValue\b/);
  const out = [];
  for (let i = 1; i + 2 < parts.length; i += 3) {
    const seg = parts[i + 2] || "";
    const inVar = /input\s*:\s*\$(\w+)/.exec(seg);
    const input = inVar ? (vars[inVar[1]] || {}) : null;
    const itemId = input ? input.itemId : pick(seg, "itemId");
    const text = input ? (input.value && input.value.text) : pick(seg, "text");
    out.push({ alias: parts[i], clear: parts[i + 1] === "clear", itemId, text });
  }
  return out;
}

// createWorld({G, origin?, delay?, fail?, onEnsure?}) -> the clock, the fake spawnSync and its call log.
// delay(call) / fail(call) see {kind, gh, index, kindIndex}; fail returns an error code (e.g. "ENOENT") or null.
function createWorld(o) {
  const G = o.G;
  const base = Date.now();
  const p0 = performance.now();
  let offset = 0;
  const now = () => base + (performance.now() - p0) + offset;
  const calls = [];
  const perKind = {};
  function answer(kind, cmd, a, opts) {
    if (kind === "git") {
      const isUrl = a.includes("remote") && a.includes("get-url");
      return isUrl && o.origin !== null ? { status: 0, stdout: `${o.origin || "https://github.com/o/r.git"}\n`, stderr: "" } : { status: 1, stdout: "", stderr: "fake git: no answer\n" };
    }
    if (kind === "resolve-board") return { status: 0, stdout: "status=resolved\nowner=o\nnumber=1\nproject_id=PVT_fake\n", stderr: "" };
    if (kind === "ensure-card") {
      const i = a.indexOf("--repo");
      if (typeof o.onEnsure === "function") o.onEnsure(a[i + 1], Number(a[i + 2]));
      return { status: 0, stdout: "", stderr: "" };
    }
    const gh = ghArgsOf(cmd, a);
    let body = null;
    try { body = JSON.parse(String(opts.input || "")); } catch (_) { body = null; }
    if (kind === "graphql" && body && /^\s*mutation\b/.test(String(body.query || ""))) {
      const store = G.pmStore();
      const data = {};
      for (const m of mutationAliases(body)) {
        if (typeof m.itemId !== "string") continue;
        store[m.itemId] = m.clear ? null : (m.text === undefined ? null : m.text);
        data[m.alias] = { projectV2Item: { id: m.itemId } };
      }
      G.setPmStore(store);
      return { status: 0, stdout: `${JSON.stringify({ data })}\n`, stderr: "" };
    }
    const t = performance.now();
    const r = real.spawnSync(process.execPath, [FAKE_GH].concat(gh || []), { input: opts.input, encoding: "utf8", env: process.env, timeout: 60000 });
    offset -= performance.now() - t;
    return { status: r.status, stdout: r.stdout, stderr: r.stderr };
  }
  function spawnSync(cmd, args, opts) {
    const a = Array.isArray(args) ? args : [];
    const so = opts || {};
    const kind = kindOf(cmd, a);
    perKind[kind] = (perKind[kind] || 0) + 1;
    const call = { kind, index: calls.length, kindIndex: perKind[kind] - 1, cmd, args: a, timeout: so.timeout, start: now() };
    if (kind === "graphql") {
      try { call.query = String(JSON.parse(String(so.input || "")).query || ""); } catch (_) { call.query = (a.find((x) => /^query=/.test(String(x))) || "").slice("query=".length); }
      call.mutation = /^\s*mutation\b/.test(call.query);
    }
    calls.push(call);
    const code = typeof o.fail === "function" ? o.fail(call) : null;
    if (code) { call.end = now(); call.outcome = code; return { pid: 0, status: null, signal: null, stdout: "", stderr: "", output: [], error: kill(code) }; }
    const ms = typeof o.delay === "function" ? Number(o.delay(call)) || 0 : 0;
    const limit = Number.isFinite(so.timeout) && so.timeout > 0 ? so.timeout : Infinity;
    if (ms > limit) {
      offset += limit;
      call.end = now();
      call.outcome = "ETIMEDOUT";
      return { pid: 0, status: null, signal: "SIGTERM", stdout: "", stderr: "", output: [], error: kill("ETIMEDOUT") };
    }
    const r = answer(kind, cmd, a, so);
    offset += ms;
    call.end = now();
    call.outcome = r.status === 0 ? "ok" : `exit ${r.status}`;
    return Object.assign({ pid: 1, signal: null, output: [null, r.stdout, r.stderr] }, r);
  }
  // run(fn) -> fn() with Date.now on the virtual clock and strays recorded; both restored after.
  function run(fn) {
    const saved = Date.now;
    const before = strays.length;
    Date.now = () => Math.floor(now());
    armed = true;
    try { return fn(); } finally {
      armed = false;
      Date.now = saved;
      o.lastStrays = strays.slice(before);
    }
  }
  return { now, spawnSync, calls, run, strays: () => o.lastStrays || [] };
}

module.exports = { createWorld, mutationAliases, FAKE_GH };
