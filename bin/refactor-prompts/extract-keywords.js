"use strict";

const fs = require("fs");
const path = require("path");

const {
  resolveAgentsRoot,
  shouldIncludePattern,
  extractDenyLiteral,
  PATH_GUARD_TOOLS,
} = require("./lib/filter-kinds");

// Map pkg-mgr pattern names to their canonical bare-verb form.
const PKG_MGR_LITERALS = {
  "npm-write": "npm install",
  "pnpm-write": "pnpm install",
  "yarn-write": "yarn install",
  "pip-write": "pip install",
  "uv-write": "uv pip install",
  "cargo-write": "cargo install",
  "go-write": "go install",
};

// Strip trailing qualifiers that are not part of the command literal.
const TRAIL_STRIP = /-(write|mutate|force|extract|inplace|c)$/;

/**
 * Derives a human-readable literal from a WRITE_PATTERNS entry.
 *
 * @param {{ name: string, kind: string }} entry
 * @returns {string|null}
 */
function patternToLiteral(entry) {
  const { name, kind } = entry;
  if (!shouldIncludePattern(entry)) return null;

  if (kind === "git") {
    const sub = name.replace(/^git-/, "").replace(TRAIL_STRIP, "");
    return `git ${sub}`;
  }
  if (kind === "gh") {
    const sub = name
      .replace(/^gh-/, "")
      .replace(/-/g, " ")
      .replace(/ (write|mutate)$/, "")
      .trim();
    return `gh ${sub}`;
  }
  if (kind === "pkg-mgr") {
    return PKG_MGR_LITERALS[name] || name.replace(TRAIL_STRIP, "");
  }
  if (kind === "file-op") {
    return name.replace(TRAIL_STRIP, "");
  }
  // pwsh, pwsh-encoded: use name as-is (cmdlet / flag names)
  return name;
}

/**
 * Parses a settings.json deny entry string and returns a literal, or null.
 * Format: "Tool(pattern)" — only Bash entries produce keywords.
 *
 * @param {string} entry
 * @returns {string|null}
 */
function denyEntryToLiteral(entry) {
  if (typeof entry !== "string") return null;
  const m = entry.match(/^([A-Za-z]+)\((.+)\)$/s);
  if (!m) return null;
  const [, tool, inner] = m;
  if (PATH_GUARD_TOOLS.has(tool)) return null;
  if (tool !== "Bash") return null;
  return extractDenyLiteral(inner);
}

/**
 * Extracts up to `cap` command-name keywords from enforce-system-ops.js source
 * by scanning regex literals for command patterns.
 *
 * @param {string} src - file contents
 * @param {number} cap - max keywords to return
 * @returns {string[]}
 */
function extractSysOpsKeywords(src, cap) {
  const seen = new Set();
  // Match /regex/ literals in the JS source
  const reLiteral = /\/(?:[^/\\]|\\.)+\//g;
  let rm;
  while ((rm = reLiteral.exec(src)) !== null && seen.size < cap) {
    const body = rm[0];
    // Find command names after (?:sudo\s+)? or after word-break anchors
    const cmdPat = /\(\?:sudo\\s\+\)\??([a-zA-Z][\w.-]+)(?:\\s|\\b)/g;
    let cm;
    while ((cm = cmdPat.exec(body)) !== null && seen.size < cap) {
      const cmd = cm[1];
      if (cmd.length >= 3) seen.add(cmd);
    }
  }
  return [...seen];
}

// ---- Main ------------------------------------------------------------------

const root = resolveAgentsRoot();
const sources = [];
const keywordMap = new Map(); // literal → source (first wins)

// ---- Source 1: bash-write-patterns.js ----
const patternsPath = path.join(root, "hooks/lib/bash-write-patterns.js").replace(/\\/g, "/");
if (!fs.existsSync(patternsPath)) {
  process.stderr.write(`refactor-prompts: error: required source not found: ${patternsPath}\n`);
  process.exit(1);
}
try {
  const { WRITE_PATTERNS } = require(patternsPath);
  sources.push("bash-write-patterns.js");
  for (const p of WRITE_PATTERNS) {
    const lit = patternToLiteral(p);
    if (lit && !keywordMap.has(lit)) {
      keywordMap.set(lit, "bash-write-patterns.js");
    }
  }
} catch (e) {
  process.stderr.write(`refactor-prompts: error loading bash-write-patterns.js: ${e.message}\n`);
  process.exit(1);
}

// ---- Source 2: settings.json deny array ----
const settingsPath = path.join(root, "settings.json").replace(/\\/g, "/");
if (!fs.existsSync(settingsPath)) {
  process.stderr.write(`refactor-prompts: error: required source not found: ${settingsPath}\n`);
  process.exit(1);
}
try {
  const settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  const deny = (settings.permissions && settings.permissions.deny) || settings.deny || [];
  sources.push("settings.json");
  for (const entry of deny) {
    const lit = denyEntryToLiteral(entry);
    if (lit && !keywordMap.has(lit)) {
      keywordMap.set(lit, "settings.json");
    }
  }
} catch (e) {
  process.stderr.write(`refactor-prompts: error loading settings.json: ${e.message}\n`);
  process.exit(1);
}

// ---- Source 3: enforce-system-ops.js (fail-soft) ----
const sysOpsPath = path.join(root, "hooks/enforce-system-ops.js").replace(/\\/g, "/");
if (!fs.existsSync(sysOpsPath)) {
  process.stderr.write(`refactor-prompts: WARN: hooks/enforce-system-ops.js not found; skipping\n`);
} else {
  try {
    const src = fs.readFileSync(sysOpsPath, "utf8");
    sources.push("enforce-system-ops.js");
    const cmds = extractSysOpsKeywords(src, 50);
    for (const cmd of cmds) {
      if (!keywordMap.has(cmd)) {
        keywordMap.set(cmd, "enforce-system-ops.js");
      }
    }
  } catch (e) {
    process.stderr.write(`refactor-prompts: WARN: error reading enforce-system-ops.js: ${e.message}; skipping\n`);
  }
}

// ---- Emit JSON ----
const keywords = [...keywordMap.entries()].map(([literal, source]) => ({ literal, source }));
process.stdout.write(JSON.stringify({ version: 1, sources, keywords }, null, 2) + "\n");
