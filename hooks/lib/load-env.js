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
    // Existing process.env wins (explicit shell/test export takes precedence)
    if (!(key in process.env)) {
      process.env[key] = val;
    }
  }
  return true;
}

function loadDefaultEnv() {
  // Resolve $AGENTS_CONFIG_DIR/.env, falling back to ../ from this file
  const cfgDir = process.env.AGENTS_CONFIG_DIR || path.resolve(__dirname, "..", "..");
  return loadEnv(path.join(cfgDir, ".env"));
}

module.exports = { loadEnv, loadDefaultEnv };
