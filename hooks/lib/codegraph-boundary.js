// codegraph-boundary.js — the shared door to the CodeGraph binary and to the
// constants file that configures it.
//
// bin/codegraph-lifecycle.js and install/codegraph-mcp.js both need the same
// three facts — is CODEGRAPH on, what env must a codegraph process inherit, and
// how is that process spawned — so those facts live here once rather than in
// each entrypoint. This module is a pure library: it decides and returns, and
// never writes to stdout or stderr. Reporting belongs to the entrypoints, which
// own their own diagnostic vocabulary.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnShimmedCli } = require("./spawn-shimmed-cli");
const { normalizeCwd } = require("./path-normalize");

const CONSTANTS_FILE = path.join(__dirname, "..", "..", "install", "codegraph-constants.txt");
const TELEMETRY_KEYS = ["CODEGRAPH_TELEMETRY", "DO_NOT_TRACK"];

// OWNER_MARKER_KEY is the positive evidence that an MCP registration was written
// by this installer. The telemetry pair alone cannot prove that — any tool may
// ship the same two values — so ownership is decided by this marker and only a
// marked entry is ever removed.
const OWNER_MARKER_KEY = "AGENTS_CODEGRAPH_MCP_OWNER";
const REGISTRATION_ENV_KEYS = [...TELEMETRY_KEYS, OWNER_MARKER_KEY];

// TELEMETRY_FALLBACK_ENV is a privacy-side floor, not a copy of the shipped
// defaults: when the constants file cannot be read we cannot know what the
// repo wants, so the spawned process inherits the quietest possible pair.
// It stays 0/1 even after the shipped defaults invert.
const TELEMETRY_FALLBACK_ENV = Object.freeze({ CODEGRAPH_TELEMETRY: "0", DO_NOT_TRACK: "1" });

const STATUS_TIMEOUT_MS = 60000;

// readConstants returns {} for a missing or unparsable file. Callers that need
// a complete answer test the key set themselves; callers that only need a
// process env fall back to TELEMETRY_FALLBACK_ENV.
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

// telemetryEnv answers "what telemetry env must a codegraph process this
// framework starts inherit?". It always answers both keys, so an unreadable
// constants file degrades to the privacy-side floor rather than to silence.
function telemetryEnv() {
  return { ...TELEMETRY_FALLBACK_ENV, ...constantsSubset(TELEMETRY_KEYS) };
}

// registrationEnv is the STRICT reader: it reports only what the constants file
// actually carries. An incomplete answer must stay incomplete, because the
// caller uses the key count to decide whether ownership is knowable at all.
function registrationEnv() {
  return constantsSubset(REGISTRATION_ENV_KEYS);
}

// envHasAll is the subset test: the entry carries at least these keys with these
// values. Evidence is asymmetric — extra keys another tool added do not make a
// registration less ours, so a superset still counts as a match.
function envHasAll(entry, wanted, keys) {
  const env = entry && entry.env;
  if (!env || typeof env !== "object") return false;
  return keys.every((key) => String(env[key]) === wanted[key]);
}

// classifyRegistration collapses "what is in ~/.claude.json" into the verdicts
// the two verbs branch on. `found` is null for an unreadable config, {absent:true}
// for no entry, or {entry}. `shapeMatches` is supplied by the caller because the
// argv shape (command and args) is the installer's own single source of truth.
// The verdict vocabulary is documented in docs/ops/codegraph.md.
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
  // The marker is the only evidence of authorship, so an unmarked entry is
  // foreign however closely it resembles ours. A marker that is ours but an env
  // that is not means our own registration drifted; someone else's marker value
  // is refreshable, because the `add` that follows re-establishes ours.
  if (!marked) return "foreign";
  return String(env[OWNER_MARKER_KEY]) === wantedEnv[OWNER_MARKER_KEY] ? "ours-stale" : "replaceable";
}

// codegraphEnabled is the single implementation point of the fail-safe-OFF
// polarity shared with install/win/codegraph.ps1 and install/linux/codegraph.sh:
// an explicit lowercase `on` enables, and everything else — `off`, unset,
// empty, an unrecognized value, or a failure to read the config at all —
// resolves to OFF. A real environment variable outranks the .env file.
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

// spawnCodegraph is the only door to the binary, so every invocation carries
// the same two guarantees: a bounded timeout, and the telemetry env
// install/codegraph-constants.txt ships. The env is built per call, not at
// module load, because codegraphEnabled() may have populated process.env from
// .env in between. A caller may shorten the timeout but never remove it.
function spawnCodegraph(args, options) {
  return spawnShimmedCli("codegraph", args, {
    ...options,
    env: { ...process.env, ...TELEMETRY_FALLBACK_ENV, ...telemetryEnv() },
    timeout: options && typeof options.timeout === "number" ? options.timeout : STATUS_TIMEOUT_MS,
  });
}

// normalizePayloadCwd wraps the shared normalizeCwd so a POSIX drive-letter cwd
// — the MSYS form Git Bash hands Claude Code — becomes the form Node's fs
// and spawn APIs accept. The private copies in hooks/enforce-worktree/ and
// hooks/workflow-state/ are candidates for the same extraction, out of scope here.
function normalizePayloadCwd(cwd) {
  const normalized = normalizeCwd(cwd);
  return typeof normalized === "string" ? normalized : cwd;
}

// promptHookScopeAllows(cwd) — may `prompt-hook` run for this cwd at all? An
// ENABLEMENT gate (same class as codegraphEnabled), never a filter on output.
// At the pinned version planFrontload() runs a DOWN-scan gated only on a
// workspace manifest, while upstream's own exclusion for that hazard is wired
// into the server-root path alone; this ports that exclusion and nothing more.
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
  // A home directory that cannot be resolved degrades to allow, the same way
  // upstream's own exclusion degrades.
  try {
    if (base === path.resolve(os.homedir())) return false;
  } catch (_) {
    return true;
  }
  return true;
}

// verifyPinnedCliVersion — is the codegraph this repo will actually invoke the
// one install/codegraph-constants.txt pins? Resolved through spawnCodegraph, so
// it sees the same PATH/PATHEXT resolution the lifecycle and the hook see.
// Verdicts: "match" | "mismatch" | "unknown-actual" | "unknown-pin".
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

// The shipped posture, evaluated with upstream's own truthiness for the two env
// keys this framework injects: undefined, "", "0" and "false" (any case) are the
// OFF side for BOTH keys, and DO_NOT_TRACK resolves first. The empty value is the
// one deliberate divergence — upstream lets it fall through to the saved config,
// so shipping "" means the user's own choice decides and must not be erased.
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

// clearSavedTelemetryChoice decides, acts, and returns { action, path } — it never
// prints, because the diagnostic vocabulary belongs to install/codegraph-mcp.js.
// The file's content is never read: whatever it holds, it goes.
// action: "skipped" | "absent" | "cleared" | "failed".
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
