// codegraph-boundary.js — the shared door to the CodeGraph binary and to the
// constants file that configures it, for bin/codegraph-lifecycle.js,
// install/codegraph-mcp.js and hooks/codegraph-context-inject.js.
// A pure library: it decides and returns, and never writes to stdout or stderr.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnShimmedCli } = require("./spawn-shimmed-cli");
const { normalizeCwd } = require("./path-normalize");

const CONSTANTS_FILE = path.join(__dirname, "..", "..", "install", "codegraph-constants.txt");
const TELEMETRY_KEYS = ["CODEGRAPH_TELEMETRY", "DO_NOT_TRACK"];

// The only evidence an MCP registration is ours: the telemetry pair alone
// proves nothing, since any tool may ship the same two values.
const OWNER_MARKER_KEY = "AGENTS_CODEGRAPH_MCP_OWNER";
const REGISTRATION_ENV_KEYS = [...TELEMETRY_KEYS, OWNER_MARKER_KEY];

// Privacy-side floor for an unreadable constants file, not a copy of the
// shipped defaults — it stays 0/1 even after those defaults invert.
const TELEMETRY_FALLBACK_ENV = Object.freeze({ CODEGRAPH_TELEMETRY: "0", DO_NOT_TRACK: "1" });

const STATUS_TIMEOUT_MS = 60000;

// Returns {} for a missing or unparsable file; callers decide what that means.
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

function constantsSubset(keys) {
  const constants = readConstants();
  const pairs = {};
  for (const key of keys) {
    if (typeof constants[key] === "string") pairs[key] = constants[key];
  }
  return pairs;
}

// Always answers both keys, so an unreadable constants file degrades to the
// privacy-side floor rather than to silence.
function telemetryEnv() {
  return { ...TELEMETRY_FALLBACK_ENV, ...constantsSubset(TELEMETRY_KEYS) };
}

// The strict reader: no fallback, because the caller uses the key count to
// decide whether ownership is knowable at all.
function registrationEnv() {
  return constantsSubset(REGISTRATION_ENV_KEYS);
}

// A subset test on purpose: extra keys another tool added do not make a
// registration less ours.
function envHasAll(entry, wanted, keys) {
  const env = entry && entry.env;
  if (!env || typeof env !== "object") return false;
  return keys.every((key) => String(env[key]) === wanted[key]);
}

// `found`: null for an unreadable config, {absent:true} for no entry, or {entry}.
// Verdict vocabulary: docs/ops/codegraph.md.
function classifyRegistration(found, wantedEnv, shapeMatches) {
  const keys = Object.keys(wantedEnv || {});
  // An incomplete or empty-valued constants read makes ownership unknowable.
  if (keys.length !== REGISTRATION_ENV_KEYS.length) return null;
  if (keys.some((key) => wantedEnv[key] === "")) return null;
  if (found === null) return null;
  if (found.absent) return "absent";
  if (!shapeMatches) return "foreign";
  const entry = found.entry;
  if (envHasAll(entry, wantedEnv, REGISTRATION_ENV_KEYS)) return "current";
  const env = entry && entry.env;
  const marked = Boolean(env) && typeof env === "object"
    && Object.prototype.hasOwnProperty.call(env, OWNER_MARKER_KEY);
  // Unmarked is foreign however closely it resembles ours; our own marker with a
  // drifted env is stale, and someone else's marker is refreshable by the `add`.
  if (!marked) return "foreign";
  return String(env[OWNER_MARKER_KEY]) === wantedEnv[OWNER_MARKER_KEY] ? "ours-stale" : "replaceable";
}

// Fail-safe-OFF polarity, shared with install/win/codegraph.ps1 and
// install/linux/codegraph.sh: only a lowercase `on` enables; anything else,
// including an unreadable config, resolves to OFF.
function codegraphEnabled() {
  try {
    require("./load-env").loadDefaultEnv();
  } catch (_) {
    return false;
  }
  const raw = process.env.CODEGRAPH;
  if (typeof raw !== "string") return false;
  return raw.trim().toLowerCase() === "on";
}

// The env is built per call, not at module load, because codegraphEnabled() may
// have populated process.env from .env in between.
function spawnCodegraph(args, options) {
  return spawnShimmedCli("codegraph", args, {
    ...options,
    env: { ...process.env, ...TELEMETRY_FALLBACK_ENV, ...telemetryEnv() },
    timeout: options && typeof options.timeout === "number" ? options.timeout : STATUS_TIMEOUT_MS,
  });
}

// A POSIX drive-letter cwd — the MSYS form Git Bash hands Claude Code — is
// rejected by Node's fs and spawn APIs.
function normalizePayloadCwd(cwd) {
  const normalized = normalizeCwd(cwd);
  return typeof normalized === "string" ? normalized : cwd;
}

// Ports upstream's own home-directory exclusion, which at the pinned version is
// wired into the server-root path alone and so misses prompt-hook's DOWN-scan.
// Delete it once the pinned build applies its own — see docs/ops/codegraph.md.
const SCOPE_UPWALK_LEVELS = 6;

function promptHookScopeAllows(cwd) {
  const raw = typeof cwd === "string" && cwd ? cwd : process.cwd();
  const base = path.resolve(normalizePayloadCwd(raw));
  let dir = base;
  for (let i = 0; i < SCOPE_UPWALK_LEVELS; i += 1) {
    if (fs.existsSync(path.join(dir, ".codegraph", "codegraph.db"))) return true;
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  if (base === path.parse(base).root) return false;
  // An unresolvable home directory degrades to allow, as upstream's own does.
  try {
    if (base === path.resolve(os.homedir())) return false;
  } catch (_) {
    return true;
  }
  return true;
}

// Goes through spawnCodegraph so it sees the same PATH/PATHEXT resolution the
// lifecycle and the hook see. Verdicts: match | mismatch | unknown-actual | unknown-pin.
const VERSION_TIMEOUT_MS = 10000;
const SEMVER_HEAD = /^[0-9]+\.[0-9]+\.[0-9]+/;

function verifyPinnedCliVersion() {
  const pinned = readConstants().CODEGRAPH_VERSION;
  if (typeof pinned !== "string" || pinned === "") return { verdict: "unknown-pin", pinned: null, actual: null };
  const result = spawnCodegraph(["--version"], { encoding: "utf8", timeout: VERSION_TIMEOUT_MS });
  const unknown = { verdict: "unknown-actual", pinned, actual: null };
  if (!result || result.error || result.status !== 0) return unknown;
  const line = String(result.stdout || "").split(/\r?\n/).map((s) => s.trim()).find((s) => s.length > 0);
  if (!line || !SEMVER_HEAD.test(line)) return unknown;
  return { verdict: line === pinned ? "match" : "mismatch", pinned, actual: line };
}

// Upstream's own truthiness: "", "0" and "false" (any case) are the OFF side of
// both keys, and "" deliberately falls through to the user's saved choice.
function offSide(value) {
  return value === "" || value === "0" || value.toLowerCase() === "false";
}

function telemetryEnabledByConstants() {
  const env = telemetryEnv();
  const dnt = env.DO_NOT_TRACK;
  const cgt = env.CODEGRAPH_TELEMETRY;
  if (typeof dnt !== "string" || typeof cgt !== "string") return false;
  if (!offSide(dnt)) return false;
  return !offSide(cgt);
}

// Returns { action, path }; action: skipped | absent | cleared | failed.
function clearSavedTelemetryChoice() {
  const configPath = path.join(os.homedir(), ".codegraph", "telemetry.json");
  if (!telemetryEnabledByConstants()) return { action: "skipped", path: configPath };
  try {
    fs.unlinkSync(configPath);
  } catch (err) {
    if (err && err.code === "ENOENT") return { action: "absent", path: configPath };
    return { action: "failed", path: configPath, error: err };
  }
  return { action: "cleared", path: configPath };
}

module.exports = {
  CONSTANTS_FILE,
  TELEMETRY_KEYS,
  OWNER_MARKER_KEY,
  REGISTRATION_ENV_KEYS,
  TELEMETRY_FALLBACK_ENV,
  STATUS_TIMEOUT_MS,
  readConstants,
  telemetryEnv,
  registrationEnv,
  classifyRegistration,
  codegraphEnabled,
  spawnCodegraph,
  normalizePayloadCwd,
  promptHookScopeAllows,
  verifyPinnedCliVersion,
  clearSavedTelemetryChoice,
};
