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
const { spawnShimmedCli } = require("../hooks/lib/spawn-shimmed-cli");
const {
  REGISTRATION_ENV_KEYS,
  registrationEnv,
  classifyRegistration,
  clearSavedTelemetryChoice,
  verifyPinnedCliVersion,
} = require("../hooks/lib/codegraph-boundary");

const SERVER_NAME = "codegraph";
const VERBS = ["register", "unregister"];
const SERVER_COMMAND = "codegraph";
const SERVER_ARGS = ["serve", "--mcp"];
// Both verbs require proven ownership — the classifier grants a verdict other
// than "foreign" only to an entry carrying our owner marker. They differ on
// which marked verdicts they act on: removal needs a marker value that is ours,
// while a refresh also takes someone else's marker value, since the `add` that
// follows re-establishes ours.
const REFRESH_STATES = ["replaceable", "ours-stale"];
const REMOVE_STATES = ["current", "ours-stale"];

function warn(message) {
  process.stderr.write("codegraph-mcp: " + message + "\n");
}

function note(message) {
  process.stdout.write(message + "\n");
}

// RESET_NOTICE is one stdout line: the deletion is silent otherwise, and a saved
// opt-out that keeps coming back needs to name the file, the cause, and the cure.
// The two-stage recipe is ordered — the constants change alone restores nothing.
const RESET_NOTICE =
  "reset the local CodeGraph telemetry choice (removed ~/.codegraph/telemetry.json); the installer repeats " +
  "this on every run while install/codegraph-constants.txt ships CODEGRAPH_TELEMETRY=1 — to turn telemetry " +
  "off everywhere, set it to 0 and re-run the installer, then run `codegraph telemetry off` once for the " +
  "codegraph you start by hand.";

// The boundary decides and acts; this file owns every byte that reaches a stream.
function reportTelemetryReset() {
  const result = clearSavedTelemetryChoice();
  if (result.action === "cleared") note(RESET_NOTICE);
  else if (result.action === "failed") {
    warn("could not reset the local CodeGraph telemetry choice at " + result.path +
      "; the next installer run retries.");
  }
}

// A version report never blocks registration: the MCP server is useful at any
// version, and only the per-prompt context hook depends on the pinned build.
function reportPinnedVersionMismatch() {
  const { verdict, pinned, actual } = verifyPinnedCliVersion();
  const remedy = "; run: npm install -g --ignore-scripts @colbymchenry/codegraph@" + pinned;
  if (verdict === "mismatch") {
    process.stderr.write("pinned CodeGraph version mismatch: installed " + actual +
      ", install/codegraph-constants.txt pins " + pinned + remedy + "\n");
  } else if (verdict === "unknown-actual") {
    process.stderr.write("could not read the installed CodeGraph version (`codegraph --version`); " +
      "the per-prompt context hook needs the pinned " + pinned + " build" + remedy + "\n");
  }
}

// claudeCliPresent probes the CLI itself; only ENOENT means "not installed".
// A non-zero exit from `--version` is still a CLI that exists.
function claudeCliPresent() {
  const probe = spawnShimmedCli("claude", ["--version"], { stdio: "ignore" });
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

// readState pairs the config read with the shape test this file owns and hands
// both to the shared classifier. A partial or empty-valued wantedEnv means
// codegraph-constants.txt was missing, malformed, or incomplete — the desired
// env is itself unknowable, so classification fails closed exactly as it does
// for an unreadable ~/.claude.json, rather than falling through to "current"
// on whichever keys happened to be readable.
function readState(wantedEnv) {
  const found = readEntry();
  return classifyRegistration(found, wantedEnv, found && !found.absent && hasOurShape(found.entry));
}

function runClaude(args) {
  const result = spawnShimmedCli("claude", args, { stdio: "inherit" });
  if (result.error) return false;
  return result.status === 0;
}

function addServer(wantedEnv) {
  // Iterating REGISTRATION_ENV_KEYS, not the object, keeps the --env order fixed:
  // the argv is what tests and reviewers compare, so it must not follow key
  // insertion order in the constants file.
  const envFlags = REGISTRATION_ENV_KEYS.flatMap((key) => ["--env", key + "=" + wantedEnv[key]]);
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
  if (REFRESH_STATES.indexOf(state) >= 0 && !removeServer()) {
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
  if (REMOVE_STATES.indexOf(state) < 0) {
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
  // Both reports belong to `register` alone and run before the CLI probe: they
  // describe the local install, not the registration, so a missing claude CLI
  // must not swallow them.
  if (verb === "register") {
    reportTelemetryReset();
    reportPinnedVersionMismatch();
  }
  if (!claudeCliPresent()) {
    warn("claude CLI not found; MCP registration skipped.");
    process.exit(0);
  }
  const wantedEnv = registrationEnv();
  const state = readState(wantedEnv);
  if (state === null) {
    warn("could not read the MCP server list or its registration constants; leaving registration unchanged.");
    process.exit(0);
  }
  if (verb === "register") register(state, wantedEnv);
  else unregister(state);
  process.exit(0);
}

main();
