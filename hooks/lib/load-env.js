#!/usr/bin/env node
// Lightweight .env file loader for Claude Code hooks.
//
// Reads $AGENTS_CONFIG_DIR/.env (or a given path) and injects KEY=VALUE pairs
// into process.env. Existing process.env values take precedence (so explicit
// shell exports and tests setting their own env override the .env file).
//
// Format: simple KEY=VALUE per line. Optional surrounding double or single
// quotes are stripped. Lines starting with `#` or empty lines are skipped.
// No multi-line values, no variable interpolation, no `export` prefix.
//
// OS-conditional blocks: marker lines (#@if <os> / #@endif) delimit sections
// that apply only to a specific OS. On win32, blocks tagged `#@if windows` are
// retained; on all other platforms, blocks tagged `#@if posix` are retained.
// Marker lines themselves are always stripped from the parsed output. A flat
// file with no markers is parsed identically — no-op, fully backward compatible.
//
// Fail-safe: missing or unreadable .env is a silent no-op.

const fs = require("fs");
const path = require("path");

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

// parseEnv parses already-OS-filtered .env text into a plain KEY→value map.
// Pure: never touches process.env. SSOT for the KEY=VALUE line grammar.
function parseEnv(content) {
  const map = {};
  for (const rawLine of content.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const m = line.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
    if (!m) continue;
    const key = m[1];
    let val = m[2];
    // Strip optional surrounding quotes
    if (val.length >= 2) {
      if ((val.startsWith('"') && val.endsWith('"')) ||
          (val.startsWith("'") && val.endsWith("'"))) {
        val = val.slice(1, -1);
      }
    }
    map[key] = val;
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
// Returns {} when no .env can be found (callers treat "absent" as "unset").
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

function loadDefaultEnv() {
  // (a) Honor AGENTS_CONFIG_DIR if set
  if (process.env.AGENTS_CONFIG_DIR) {
    return loadEnv(path.join(process.env.AGENTS_CONFIG_DIR, ".env"));
  }
  // (b) __dirname two levels up (direct install path)
  const dirFallback = path.resolve(__dirname, "..", "..");
  if (loadEnv(path.join(dirFallback, ".env"))) return true;
  // (c) Resolve __filename through symlinks (e.g. ~/.claude/hooks/lib -> real repo)
  try {
    const realCfgDir = path.resolve(path.dirname(fs.realpathSync(__filename)), "..", "..");
    if (loadEnv(path.join(realCfgDir, ".env"))) return true;
  } catch (_) {}
  if (process.env.AGENTS_HOOK_DEBUG === "1") {
    process.stderr.write("[load-env] loadDefaultEnv: .env not found via AGENTS_CONFIG_DIR, __dirname, or realpathSync\n");
  }
  return false;
}

module.exports = { loadEnv, loadDefaultEnv, filterOsBlocks, parseEnv, readEnvFile, readDefaultEnvFile };
