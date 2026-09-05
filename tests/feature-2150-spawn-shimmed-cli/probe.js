#!/usr/bin/env node
// tests/feature-2150-spawn-shimmed-cli/probe.js
// Row evaluator for tests/feature-2150-spawn-shimmed-cli.sh (#2150).
// argv: [2] ROOT (agents dir the module is loaded FROM) [3] CASE_DIR (fixture
// root; reported paths are relative to it) [4] DIRS_FILE (one PATH entry per
// line, or the single token @none / @empty) [5] PATHEXT_SPEC (literal, @unset
// or @empty) [6] COMMAND_SPEC (literal or @empty) [7] FN (verdict | argv |
// opts | exec | execopts | direct | ref | posix). stdout: exactly one line, the
// `got` the table compares.
"use strict";

const fs = require("fs");
const path = require("path");

const ROOT = process.argv[2];
const CASE_DIR = process.argv[3];
const DIRS_FILE = process.argv[4];
const PATHEXT_SPEC = process.argv[5];
const COMMAND_SPEC = process.argv[6];
const FN = process.argv[7];

// One probe process per row, unlike the round-12 precedent's one-per-table:
// spawn-shimmed-cli.js memoizes resolveOnPath() in a module-level Map and reads
// process.env plus the real filesystem, so a shared process would let row N
// decide row N+1. Fixture build, not process spawn, dominates the cost anyway.

// Metacharacter-bearing on purpose: if any layer ever grew a shell, `x&y` and
// `$(id)` would not survive intact to the target's argv (concern C4).
const ARGS = ["--flag", "a b", "x&y", "$(id)"];

const out = (s) => process.stdout.write(String(s).replace(/[\r\n]+/g, " ") + "\n");

// --- environment shaping, before the module under test is loaded ------------
const dirs = fs
  .readFileSync(DIRS_FILE, "utf8")
  .split("\n")
  .map((s) => s.replace(/\r$/, ""))
  .filter((s) => s !== "");
if (dirs.length === 1 && dirs[0] === "@none") {
  // win32 process.env is case-insensitive, so this clears Path too — exactly
  // the "neither PATH nor Path is set" input pathDirs() must survive.
  delete process.env.PATH;
  delete process.env.Path;
} else if (dirs.length === 1 && dirs[0] === "@empty") {
  process.env.PATH = "";
} else {
  process.env.PATH = dirs.join(path.delimiter);
}

if (PATHEXT_SPEC === "@unset") delete process.env.PATHEXT;
else if (PATHEXT_SPEC === "@empty") process.env.PATHEXT = "";
else process.env.PATHEXT = PATHEXT_SPEC;

const command = COMMAND_SPEC === "@empty" ? "" : COMMAND_SPEC;

// The win32 branch is unreachable on Linux/macOS, so a suite that only ran it
// natively would be vacuously green on common CI (C5). Only path.sep /
// path.delimiter still follow the real host; the module uses path.join and
// path.delimiter throughout, so fixtures are host-shaped and verdicts are not.
Object.defineProperty(process, "platform", {
  value: FN === "posix" ? "linux" : "win32",
  configurable: true,
  writable: true,
});

// `verdict` / `argv` ask WHICH file the module decided to launch, so nothing is
// executed: the module destructures spawnSync at load, and this replacement is
// installed first. `exec` / `posix` keep the real one — they are the rows that
// prove the decision is also runnable.
const cp = require("child_process");
const calls = [];
if (FN === "verdict" || FN === "argv" || FN === "opts") {
  cp.spawnSync = function (c, a, o) {
    calls.push({ c: c, a: a, o: o });
    return { pid: 1, output: [null, null, null], stdout: null, stderr: null, status: 0, signal: null, error: null };
  };
}

let mod = null;
let loadErr = "";
try {
  mod = require(
    FN === "ref"
      ? path.join(ROOT, "tests", "lib", "shim-resolve-reference.js")
      : path.join(ROOT, "hooks", "lib", "spawn-shimmed-cli.js")
  );
} catch (e) {
  loadErr = String((e && e.message) || e);
}
if (!mod) {
  out("load-failed: " + loadErr.split("\n")[0]);
  process.exit(0);
}

const rel = (p) => path.relative(CASE_DIR, p).split(/[\\/]/).join("/");
const readMarker = (m) => {
  try { return fs.readFileSync(m, "utf8").trim(); } catch (_) { return "<no-marker>"; }
};

// --- caller-supplied options (C3) -------------------------------------------
// ONE realistic options object, every field a distinguishable non-default, so a
// helper that dropped, reordered or rewrote any of them shows up as a diff and
// not as a still-green run. `timeout` is bin/codegraph-lifecycle.js's own
// STATUS_TIMEOUT_MS (60000) — the only bound that file has on the binary.
const STATUS_TIMEOUT_MS = 60000;
const CUSTOM_ENV_VALUE = "cg-2150-custom";
function callerOptions() {
  return {
    timeout: STATUS_TIMEOUT_MS,
    cwd: CASE_DIR,
    encoding: "utf8",
    env: Object.assign({}, process.env, {
      SSC_CUSTOM: CUSTOM_ENV_VALUE,
      SSC_EXPECT_CWD: CASE_DIR,
    }),
    stdio: "pipe",
  };
}
function optsReport(o) {
  if (!o) return "<no-options>";
  return "timeout=" + String(o.timeout) +
    " cwd=" + (rel(String(o.cwd || "")) || ".") +
    " encoding=" + String(o.encoding) +
    " env.SSC_CUSTOM=" + String(o.env && o.env.SSC_CUSTOM) +
    " stdio=" + String(o.stdio) +
    " shell=" + String(o.shell);
}

// The script the direct .exe/.com fixture runs. That fixture is a real copy of
// the node binary, so this is the CHILD's own report of the cwd, env and argv it
// actually received — the direct branch observed through a real subprocess (C2)
// rather than through the parent's spy.
const DIRECT_SCRIPT =
  'const fs=require("fs");' +
  'const n=(p)=>String(p).replace(/\\\\/g,"/").toLowerCase();' +
  'fs.writeFileSync(process.env.SSC_MARKER,' +
  '["cwd="+(n(process.cwd())===n(process.env.SSC_EXPECT_CWD)?"match":"MISMATCH:"+process.cwd()),' +
  '"env="+(process.env.SSC_CUSTOM||"<unset>"),' +
  '"argv="+process.argv.slice(1).join(",")].join(" ")+"\\n");';

function verdictFromCalls(result) {
  if (result && result.error) {
    return result.error.code === "ENOENT" ? "enoent" : "error:" + result.error.code;
  }
  if (!calls.length) return "no-spawn";
  const call = calls[calls.length - 1];
  const isNode = call.c === process.execPath;
  return {
    kind: isNode ? "node" : "direct",
    file: isNode ? call.a[0] : call.c,
    passed: isNode ? call.a.slice(1) : call.a,
    shell: call.o ? call.o.shell : undefined,
  };
}

if (FN === "ref") {
  if (typeof mod.decide !== "function") {
    out("ref-missing-decide");
  } else {
    const d = mod.decide(command);
    out(!d ? "enoent" : d.kind + " " + rel(d.file));
  }
} else if (typeof mod.spawnShimmedCli !== "function") {
  out("no-export:spawnShimmedCli");
} else if (FN === "posix") {
  const r = mod.spawnShimmedCli(process.execPath, ["-e", "process.exit(7)"], { stdio: "ignore" });
  out("status=" + (r && r.error ? "error:" + r.error.code : String(r.status)));
} else if (FN === "exec") {
  const marker = process.env.SSC_MARKER;
  try { fs.rmSync(marker, { force: true }); } catch (_) {}
  const r = mod.spawnShimmedCli(command, ARGS, { stdio: "ignore" });
  out("status=" + (r && r.error ? "error:" + r.error.code : String(r.status)) +
    " argv=" + readMarker(marker));
} else if (FN === "opts") {
  // Spy mode: the question is what the underlying spawnSync was HANDED, which a
  // real run cannot show — the branch (node/direct) is reported alongside so the
  // same expectation covers both members of the class (CPR-ORTH).
  const r = mod.spawnShimmedCli(command, ARGS, callerOptions());
  if (r && r.error) out("error:" + r.error.code);
  else if (!calls.length) out("no-spawn");
  else {
    const call = calls[calls.length - 1];
    const isNode = call.c === process.execPath;
    out((isNode ? "node " : "direct ") + rel(isNode ? call.a[0] : call.c) +
      " :: " + optsReport(call.o));
  }
} else if (FN === "execopts" || FN === "direct") {
  // Real subprocess, no spy. `execopts` goes through the delegated (.cmd/.bat)
  // branch, `direct` through the resolved .exe/.com launched as-is; both read
  // the child's own record, so cwd/env/argv are observed, never inferred.
  const marker = process.env.SSC_MARKER;
  try { fs.rmSync(marker, { force: true }); } catch (_) {}
  const argv = FN === "direct" ? ["-e", DIRECT_SCRIPT, "--"].concat(ARGS) : ARGS;
  const r = mod.spawnShimmedCli(command, argv, callerOptions());
  out("status=" + (r && r.error ? "error:" + r.error.code : String(r.status)) +
    " " + readMarker(marker));
} else {
  const r = mod.spawnShimmedCli(command, ARGS, { stdio: "ignore" });
  const v = verdictFromCalls(r);
  if (typeof v === "string") out(v);
  else if (FN === "verdict") out(v.kind + " " + rel(v.file));
  else out(v.kind + " " + rel(v.file) + " :: " + v.passed.join(",") + " :: shell=" + String(v.shell));
}
