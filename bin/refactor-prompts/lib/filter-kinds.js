"use strict";

const path = require("path");
const { execSync } = require("child_process");

// Kinds that carry syntactic tokens rather than user-visible command literals.
// Matching these in prose would produce false positives.
const SYNTACTIC_KINDS = new Set([
  "posix-redirect",
  "posix-tee",
  "posix-here-doc",
  "posix-here-string",
  "pwsh-alias",
  "pwsh-here",
  "interpreter",
]);

// Tool names used as the `tool` field in settings.json deny entries for
// path-guarding (Read, Edit, Write, Grep). These are not command literals.
const PATH_GUARD_TOOLS = new Set(["Read", "Edit", "Write", "Grep"]);

/**
 * Returns true if the pattern should be included in the keyword set.
 * Excludes syntactic kinds and patterns that represent path-guard tools.
 *
 * @param {{ kind?: string, name?: string }} pattern - entry from WRITE_PATTERNS or deny list
 */
function shouldIncludePattern(pattern) {
  const kind = pattern.kind || "";
  return !SYNTACTIC_KINDS.has(kind);
}

/**
 * Extracts a human-readable literal from a settings.json Bash deny entry.
 * Returns null if the entry should be skipped (sentinel, path-guard, or empty).
 *
 * Rules:
 *  1. Strip leading/trailing `*`
 *  2. Strip leading &&/;/|/& separators and spaces
 *  3. Collapse internal `*` sequences → single space
 *  4. Return null if starts with <<WORKFLOW_
 *  5. Return null if empty/whitespace after processing
 *
 * @param {string} s - raw command string from deny entry
 * @returns {string|null}
 */
function extractDenyLiteral(s) {
  if (typeof s !== "string") return null;

  let v = s.trim();
  // Strip leading/trailing wildcards
  v = v.replace(/^\*+/, "").replace(/\*+$/, "");
  // Strip leading chain operators and spaces
  v = v.replace(/^[&;|]+\s*/, "");
  v = v.trim();
  // Collapse internal wildcards to single space
  v = v.replace(/\s*\*+\s*/g, " ");
  v = v.trim();

  if (v.startsWith("<<WORKFLOW_")) return null;
  if (v === "") return null;

  return v;
}

/**
 * Resolves the absolute path to the agents repository root.
 * Prefers AGENTS_CONFIG_DIR env var; falls back to git rev-parse with a warning.
 *
 * @returns {string} absolute path (forward slashes on all platforms)
 */
function resolveAgentsRoot() {
  if (process.env.AGENTS_CONFIG_DIR) {
    return path.resolve(process.env.AGENTS_CONFIG_DIR).replace(/\\/g, "/");
  }
  try {
    const root = execSync("git rev-parse --show-toplevel", { encoding: "utf8" })
      .trim()
      .replace(/\\/g, "/");
    process.stderr.write(
      `refactor-prompts: AGENTS_CONFIG_DIR not set; falling back to git toplevel: ${root}\n`
    );
    return root;
  } catch {
    throw new Error(
      "refactor-prompts: cannot locate agents repo (AGENTS_CONFIG_DIR unset and not in a git repo)"
    );
  }
}

module.exports = {
  SYNTACTIC_KINDS,
  PATH_GUARD_TOOLS,
  shouldIncludePattern,
  extractDenyLiteral,
  resolveAgentsRoot,
};
