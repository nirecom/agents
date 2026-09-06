#!/usr/bin/env node
// codegraph-mcp.js - register / unregister the `codegraph` MCP server for this user.
//
// Registration is delegated to the Claude Code CLI (`claude mcp add|remove`), never to
// the upstream tool's own bootstrap command, which rewrites ~/.claude/CLAUDE.md and
// injects a prompt hook. Rationale: docs/architecture/claude-code.md.
//
// ~/.claude.json is READ ONLY here; every write belongs to the CLI. A same-named entry
// counts as ours only when hasOurShape() matches (see readState()). Exit is always 0
// except a usage error (64) — a failed registration must never fail the installer.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnShimmedCli } = require("../hooks/lib/spawn-shimmed-cli");
const {
  TELEMETRY_KEYS,
  telemetryEnv,
  clearSavedTelemetryChoice,
  verifyPinnedCliVersion,
} = require("../hooks/lib/codegraph-boundary");

const SERVER_NAME = "codegraph";
const VERBS = ["register", "unregister"];
const SERVER_COMMAND = "codegraph";
const SERVER_ARGS = ["serve", "--mcp"];

function warn(message) {
  process.stderr.write("codegraph-mcp: " + message + "\n");
}

function note(message) {
  process.stdout.write(message + "\n");
}

const RESET_NOTICE =
  "reset the local CodeGraph telemetry choice (removed ~/.codegraph/telemetry.json); the installer repeats " +
  "this on every run while install/codegraph-constants.txt ships CODEGRAPH_TELEMETRY=1 — to turn telemetry " +
  "off everywhere, set it to 0 and re-run the installer, then run `codegraph telemetry off` once for the " +
  "codegraph you start by hand.";

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

// A same-named entry only counts as ours when its command/args match what addServer()
// writes — a name collision with an unrelated hand-written or third-party MCP server
// must never be silently overwritten or deleted.
function hasOurShape(entry) {
  return (
    entry.command === SERVER_COMMAND &&
    Array.isArray(entry.args) &&
    entry.args.length === SERVER_ARGS.length &&
    entry.args.every((arg, i) => arg === SERVER_ARGS[i])
  );
}

// Returns "present" | "foreign" | "absent" | null. "foreign" means a same-named entry
// exists but its shape doesn't match ours — leave it alone. null means ~/.claude.json
// could not be read or parsed: the file is not ours to repair, so both verbs leave it alone.
function readState() {
  const configPath = path.join(os.homedir(), ".claude.json");
  let raw;
  try {
    raw = fs.readFileSync(configPath, "utf8");
  } catch (err) {
    if (err && err.code === "ENOENT") return "absent";
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
  if (!servers || typeof servers !== "object") return "absent";
  if (!Object.prototype.hasOwnProperty.call(servers, SERVER_NAME)) return "absent";
  const entry = servers[SERVER_NAME];
  if (!entry || typeof entry !== "object") return null;
  return hasOurShape(entry) ? "present" : "foreign";
}

function runClaude(args) {
  const result = spawnShimmedCli("claude", args, { stdio: "inherit" });
  if (result.error) return false;
  return result.status === 0;
}

function addServer(wantedEnv) {
  // Iterating the key list, not the object, keeps --env order independent of the
  // key order in the constants file.
  const envFlags = TELEMETRY_KEYS.flatMap((key) => ["--env", key + "=" + wantedEnv[key]]);
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

// Remove-then-add rather than a conditional refresh: `claude mcp add` rejects a
// duplicate name, and re-adding is how the shipped env reaches an older entry.
function register(state, wantedEnv) {
  if (state === "foreign") {
    warn("a " + SERVER_NAME + " MCP server is already registered with a different command/args; leaving it as-is.");
    return;
  }
  if (state === "present" && !removeServer()) {
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
  if (state !== "present") return;
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
  // Before the CLI probe: both describe the local install, not the registration,
  // so a missing claude CLI must not swallow them.
  if (verb === "register") {
    reportTelemetryReset();
    reportPinnedVersionMismatch();
  }
  if (!claudeCliPresent()) {
    warn("claude CLI not found; MCP registration skipped.");
    process.exit(0);
  }
  const state = readState();
  if (state === null) {
    warn("could not read the MCP server list; leaving registration unchanged.");
    process.exit(0);
  }
  if (verb === "register") register(state, telemetryEnv());
  else unregister(state);
  process.exit(0);
}

main();
