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
const { configDirCandidates } = require("./agents-config-dir");

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

function loadEnv(envPath) {
  if (!envPath) return false;
  let content;
  try {
    content = fs.readFileSync(envPath, "utf8");
  } catch {
    return false; // missing or unreadable — silent no-op
  }
  content = filterOsBlocks(content, process.platform);
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
  // Candidate ENUMERATION is shared with hooks/lib/agents-config-dir.js — the
  // (a)/(b)/(c) sources below are now its "env"/"module"/"realpath" candidates,
  // normalized through normalizeCwd + path.resolve (so a Git Bash
  // `/c/git/agents` value resolves), and (c) is still the
  // `realpathSync(__filename)` walk that reaches a symlinked checkout.
  //
  // The SELECTION POLICY is deliberately NOT shared (CPR-3): load-env decides
  // where SETTINGS come from, so an explicit AGENTS_CONFIG_DIR short-circuits —
  // it is the sole config source and never falls through, or a child process
  // pointed at an alternate/test config dir would get the real repo's .env
  // injected. The resolver decides WHO is executing and does fall through.
  // Pinned by tests/fix-389-load-env-default-fallback T389-7.
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

module.exports = { loadEnv, loadDefaultEnv, filterOsBlocks };
