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
// Fail-safe: missing or unreadable .env is a silent no-op.

const fs = require("fs");
const path = require("path");

function loadEnv(envPath) {
  if (!envPath) return false;
  let content;
  try {
    content = fs.readFileSync(envPath, "utf8");
  } catch {
    return false; // missing or unreadable — silent no-op
  }
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

module.exports = { loadEnv, loadDefaultEnv };
