"use strict";
// Test-only fake gh / glab for the #2668 tests. No case markers.
// fakeCliDir(dir) fills dir with a node-shebang `gh` and `glab` (found by bash callers) and, on
// Windows, gh.exe / glab.exe copies of the node binary (Node's shell-less spawn resolves only
// .exe / .com); loaded as a preload through fakeCliEnv's NODE_OPTIONS, this file turns those copies
// into the same fake. Inert in every other node process.
// Every call is appended to FAKE_CLI_LOG as {"cmd","args"}. FAKE_<GH|GLAB>_STDOUT / _STATUS fix the
// answer; without them `issue view <N>` prints "Fake title <N>" and anything else prints nothing.
const fs = require("node:fs");
const path = require("node:path");

function main(name, args) {
  const log = process.env.FAKE_CLI_LOG;
  if (log) fs.appendFileSync(log, `${JSON.stringify({ cmd: name, args })}\n`);
  const key = `FAKE_${name.toUpperCase()}_`;
  const fixed = process.env[`${key}STDOUT`];
  let out = "";
  if (fixed !== undefined) out = fixed;
  else if (args[0] === "issue" && args[1] === "view") out = `Fake title ${args[2]}\n`;
  if (out) fs.writeSync(1, out);
  process.exit(Number(process.env[`${key}STATUS`] || 0));
}

const self = path.basename(process.execPath).replace(/\.exe$/i, "").toLowerCase();
if (self === "gh" || self === "glab") {
  // node took the first argument as its script path and resolved it; give back the bare word.
  const args = process.argv.slice(1);
  if (args.length > 0) args[0] = path.basename(args[0]);
  main(self, args);
}

const fwd = (p) => p.replace(/\\/g, "/");

function fakeCliDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
  for (const name of ["gh", "glab"]) {
    fs.writeFileSync(path.join(dir, name), `#!/usr/bin/env node\nrequire(${JSON.stringify(fwd(__filename))}).main(${JSON.stringify(name)}, process.argv.slice(2));\n`, { mode: 0o755 });
    if (process.platform === "win32") {
      const exe = path.join(dir, `${name}.exe`);
      try { fs.linkSync(process.execPath, exe); } catch (_e) { fs.copyFileSync(process.execPath, exe); }
    }
  }
  return dir;
}

// withEnv(base, extra) -> base with extra applied; a key of extra replaces every spelling of the
// same name (Windows names are case-insensitive: "Path"), and a null value removes it.
function withEnv(base, extra) {
  const drop = new Set(Object.keys(extra).map((k) => k.toUpperCase()));
  const env = Object.fromEntries(Object.entries(base).filter(([k]) => !drop.has(k.toUpperCase())));
  for (const [k, v] of Object.entries(extra)) if (v !== null && v !== undefined) env[k] = v;
  return env;
}

// fakeCliEnv(dir, log, base) -> the env overrides that put the fakes first on PATH and arm them.
function fakeCliEnv(dir, log, base = process.env) {
  const pathKey = Object.keys(base).find((k) => k.toUpperCase() === "PATH") || "PATH";
  return { PATH: `${dir}${path.delimiter}${base[pathKey] || ""}`, NODE_OPTIONS: `--require "${fwd(__filename)}"`, FAKE_CLI_LOG: log };
}

// calls(log) -> the logged calls, oldest first.
function calls(log) {
  try {
    return fs.readFileSync(log, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
  } catch (_e) {
    return [];
  }
}

module.exports = { main, fakeCliDir, fakeCliEnv, withEnv, calls };
