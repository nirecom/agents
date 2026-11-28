"use strict";
// Shared #1889 / #3043 fixture: a `gh` on PATH that answers `gh issue view <N> [--repo r] ...`
// per issue, reachable from a shell-less spawnSync on every platform. Not a test on its own.
// <dir>/gh(.exe) are links/copies of the node binary; the preload answers only in a process whose
// own binary is named gh and stays inert in every other node process (as tests/lib/cli-stub.sh).
// Answer map keys: `<repo>#<N>` (repo lowercased, matched first when --repo is passed) or `<N>`.
// Values: CLOSED / OPEN (printed bare under --jq, else as {"state":...}); FAIL or absent = exit 1.

const fs = require("node:fs");
const path = require("node:path");

const PRELOAD_SRC = [
  'const path = require("path"); const fs = require("fs");',
  'if (path.basename(process.execPath).replace(/\\.exe$/i, "").toLowerCase() === "gh") {',
  '  const a = process.argv.slice(1); if (a.length) a[0] = path.basename(a[0]);',
  '  if (process.env.GH_STUB_LOG) fs.appendFileSync(process.env.GH_STUB_LOG, JSON.stringify(a) + "\\n");',
  '  const map = JSON.parse(process.env.GH_STUB_MAP || "{}");',
  '  const n = a.find((x) => /^[0-9]+$/.test(x)); const ri = a.indexOf("--repo");',
  '  const repo = ri >= 0 ? String(a[ri + 1] || "").toLowerCase() : "";',
  '  const v = (repo && map[repo + "#" + n]) || map[n];',
  '  if (!v || v === "FAIL") { fs.writeSync(2, "gh stub: no answer\\n"); process.exit(1); }',
  '  fs.writeSync(1, a.includes("--jq") ? v + "\\n" : JSON.stringify({ state: v }) + "\\n");',
  '  process.exit(0);',
  '}',
].join("\n");

const pathKey = (env) => Object.keys(env).find((k) => k.toUpperCase() === "PATH") || "PATH";

// makeGhStub(dir) — builds the stub under <dir>; returns { env(map), calls(env), apply(env) }.
function makeGhStub(dir) {
  fs.mkdirSync(dir, { recursive: true });
  for (const n of ["gh", "gh.exe"]) {
    const p = path.join(dir, n);
    try { fs.linkSync(process.execPath, p); } catch (_) { fs.copyFileSync(process.execPath, p); }
  }
  const preload = path.join(dir, "gh-stub-preload.js");
  fs.writeFileSync(preload, PRELOAD_SRC);
  let seq = 0;
  // env(map) — process.env with the stub first on PATH, the preload on, and a fresh call log.
  function env(map) {
    const e = Object.assign({}, process.env);
    const key = pathKey(e);
    e[key] = dir + path.delimiter + (e[key] || "");
    e.NODE_OPTIONS = `${e.NODE_OPTIONS ? e.NODE_OPTIONS + " " : ""}--require "${preload.replace(/\\/g, "/")}"`;
    e.GH_STUB_MAP = JSON.stringify(map || {});
    e.GH_STUB_LOG = path.join(dir, `gh-${++seq}.log`);
    delete e.CLAUDE_CODE_SESSION_ID;
    return e;
  }
  // calls(env) — each gh invocation's argv (argv[0] = "issue"), in order.
  function calls(e) {
    try {
      return fs.readFileSync(e.GH_STUB_LOG, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
    } catch (_) { return []; }
  }
  // withEnv(e, fn) — runs fn with this process's PATH / NODE_OPTIONS / GH_STUB_* taken from e.
  function withEnv(e, fn) {
    const names = [pathKey(process.env), "NODE_OPTIONS", "GH_STUB_MAP", "GH_STUB_LOG"];
    const saved = names.map((n) => process.env[n]);
    names.forEach((n, i) => { process.env[n] = e[i === 0 ? pathKey(e) : n]; });
    try { return fn(); } finally {
      names.forEach((n, i) => { if (saved[i] === undefined) delete process.env[n]; else process.env[n] = saved[i]; });
    }
  }
  return { dir, env, calls, withEnv };
}

module.exports = { makeGhStub };
