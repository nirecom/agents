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
 * Extracts a human-readable literal from a settings.json Bash deny entry: strips edge
 * `*`, leading &&/;/|/& separators, collapses internal `*` runs to one space.
 * Returns null for a <<WORKFLOW_ sentinel or an empty result.
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
 * Resolves the root of the checkout whose prompts and sources are read.
 * --target-checkout-root wins; without it the agents main root (AGENTS_MAIN_ROOT);
 * without that, the git toplevel with a warning.
 *
 * @param {string|null|undefined} targetCheckoutRoot - the --target-checkout-root value
 * @returns {string} absolute path (forward slashes on all platforms)
 */
function resolveTargetCheckoutRoot(targetCheckoutRoot) {
  if (targetCheckoutRoot) {
    return path.resolve(targetCheckoutRoot).replace(/\\/g, "/");
  }
  if (process.env.AGENTS_MAIN_ROOT) {
    return path.resolve(process.env.AGENTS_MAIN_ROOT).replace(/\\/g, "/");
  }
  try {
    const root = execSync("git rev-parse --show-toplevel", { encoding: "utf8" })
      .trim()
      .replace(/\\/g, "/");
    process.stderr.write(
      `refactor-prompts: --target-checkout-root and AGENTS_MAIN_ROOT not set; falling back to git toplevel: ${root}\n`
    );
    return root;
  } catch {
    throw new Error(
      "refactor-prompts: cannot locate the target checkout (--target-checkout-root and AGENTS_MAIN_ROOT unset, and not in a git repo)"
    );
  }
}

/**
 * Reads --target-checkout-root from argv. A flag with no value is a usage error.
 *
 * @param {string[]} args
 * @returns {{ value: string|null, error: string|null }}
 */
function readTargetCheckoutRootFlag(args) {
  const i = args.indexOf("--target-checkout-root");
  if (i === -1) return { value: null, error: null };
  const v = args[i + 1];
  if (v === undefined || v === "" || v.startsWith("--")) {
    return { value: null, error: "--target-checkout-root needs a value" };
  }
  return { value: v, error: null };
}

module.exports = {
  SYNTACTIC_KINDS,
  PATH_GUARD_TOOLS,
  shouldIncludePattern,
  extractDenyLiteral,
  resolveTargetCheckoutRoot,
  readTargetCheckoutRootFlag,
};
