#!/usr/bin/env node
"use strict";
// hooks/rtk-rewrite.js — PreToolUse (Bash) hook. Delegates eligible commands to
// `rtk hook claude`; fail-open. Five guards decide when NOT to delegate.

const fs = require("fs");
const path = require("path");
const { execFileSync, spawnSync } = require("child_process");
const { hasCommandHead } = require("./lib/command-head");
const {
  splitSegmentsWithSeparators,
  tokenizeSegment,
} = require("./lib/command-parser");
const { isUnderPath } = require("./lib/path-match");
const { recordGuardReject } = require("./lib/rtk-guard-audit");

const DELEGATE_TIMEOUT_MS = 3000;

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
  "alias", "typeset",
]);

function passthrough() {
  return {};
}

function binBasename(token) {
  if (typeof token !== "string") return "";
  return token.replace(/\\/g, "/").split("/").pop().replace(/\.exe$/i, "").toLowerCase();
}

function isEnvHead(token) {
  return binBasename(token) === "env";
}

function peelEnvTokens(tokens) {
  let i = 1; // skip "env" itself
  while (i < tokens.length) {
    const t = tokens[i];
    if (t === "--") { i++; break; }
    if (t === "-i" || t === "--ignore-environment" || t === "-0" || t === "--null") { i++; continue; }
    // value-taking flags: -u/--unset NAME, -C/--chdir DIR
    if ((t === "-u" || t === "--unset" || t === "-C" || t === "--chdir") && i + 1 < tokens.length) { i += 2; continue; }
    if (t.startsWith("-")) { i++; continue; }
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(t)) { i++; continue; } // VAR=val
    break;
  }
  return i < tokens.length ? tokens.slice(i) : null;
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

function loadAuditEnabled() {
  const agentsDir = process.env.AGENTS_CONFIG_DIR;
  if (!agentsDir) return false;
  const script = path.join(agentsDir, "bin", "get-config-var");
  try {
    execFileSync("bash", [script, "--is-off", "RTK_AUDIT", "off"], { stdio: "ignore" });
    return false; // exit 0 => OFF
  } catch (e) {
    return e && e.status === 1; // exit 1 => explicit ON
  }
}

function whichRtkOnPath() {
  const finder = process.platform === "win32" ? "where.exe" : "which";
  const out = execFileSync(finder, ["rtk"], { encoding: "utf8" });
  return out.split(/\r?\n/).map((l) => l.trim()).find((l) => l.length > 0) || null;
}

// whichFn: `() => string | null` PATH lookup, injectable for host-independent tests; a throw is not-found.
function resolveRtkBin(existsFn = fs.existsSync, whichFn = null) {
  if (process.env.RTK_BIN) return process.env.RTK_BIN;
  try {
    const first = (whichFn || whichRtkOnPath)();
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

function quoteBin(bin, platform = process.platform) {
  if (platform === "win32") {
    if (/[\\ ]/.test(bin)) return '"' + bin.replace(/\\/g, "/") + '"';
    return bin;
  }
  if (bin.includes(" ")) return '"' + bin + '"';
  return bin;
}

function leadingToken(command) {
  let i = 0;
  while (i < command.length && /\s/.test(command[i])) i++;
  const lead = command.slice(0, i);
  const start = i;
  let value = "";
  const q = command[i];
  if (q === '"' || q === "'") {
    i++;
    while (i < command.length && command[i] !== q) { value += command[i]; i++; }
    if (i < command.length) i++; // consume closing quote
  } else {
    while (i < command.length && !/\s/.test(command[i])) { value += command[i]; i++; }
  }
  return { lead, raw: command.slice(start, i), value, rest: command.slice(i) };
}

function substituteRtkHead(command, rtkBin, platform = process.platform) {
  const { lead, value, rest } = leadingToken(command);
  if (binBasename(value) !== "rtk") return command;
  return lead + quoteBin(rtkBin, platform) + rest;
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
  const underAgents = (p) => isUnderPath(p, resolvedAgentsDir);
  const checkTokens = (toks) => {
    const head = toks[0];
    if (!head) return false;
    const isRunner = SCRIPT_RUNNERS.has(binBasename(head));
    // Path head that is NOT a script runner: judge the head itself.
    if ((head.includes("/") || head.includes("\\")) && !isRunner) {
      let resolved;
      try { resolved = path.resolve(head); } catch (_e) { return false; }
      try { resolved = fs.realpathSync(resolved); } catch (_e) { /* use unresolved */ }
      return underAgents(resolved);
    }
    if (binNames.has(head)) return true;
    // Script runner (even via absolute path): judge its first path argument.
    if (isRunner) {
      for (let i = 1; i < toks.length; i++) {
        const t = toks[i];
        if (t.startsWith("-")) continue;
        if (!t.includes("/") && !t.includes("\\")) break;
        let resolved;
        try { resolved = path.resolve(t); } catch (_e) { break; }
        try { resolved = fs.realpathSync(resolved); } catch (_e) { /* use unresolved */ }
        return underAgents(resolved);
      }
    }
    return false;
  };
  try {
    return hasCommandHead(cmd, (tokens) => {
      // Peel env prefix to reach the actual command head.
      let toks = tokens;
      if (toks.length > 0 && isEnvHead(toks[0])) {
        const peeled = peelEnvTokens(toks);
        if (!peeled || peeled.length === 0) return false;
        toks = peeled;
      }
      return checkTokens(toks);
    });
  } catch (_e) {
    return false;
  }
}

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
      // Peel env prefix and strip .exe suffix to reach the actual command base.
      let toks = tokens;
      if (toks.length > 0 && isEnvHead(toks[0])) {
        const peeled = peelEnvTokens(toks);
        if (!peeled || peeled.length === 0) return false;
        toks = peeled;
      }
      if (toks.length === 0) return false;
      const base = binBasename(toks[0]);
      if (base === "git") return gitMachineReadable(toks);
      for (let k = 1; k < toks.length; k++) {
        const t = toks[k];
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

function isComposite(cmd) {
  if (cmd.includes("\n")) return true; // newline-separated multi-statement
  const { seps } = splitSegmentsWithSeparators(cmd);
  if (seps.length > 0) return true;
  if (/`|\$\(/.test(cmd)) return true; // substitution — check before quote-strip
  const stripped = cmd.replace(/"[^"]*"|'[^']*'/g, "");
  if (/[><]/.test(stripped)) return true; // redirect — check after quote-strip
  return false;
}

function isShellBuiltin(cmd) {
  const tokens = tokenizeSegment(cmd);
  if (tokens.length === 0) return true;
  let effectiveTokens = tokens;
  if (isEnvHead(tokens[0])) {
    const peeled = peelEnvTokens(tokens);
    if (!peeled || peeled.length === 0) return false;
    effectiveTokens = peeled;
  }
  const first = effectiveTokens[0];
  if (first.includes("=") && !first.startsWith("-")) return true; // FOO=bar ...
  // bash/sh -c: the wrapped shell string cannot be meaningfully compressed.
  const base = binBasename(first);
  if ((base === "bash" || base === "sh") && effectiveTokens.slice(1).includes("-c")) return true;
  return SHELL_BUILTINS.has(first);
}

function isRtkSelf(cmd) {
  try {
    return hasCommandHead(cmd, (tokens) => {
      let i = 0;
      if (tokens.length > 0 && isEnvHead(tokens[0])) i++;
      while (i < tokens.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[i])) i++;
      const head = tokens[i];
      if (!head) return false;
      return binBasename(head) === "rtk";
    });
  } catch (_e) {
    return false;
  }
}

function firstRejectingGuard(cmd) {
  if (isAgentsEmit(cmd)) return "agentsEmit";
  if (isShellBuiltin(cmd)) return "shellBuiltin";
  if (isComposite(cmd)) return "composite";
  if (isMachineReadable(cmd)) return "machineReadable";
  if (isRtkSelf(cmd)) return "rtkSelf";
  return null;
}

function delegateToRtkHook(rtkBin, input, opts = {}) {
  const spawnFn = opts.spawnFn || spawnSync;
  const env = { ...process.env };
  if (opts.auditOn) env.RTK_HOOK_AUDIT = "1";
  else delete env.RTK_HOOK_AUDIT; // clear any inherited value so off stays off
  let res;
  try {
    res = spawnFn(rtkBin, ["hook", "claude"], {
      input: JSON.stringify(input),
      encoding: "utf8",
      timeout: DELEGATE_TIMEOUT_MS,
      env,
    });
  } catch (_e) {
    return passthrough();
  }
  if (!res || res.error || res.status !== 0 || !res.stdout) return passthrough();
  let out;
  try { out = JSON.parse(res.stdout); } catch (_e) { return passthrough(); }
  if (!out || !out.hookSpecificOutput) return passthrough();
  const hso = out.hookSpecificOutput;
  if (hso.updatedInput && typeof hso.updatedInput.command === "string") {
    hso.updatedInput.command = substituteRtkHead(hso.updatedInput.command, rtkBin);
  }
  return out;
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
      : resolveRtkBin(opts.existsFn || fs.existsSync, opts.whichFn || null);
    if (rtkBin === null || rtkBin === undefined) return passthrough();
    const auditOn = opts.auditOn !== undefined ? opts.auditOn : loadAuditEnabled();
    const guardName = firstRejectingGuard(cmd);
    if (guardName) {
      if (auditOn) {
        try { recordGuardReject(guardName, cmd, opts.auditOpts); }
        catch (_e) { /* fail-open: audit must not break the hook */ }
      }
      return passthrough();
    }
    return delegateToRtkHook(rtkBin, input, { auditOn, spawnFn: opts.spawnFn });
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
  quoteBin,
  substituteRtkHead,
  passthrough,
  loadDefaultEnv,
  loadAuditEnabled,
  isAgentsEmit,
  isMachineReadable,
  isComposite,
  isShellBuiltin,
  isRtkSelf,
  decide,
};

if (require.main === module) main();
