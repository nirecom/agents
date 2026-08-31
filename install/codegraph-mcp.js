#!/usr/bin/env node
// codegraph-mcp.js - register / unregister the `codegraph` MCP server for this user.
//
// Registration is delegated to the Claude Code CLI (`claude mcp add|remove`), never to
// the upstream tool's own bootstrap command: that command rewrites ~/.claude/CLAUDE.md
// and injects a prompt hook. Rationale: docs/architecture/claude-code.md.

// ~/.claude.json is READ ONLY here, to answer "is it registered, and is it ours?"; every
// write to it belongs to the CLI. Exit is always 0 except a usage error (64) — a failed
// registration must never fail the installer that called it.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const SERVER_NAME = "codegraph";
const VERBS = ["register", "unregister"];
const SERVER_COMMAND = "codegraph";
const SERVER_ARGS = ["serve", "--mcp"];
const TELEMETRY_KEYS = ["CODEGRAPH_TELEMETRY", "DO_NOT_TRACK"];
const CONSTANTS_FILE = path.join(__dirname, "codegraph-constants.txt");

function warn(message) {
  process.stderr.write("codegraph-mcp: " + message + "\n");
}

function note(message) {
  process.stdout.write(message + "\n");
}

function readConstants() {
  const out = {};
  let raw;
  try {
    raw = fs.readFileSync(CONSTANTS_FILE, "utf8");
  } catch (_) {
    return out;
  }
  for (const line of raw.split(/\r?\n/)) {
    const matched = /^([A-Z][A-Z0-9_]*)=(.*)$/.exec(line.trim());
    if (matched) out[matched[1]] = matched[2];
  }
  return out;
}

// telemetryEnv is the opt-out pair the daemon must inherit; install/codegraph-constants.txt
// is its single source of truth, shared with both OS installer scripts.
function telemetryEnv() {
  const constants = readConstants();
  const pairs = {};
  for (const key of TELEMETRY_KEYS) {
    if (typeof constants[key] === "string") pairs[key] = constants[key];
  }
  return pairs;
}

// claudeCliPresent probes the CLI itself; only ENOENT means "not installed".
// A non-zero exit from `--version` is still a CLI that exists.
function claudeCliPresent() {
  const probe = spawnSync("claude", ["--version"], { stdio: "ignore" });
  return !(probe.error && probe.error.code === "ENOENT");
}

function readEntry() {
  const configPath = path.join(os.homedir(), ".claude.json");
  let raw;
  try {
    raw = fs.readFileSync(configPath, "utf8");
  } catch (err) {
    if (err && err.code === "ENOENT") return { absent: true };
    return null;
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (_) {
    return null;
  }
  if (!parsed || typeof parsed !== "object") return null;
  const servers = parsed.mcpServers;
  if (!servers || typeof servers !== "object") return { absent: true };
  if (!Object.prototype.hasOwnProperty.call(servers, SERVER_NAME)) return { absent: true };
  const entry = servers[SERVER_NAME];
  if (!entry || typeof entry !== "object") return null;
  return { absent: false, entry };
}

// hasOurShape is the weaker test: same command and args, whatever the env. Such an
// entry may be replaced when CODEGRAPH turns on, but never removed when it turns off.
function hasOurShape(entry) {
  if (entry.command !== SERVER_COMMAND) return false;
  const args = entry.args;
  if (!Array.isArray(args) || args.length !== SERVER_ARGS.length) return false;
  return SERVER_ARGS.every((value, index) => args[index] === value);
}

function hasTelemetryOptOut(entry, wanted) {
  const env = entry.env;
  if (!env || typeof env !== "object") return Object.keys(wanted).length === 0;
  return Object.keys(wanted).every((key) => String(env[key]) === wanted[key]);
}

// readState collapses ~/.claude.json into the four cases the verbs branch on, plus
// null for "unknowable", which must change nothing. Only "current" — an entry
// carrying the exact command, args and telemetry env register() writes — is proof
// of ownership, so only "current" is ever removed.
function readState(wantedEnv) {
  const found = readEntry();
  if (found === null) return null;
  if (found.absent) return "absent";
  if (!hasOurShape(found.entry)) return "foreign";
  return hasTelemetryOptOut(found.entry, wantedEnv) ? "current" : "replaceable";
}

function runClaude(args) {
  const result = spawnSync("claude", args, { stdio: "inherit" });
  if (result.error) return false;
  return result.status === 0;
}

function addServer(wantedEnv) {
  const envFlags = Object.keys(wantedEnv).flatMap((key) => ["--env", key + "=" + wantedEnv[key]]);
  return runClaude(
    ["mcp", "add", SERVER_NAME, "--scope", "user"]
      .concat(envFlags)
      .concat(["--", SERVER_COMMAND])
      .concat(SERVER_ARGS)
  );
}

function removeServer() {
  return runClaude(["mcp", "remove", SERVER_NAME, "-s", "user"]);
}

function register(state, wantedEnv) {
  if (state === "current") {
    note(SERVER_NAME + " MCP server already registered.");
    return;
  }
  if (state === "foreign") {
    note(SERVER_NAME + " MCP server is registered with a command this installer did not write; leaving it unchanged.");
    return;
  }
  if (state === "replaceable" && !removeServer()) {
    warn("could not refresh the " + SERVER_NAME + " MCP server registration; re-run the installer to retry.");
    return;
  }
  if (!addServer(wantedEnv)) {
    warn("could not register the " + SERVER_NAME + " MCP server; re-run the installer to retry.");
    return;
  }
  note(SERVER_NAME + " MCP server registered.");
}

function unregister(state) {
  if (state === "absent") return;
  if (state !== "current") {
    note(SERVER_NAME + " MCP server does not carry this installer's registration marker; leaving it in place.");
    return;
  }
  if (!removeServer()) {
    warn("could not unregister the " + SERVER_NAME + " MCP server; re-run the installer to retry.");
    return;
  }
  note(SERVER_NAME + " MCP server unregistered (CODEGRAPH is off).");
}

function main() {
  const verb = process.argv[2];
  if (!verb || VERBS.indexOf(verb) < 0) {
    process.stderr.write("usage: node install/codegraph-mcp.js <register|unregister>\n");
    process.exit(64);
  }
  if (!claudeCliPresent()) {
    warn("claude CLI not found; MCP registration skipped.");
    process.exit(0);
  }
  const wantedEnv = telemetryEnv();
  const state = readState(wantedEnv);
  if (state === null) {
    warn("could not read the MCP server list; leaving registration unchanged.");
    process.exit(0);
  }
  if (verb === "register") register(state, wantedEnv);
  else unregister(state);
  process.exit(0);
}

main();
