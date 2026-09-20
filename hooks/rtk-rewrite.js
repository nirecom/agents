#!/usr/bin/env node
"use strict";
// hooks/rtk-rewrite.js — PreToolUse (matcher: Bash) hook that wraps general Bash
// commands with the RTK binary so its runtime output compression reaches the LLM.
// Fail-open at every boundary: any doubt returns passthrough ({}), never a wrap.
//
// Four guards decide when NOT to wrap:
//   G-a isAgentsEmit      — commands that emit agents-framework control output
//   G-b isMachineReadable — plumbing / machine-readable output (compression harms it)
//   G-c isComposite       — pipelines, redirects, substitutions (wrap would misparse)
//   G-d isShellBuiltin    — builtins / assignments (no external process to wrap)

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const { hasCommandHead } = require("./lib/command-head");
const {
  splitSegmentsWithSeparators,
  tokenizeSegment,
} = require("./lib/command-parser");

const GIT_GLOBAL_OPTS_WITH_VALUE = new Set([
  "-C", "--git-dir", "--work-tree", "--namespace", "--exec-path",
  "-c", "--config-env", "--super-prefix",
]);
const GIT_GLOBAL_FLAGS = new Set([
  "--no-pager", "--no-replace-objects", "--bare", "--literal-pathspecs",
  "--glob-pathspecs", "--noglob-pathspecs", "--icase-pathspecs",
  "--no-optional-locks", "--version", "--help", "-v", "--verbose", "--no-advice",
]);
const MACHINE_FLAGS = new Set([
  "--json", "--porcelain", "-z", "--null", "--name-only", "--name-status",
  "--numstat", "--raw",
]);
const MACHINE_FLAGS_WITH_VALUE = new Set(["--format", "--pretty"]);
const GIT_PLUMBING_SUBCOMMANDS = new Set([
  "rev-parse", "cat-file", "ls-files", "ls-tree", "for-each-ref", "show-ref",
  "diff-index", "diff-files", "diff-tree", "merge-base", "config",
]);
const SHELL_BUILTINS = new Set([
  "cd", "export", "unset", "set",
  "echo", "printf",
  "true", "false", "test", "[",
  "read",
  "source", ".",
  "declare", "local", "readonly",
  "pwd", ":", "command", "builtin", "exec",
]);

function passthrough() {
  return {};
}

// RTK on/off resolves through bin/get-config-var (exit 1 = explicit ON).
function loadDefaultEnv() {
  const agentsDir = process.env.AGENTS_CONFIG_DIR;
  if (!agentsDir) return false;
  const script = path.join(agentsDir, "bin", "get-config-var");
  try {
    execFileSync("bash", [script, "--is-off", "RTK", "off"], { stdio: "ignore" });
    return false; // exit 0 => OFF
  } catch (e) {
    return e && e.status === 1; // exit 1 => explicit ON
  }
}

function resolveRtkBin(existsFn = fs.existsSync) {
  if (process.env.RTK_BIN) return process.env.RTK_BIN;
  try {
    const finder = process.platform === "win32" ? "where.exe" : "which";
    const out = execFileSync(finder, ["rtk"], { encoding: "utf8" });
    const first = out.split(/\r?\n/).map((l) => l.trim()).find((l) => l.length > 0);
    if (first) return first;
  } catch (_e) { /* rtk not on PATH */ }
  const brewCandidates = [
    "/opt/homebrew/bin/rtk",
    "/usr/local/bin/rtk",
    "/home/linuxbrew/.linuxbrew/bin/rtk",
  ];
  for (const c of brewCandidates) {
    try { if (existsFn(c)) return c; } catch (_e) { /* fail-open */ }
  }
  if (process.platform === "win32") {
    const local = process.env.LOCALAPPDATA || "";
    const winCandidates = [
      path.join(local, "Microsoft", "WinGet", "Links", "rtk.exe"),
      path.join(local, "Programs", "rtk-ai", "rtk", "rtk.exe"),
    ];
    for (const c of winCandidates) {
      try { if (existsFn(c)) return c; } catch (_e) { /* fail-open */ }
    }
  }
  return null;
}

// Quote the binary path when it contains spaces or (on win32) backslashes.
function buildRtkCommand(rtkBin, cmd, platform = process.platform) {
  let bin = rtkBin;
  if (platform === "win32") {
    if (/[\\ ]/.test(rtkBin)) bin = '"' + rtkBin.replace(/\\/g, "/") + '"';
  } else if (rtkBin.includes(" ")) {
    bin = '"' + rtkBin + '"';
  }
  return bin + " " + cmd;
}

let binNamesCache = null;
function getBinNames(agentsDir) {
  if (binNamesCache) return binNamesCache;
  try {
    binNamesCache = new Set(fs.readdirSync(path.join(agentsDir, "bin")));
  } catch (_e) {
    binNamesCache = new Set(); // fail-safe: nothing matches, guard does not fire
  }
  return binNamesCache;
}

const SCRIPT_RUNNERS = new Set(["node", "bash", "sh"]);

// G-a: commands rooted at the agents config dir (control/plumbing output).
function isAgentsEmit(cmd) {
  const agentsDir = process.env.AGENTS_CONFIG_DIR;
  if (!agentsDir) return false;
  if (/\$\{?AGENTS_CONFIG_DIR\b/.test(cmd)) return true; // unexpanded env ref
  let resolvedAgentsDir;
  try {
    resolvedAgentsDir = fs.realpathSync(path.resolve(agentsDir));
  } catch (_e) {
    resolvedAgentsDir = path.resolve(agentsDir);
  }
  const binNames = getBinNames(agentsDir);
  const underAgents = (p) => {
    const rel = path.relative(resolvedAgentsDir, p);
    return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
  };
  try {
    return hasCommandHead(cmd, (tokens) => {
      const head = tokens[0];
      if (!head) return false;
      if (head.includes("/") || head.includes("\\")) {
        let resolved;
        try { resolved = path.resolve(head); } catch (_e) { return false; }
        try { resolved = fs.realpathSync(resolved); } catch (_e) { /* use unresolved */ }
        return underAgents(resolved);
      }
      if (binNames.has(head)) return true;
      // Also match when a script runner's first path argument is an agents script.
      if (SCRIPT_RUNNERS.has(head)) {
        for (let i = 1; i < tokens.length; i++) {
          const t = tokens[i];
          if (t.startsWith("-")) continue; // skip flags like --harmony
          if (!t.includes("/") && !t.includes("\\")) break; // bare name, not a path
          let resolved;
          try { resolved = path.resolve(t); } catch (_e) { break; }
          try { resolved = fs.realpathSync(resolved); } catch (_e) { /* use unresolved */ }
          return underAgents(resolved);
        }
      }
      return false;
    });
  } catch (_e) {
    return false;
  }
}

// G-b: machine-readable output — git plumbing / porcelain / --json etc.
function gitMachineReadable(tokens) {
  let i = 1;
  const n = tokens.length;
  while (i < n) {
    const tok = tokens[i];
    if (!tok.startsWith("-")) break; // reached the subcommand
    if (GIT_GLOBAL_OPTS_WITH_VALUE.has(tok)) { i += 2; continue; }
    if (tok.includes("=")) { i += 1; continue; } // --git-dir=.git etc.
    if (tok.length > 2 && GIT_GLOBAL_OPTS_WITH_VALUE.has(tok.slice(0, 2))) { i += 1; continue; } // -Crepo
    i += 1; // recognized or unknown global flag
  }
  if (i >= n) return false;
  if (GIT_PLUMBING_SUBCOMMANDS.has(tokens[i])) return true;
  for (let k = i + 1; k < n; k++) {
    const t = tokens[k];
    if (MACHINE_FLAGS.has(t) || MACHINE_FLAGS_WITH_VALUE.has(t)) return true;
    if (t.includes("=")) {
      const name = t.slice(0, t.indexOf("="));
      if (MACHINE_FLAGS.has(name) || MACHINE_FLAGS_WITH_VALUE.has(name)) return true;
    }
  }
  return false;
}

function isMachineReadable(cmd) {
  try {
    return hasCommandHead(cmd, (tokens) => {
      if (tokens.length === 0) return false;
      const base = tokens[0].replace(/\\/g, "/").split("/").pop();
      if (base === "git") return gitMachineReadable(tokens);
      for (let k = 1; k < tokens.length; k++) {
        const t = tokens[k];
        if (MACHINE_FLAGS.has(t) || MACHINE_FLAGS_WITH_VALUE.has(t)) return true;
        if (t.includes("=")) {
          const name = t.slice(0, t.indexOf("="));
          if (MACHINE_FLAGS.has(name) || MACHINE_FLAGS_WITH_VALUE.has(name)) return true;
        }
      }
      return false;
    });
  } catch (_e) {
    return false;
  }
}

// G-c: composite command lines that a bare `rtk <cmd>` prefix would misparse.
function isComposite(cmd) {
  if (cmd.includes("\n")) return true; // newline-separated multi-statement
  const { seps } = splitSegmentsWithSeparators(cmd);
  if (seps.length > 0) return true;
  if (/`|\$\(/.test(cmd)) return true; // substitution — check before quote-strip
  const stripped = cmd.replace(/"[^"]*"|'[^']*'/g, "");
  if (/[><]/.test(stripped)) return true; // redirect — check after quote-strip
  return false;
}

// G-d: shell builtins and bare assignments (no external process to wrap).
function isShellBuiltin(cmd) {
  const tokens = tokenizeSegment(cmd);
  if (tokens.length === 0) return true;
  const first = tokens[0];
  if (first.includes("=") && !first.startsWith("-")) return true; // FOO=bar ...
  return SHELL_BUILTINS.has(first);
}

// Anti-double-wrap: a command already headed by rtk (optionally behind env / VAR=).
function isRtkSelf(cmd) {
  try {
    return hasCommandHead(cmd, (tokens) => {
      let i = 0;
      if (tokens[i] === "env") i++;
      while (i < tokens.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[i])) i++;
      const head = tokens[i];
      if (!head) return false;
      const base = head.replace(/\\/g, "/").split("/").pop();
      return base === "rtk" || base === "rtk.exe";
    });
  } catch (_e) {
    return false;
  }
}

function decide(input, opts = {}) {
  try {
    if (!input || input.tool_name !== "Bash") return passthrough();
    const cmd = input.tool_input && input.tool_input.command;
    if (typeof cmd !== "string" || !cmd.trim()) return passthrough();
    const rtkOn = opts.rtkOn !== undefined ? opts.rtkOn : loadDefaultEnv();
    if (!rtkOn) return passthrough();
    const rtkBin = opts.rtkBin !== undefined
      ? opts.rtkBin
      : resolveRtkBin(opts.existsFn || fs.existsSync);
    if (rtkBin === null || rtkBin === undefined) return passthrough();
    if (isAgentsEmit(cmd)) return passthrough();
    if (isShellBuiltin(cmd)) return passthrough();
    if (isComposite(cmd)) return passthrough();
    if (isMachineReadable(cmd)) return passthrough();
    if (isRtkSelf(cmd)) return passthrough();
    return {
      hookSpecificOutput: {
        permissionDecision: "allow",
        updatedInput: { command: buildRtkCommand(rtkBin, cmd) },
      },
    };
  } catch (_e) {
    return passthrough();
  }
}

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(65536);
  try {
    for (;;) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (_e) { /* closed/unreadable stdin reads as empty */ }
  return Buffer.concat(chunks).toString("utf8");
}

function main() {
  let input;
  try {
    input = JSON.parse(readStdin());
  } catch (_e) {
    process.stdout.write(JSON.stringify(passthrough()));
    process.exit(0);
  }
  process.stdout.write(JSON.stringify(decide(input)));
  process.exit(0);
}

module.exports = {
  resolveRtkBin,
  buildRtkCommand,
  passthrough,
  loadDefaultEnv,
  isAgentsEmit,
  isMachineReadable,
  isComposite,
  isShellBuiltin,
  isRtkSelf,
  decide,
};

if (require.main === module) main();
