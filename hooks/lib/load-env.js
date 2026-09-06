#!/usr/bin/env node
// Lightweight .env loader for Claude Code hooks. Reads $AGENTS_CONFIG_DIR/.env
// (or a given path) into a KEY→value map, and optionally into process.env where
// a non-empty process.env value always wins.
// Grammar: KEY=VALUE per line; `#` and blank lines skipped; optional single or
// double quotes, which may span lines (see parseEnv); no interpolation.
// OS-conditional `#@if <os>` / `#@endif` blocks are filtered by platform and the
// marker lines are always stripped.
// Fail-safe: a missing or unreadable file is a silent no-op.

const fs = require("fs");
const path = require("path");
const { configDirCandidates } = require("./agents-config-dir");
const localEnv = require("./local-env");

// --- Pristine isolation-env snapshot -------------------------------------
// Captured at module load time, BEFORE loadDefaultEnv() injects any .env
// values into process.env. Consumers (supervisor-emit.js) need to know what
// the CALLER's environment declared, not the post-injection view — a test that
// pins only CLAUDE_WORKFLOW_DIR must remain distinguishable from a session
// where both vars arrived from .env.
const ISOLATION_ENV_KEYS = ["CLAUDE_WORKFLOW_DIR", "WORKFLOW_PLANS_DIR"];

function normalizeIsolationValue(raw) {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed.length === 0 ? null : raw;
}

const _pristineIsolationEnv = Object.freeze(
  ISOLATION_ENV_KEYS.reduce((acc, key) => {
    acc[key] = normalizeIsolationValue(process.env[key]);
    return acc;
  }, {})
);

// getPristineIsolationEnv returns the frozen module-load-time snapshot of the
// two plans-dir isolation variables. undefined / empty / whitespace-only → null.
function getPristineIsolationEnv() {
  return _pristineIsolationEnv;
}

// filterOsBlocks strips lines inside #@if <token> / #@endif blocks that do not
// match the current platform, and removes all marker lines from the output.
// Future extension: update activeTokens resolver below to add a repo-axis token.
function filterOsBlocks(text, platform) {
  const activeTokens = platform === "win32" ? new Set(["windows"]) : new Set(["posix"]);
  const lines = text.split(/\r?\n/);
  const out = [];
  let suppressing = false;
  let depth = 0;
  let suppressDepth = 0;

  for (const rawLine of lines) {
    const trimmed = rawLine.trim();

    if (trimmed.startsWith("#@if ")) {
      const token = trimmed.slice(5).trim();
      depth++;
      if (!suppressing && !activeTokens.has(token)) {
        suppressing = true;
        suppressDepth = depth;
      }
      // Drop the marker line — never push to output.
    } else if (trimmed === "#@endif") {
      if (depth > 0) {
        if (suppressing && depth === suppressDepth) {
          suppressing = false;
        }
        depth--;
      }
      // Drop the marker line — never push to output.
    } else if (trimmed.startsWith("#@")) {
      // Unknown marker — drop silently for forward-compat.
    } else {
      if (!suppressing) {
        out.push(rawLine);
      }
    }
  }

  return out.join("\n");
}

// findClosingQuote returns the index of the terminating quote in `text`, or -1.
// A backslash escapes the next character inside a double-quoted value only.
function findClosingQuote(text, quote) {
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quote === '"' && ch === "\\") {
      i++;
      continue;
    }
    if (ch === quote) return i;
  }
  return -1;
}

// unescapeDoubleQuoted expands \n, \t, \\ and \" inside a double-quoted value.
// An unrecognized sequence keeps its backslash verbatim.
function unescapeDoubleQuoted(text) {
  let out = "";
  for (let i = 0; i < text.length; i++) {
    if (text[i] !== "\\" || i === text.length - 1) {
      out += text[i];
      continue;
    }
    const next = text[i + 1];
    if (next === "n") out += "\n";
    else if (next === "t") out += "\t";
    else if (next === "\\") out += "\\";
    else if (next === '"') out += '"';
    else out += "\\" + next;
    i++;
  }
  return out;
}

// parseEnv parses already-OS-filtered .env text into a plain KEY→value map.
// Pure: never touches process.env. SSOT for the KEY=VALUE grammar.
// A quoted value runs to its matching closing quote, so every line it covers is
// data — a `#` or a second `KEY=` inside it is content, not syntax. A newline
// directly before the closing quote is dropped. An unterminated quote discards
// that key alone; keys parsed before it survive.
function parseEnv(content) {
  const map = {};
  const lines = content.replace(/\r\n/g, "\n").replace(/\r/g, "\n").split("\n");

  for (let idx = 0; idx < lines.length; idx++) {
    const line = lines[idx].trim();
    if (!line || line.startsWith("#")) continue;
    const m = line.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
    if (!m) continue;
    const key = m[1];
    const rawValue = m[2];

    const quote = rawValue.startsWith('"') || rawValue.startsWith("'") ? rawValue[0] : "";
    if (!quote) {
      map[key] = rawValue;
      continue;
    }

    let buf = rawValue.slice(1);
    let close = findClosingQuote(buf, quote);
    while (close < 0 && idx + 1 < lines.length) {
      idx++;
      buf += "\n" + lines[idx];
      close = findClosingQuote(buf, quote);
    }
    if (close < 0) {
      // Name the KEY only — the value it guarded is exactly what must not leak.
      // Unconditional: an unterminated quote can silently absorb every line down to
      // the next stray quote character in the file, so this must not require an
      // opt-in debug flag to be visible.
      process.stderr.write(`load-env: ${key} discarded — unterminated quote\n`);
      continue;
    }
    let val = buf.slice(0, close);
    if (val.endsWith("\n")) val = val.slice(0, -1);
    map[key] = quote === '"' ? unescapeDoubleQuoted(val) : val;
  }
  return map;
}

// readEnvFile reads a .env file into a map WITHOUT mutating process.env.
// Returns null when the file is missing or unreadable (same fail-safe as loadEnv).
// Use this — not process.env — for any decision that must not be forgeable by an
// inline `VAR=x node bin/...` prefix in a model-issued Bash command.
function readEnvFile(envPath) {
  if (!envPath) return null;
  let content;
  try {
    content = fs.readFileSync(envPath, "utf8");
  } catch {
    return null; // missing or unreadable — silent no-op
  }
  return parseEnv(filterOsBlocks(content, process.platform));
}

// readDefaultEnvFile resolves the config .env the same way loadDefaultEnv does,
// but returns its parsed contents instead of injecting them into process.env.
// Global-only door (DD-6): the project-local overlay is deliberately invisible
// here. Returns {} when no .env can be found ("absent" reads as "unset").
function readDefaultEnvFile() {
  // (a) Honor AGENTS_CONFIG_DIR if set
  if (process.env.AGENTS_CONFIG_DIR) {
    return readEnvFile(path.join(process.env.AGENTS_CONFIG_DIR, ".env")) || {};
  }
  // (b) __dirname two levels up (direct install path)
  const dirFallback = path.resolve(__dirname, "..", "..");
  const direct = readEnvFile(path.join(dirFallback, ".env"));
  if (direct) return direct;
  // (c) Resolve __filename through symlinks (e.g. ~/.claude/hooks/lib -> real repo)
  try {
    const realCfgDir = path.resolve(path.dirname(fs.realpathSync(__filename)), "..", "..");
    const viaReal = readEnvFile(path.join(realCfgDir, ".env"));
    if (viaReal) return viaReal;
  } catch (_) {}
  return {};
}

// resolveLocalLayer returns {globalMap, allowed, localMap} for a project root.
// localMap is null whenever the local layer must not be consulted at all.
function resolveLocalLayer(projectRoot) {
  const globalMap = readDefaultEnvFile();
  const allowed = localEnv.resolveOverridableKeys(globalMap);
  if (allowed.size === 0) return { globalMap, allowed, localMap: null };
  const root = localEnv.resolveProjectRoot(projectRoot || null, process.cwd());
  if (!root) return { globalMap, allowed, localMap: null };
  return { globalMap, allowed, localMap: readEnvFile(localEnv.localEnvPathFor(root)) };
}

// readEffectiveEnvFile returns the global map with the project-local overlay
// applied. Never reads process.env for a config value.
function readEffectiveEnvFile(projectRoot) {
  const { globalMap, allowed, localMap } = resolveLocalLayer(projectRoot);
  if (!localMap) return Object.assign({}, globalMap);
  return localEnv.overlay(globalMap, localMap, allowed).map;
}

function loadEnv(envPath) {
  if (!envPath) return false;
  let content;
  try {
    content = fs.readFileSync(envPath, "utf8");
  } catch {
    return false; // missing or unreadable — silent no-op
  }
  content = filterOsBlocks(content, process.platform);
  const parsed = parseEnv(content);
  for (const key of Object.keys(parsed)) {
    const val = parsed[key];
    // Non-empty process.env wins (explicit shell/test export takes precedence).
    // Empty-string values are treated as "not set" — Windows propagates VAR=""
    // into child processes even when the parent shell shows it as unset.
    // Log key NAME only (not value) when shadowing — prevents secret leakage.
    if (process.env[key]) {
      if (process.env.AGENTS_HOOK_DEBUG === "1") {
        process.stderr.write(`load-env: ${key} shadowed by process.env (process.env wins)\n`);
      }
    } else {
      process.env[key] = val;
    }
  }
  return true;
}

// applyLocalOverlayToProcessEnv injects declared-overridable local values on top
// of the already-injected global layer. `before` is the pre-injection process.env
// snapshot, so a value the caller actually exported still outranks both layers.
// The lookup is case-insensitive: Windows environment variables are, so a
// caller's real ENFORCE_WORKTREE export must not be missed by a differently
// cased key on the plain-object `before` snapshot.
function applyLocalOverlayToProcessEnv(before) {
  const { allowed, localMap } = resolveLocalLayer(null);
  if (!localMap) return;
  const beforeUpperTruthy = new Set(
    Object.keys(before)
      .filter((k) => before[k])
      .map((k) => k.toUpperCase())
  );
  for (const key of Object.keys(localMap)) {
    if (!allowed.has(key)) continue;
    if (beforeUpperTruthy.has(key.toUpperCase())) continue;
    process.env[key] = localMap[key];
  }
}

// loadDefaultEnv injects the effective config into process.env.
// Candidate ENUMERATION is shared with hooks/lib/agents-config-dir.js. The
// SELECTION POLICY is not (CPR-SC): an explicit AGENTS_CONFIG_DIR is the sole
// settings source and never falls through, or a child pointed at a test config
// dir would get the real repo's .env injected.
// Pinned by tests/fix-389-load-env-default-fallback T389-7.
function loadDefaultEnv() {
  const before = Object.assign({}, process.env);
  const loaded = loadDefaultEnvGlobal();
  applyLocalOverlayToProcessEnv(before);
  return loaded;
}

function loadDefaultEnvGlobal() {
  const candidates = configDirCandidates();
  // (a) Honor AGENTS_CONFIG_DIR if set
  const envCandidate = candidates.find((c) => c.source === "env");
  if (envCandidate) {
    return loadEnv(path.join(envCandidate.dir, ".env"));
  }
  // (b) module-relative, then (c) realpath-resolved
  for (const c of candidates) {
    if (loadEnv(path.join(c.dir, ".env"))) return true;
  }
  if (process.env.AGENTS_HOOK_DEBUG === "1") {
    process.stderr.write("[load-env] loadDefaultEnv: .env not found via AGENTS_CONFIG_DIR, __dirname, or realpathSync\n");
  }
  return false;
}

module.exports = {
  loadEnv,
  loadDefaultEnv,
  filterOsBlocks,
  parseEnv,
  readEnvFile,
  readDefaultEnvFile,
  readEffectiveEnvFile,
  getPristineIsolationEnv,
};
