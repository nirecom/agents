"use strict";
// tests/lib/gh-scripted-stub.js — a gh stand-in answering from a JSON script (#2940 tests).
// makeStubGh(dir, spec) -> { bin, env, calls(), resetCalls(), setSpec() }; bin holds `gh` (a bash
// script for bash) and on Windows gh.exe, a node copy the preload turns into the same stub.
// CLI: `node gh-scripted-stub.js setup <dir>` prints the bin dir and the preload path.
// spec: { rules: [{ match, flags, stdout, stderr, exit, sleepMs }], fallback }: the first rule whose
// regex hits the space-joined args answers (object stdout printed as JSON); else fallback, else exit 0.
// Each call is logged as one JSON line; stdin is read only when an argument is `-`.

const fs = require("node:fs");
const path = require("node:path");

const fwd = (p) => p.replace(/\\/g, "/");
const SELF = fwd(__filename);
const PRELOAD = fwd(path.join(__dirname, "gh-scripted-stub-preload.js"));
const BODY_FILE_FLAGS = new Set(["-F", "--body-file"]);

function writeBin(dir) {
  const bin = path.join(dir, "bin");
  fs.mkdirSync(bin, { recursive: true });
  // A bash script naming this file by its mixed path: under MSYS_NO_PATHCONV=1 a node shebang
  // would get the script's /tmp/... path unconverted.
  fs.writeFileSync(path.join(bin, "gh"), `#!/usr/bin/env bash\nexec node ${JSON.stringify(SELF)} run "$@"\n`, { mode: 0o755 });
  if (process.platform === "win32") {
    const exe = path.join(bin, "gh.exe");
    if (!fs.existsSync(exe)) {
      try { fs.linkSync(process.execPath, exe); } catch (_e) { fs.copyFileSync(process.execPath, exe); }
    }
  }
  return fwd(bin);
}

function makeStubGh(dir, spec = {}) {
  const bin = writeBin(dir);
  const specFile = fwd(path.join(dir, "gh-spec.json"));
  const logFile = fwd(path.join(dir, "gh-calls.jsonl"));
  const setSpec = (next) => fs.writeFileSync(specFile, JSON.stringify(next || {}));
  setSpec(spec);
  const env = {
    PATH: `${bin}${path.delimiter}${process.env.PATH}`,
    NODE_OPTIONS: `--require "${PRELOAD}"`,
    F2940_GH_SPEC: specFile,
    F2940_GH_LOG: logFile,
  };
  const calls = () => (fs.existsSync(logFile)
    ? fs.readFileSync(logFile, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []);
  const resetCalls = () => { try { fs.rmSync(logFile, { force: true }); } catch (_e) { /* none yet */ } };
  return { bin, env, specFile, logFile, calls, resetCalls, setSpec };
}

function sleepMs(ms) {
  if (ms > 0) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function readMaybe(file) {
  try { return fs.readFileSync(file, "utf8"); } catch (_e) { return null; }
}

function runStub(args) {
  const specFile = process.env.F2940_GH_SPEC;
  const logFile = process.env.F2940_GH_LOG;
  let spec = {};
  try { spec = JSON.parse(fs.readFileSync(specFile, "utf8")); } catch (e) {
    fs.writeSync(2, `gh-scripted-stub: unreadable spec ${specFile}: ${e.message}\n`);
    process.exit(97);
  }
  let bodyFile = null;
  let stdin = null;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    const eq = a.startsWith("--body-file=") ? a.slice("--body-file=".length) : null;
    const val = eq !== null ? eq : (BODY_FILE_FLAGS.has(a) && args[0] === "issue" ? args[i + 1] : undefined);
    if (val === undefined) continue;
    if (val === "-") { stdin = readMaybe(0); bodyFile = stdin; } else bodyFile = readMaybe(val);
  }
  if (stdin === null && args.some((a, i) => a === "--input" && args[i + 1] === "-")) stdin = readMaybe(0);
  if (logFile) {
    const rec = { args, cwd: fwd(process.cwd()), msysNoPathconv: process.env.MSYS_NO_PATHCONV || null, bodyFile, stdin };
    fs.appendFileSync(logFile, JSON.stringify(rec) + "\n");
  }
  const joined = args.join(" ");
  const rule = (spec.rules || []).find((r) => new RegExp(r.match, r.flags || "s").test(joined)) || spec.fallback || {};
  sleepMs(Number(rule.sleepMs || 0));
  const out = rule.stdout === undefined ? "" : (typeof rule.stdout === "string" ? rule.stdout : JSON.stringify(rule.stdout));
  if (out) fs.writeSync(1, out.endsWith("\n") ? out : `${out}\n`);
  if (rule.stderr) fs.writeSync(2, rule.stderr.endsWith("\n") ? rule.stderr : `${rule.stderr}\n`);
  process.exit(Number(rule.exit || 0));
}

module.exports = { makeStubGh, runStub, writeBin, PRELOAD };

if (require.main === module && process.argv[2] === "run") runStub(process.argv.slice(3));
if (require.main === module && process.argv[2] === "setup" && process.argv[3]) {
  process.stdout.write(`${writeBin(process.argv[3])}\n${PRELOAD}\n`);
}
