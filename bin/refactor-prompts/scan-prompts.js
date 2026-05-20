"use strict";

const fs = require("fs");
const path = require("path");
const { resolveAgentsRoot } = require("./lib/filter-kinds");

// ---------------------------------------------------------------------------
// CLI argument parsing
// ---------------------------------------------------------------------------
const args = process.argv.slice(2);
let keywordsArg = null;
let contextLines = 3;

for (let i = 0; i < args.length; i++) {
  if (args[i] === "--keywords" && args[i + 1]) {
    keywordsArg = args[++i];
  } else if (args[i] === "--context-lines" && args[i + 1]) {
    const n = parseInt(args[++i], 10);
    if (!isNaN(n) && n >= 0) contextLines = n;
  }
}

if (keywordsArg !== "-") {
  process.stderr.write("scan-prompts: --keywords - (read from stdin) is required\n");
  process.exit(2);
}

// ---------------------------------------------------------------------------
// Read keyword list from stdin
// ---------------------------------------------------------------------------
function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch {
    // EOF
  }
  return Buffer.concat(chunks).toString("utf8").replace(/\r\n/g, "\n");
}

let keywordsDoc;
try {
  keywordsDoc = JSON.parse(readStdin());
} catch (e) {
  process.stderr.write(`scan-prompts: failed to parse keywords JSON from stdin: ${e.message}\n`);
  process.exit(2);
}

const keywords = (keywordsDoc.keywords || []).filter(
  (k) => typeof k.literal === "string" && k.literal.length > 0
);

// ---------------------------------------------------------------------------
// Build regex for each keyword (word-boundary, whitespace-normalized)
// ---------------------------------------------------------------------------
function escapeRegex(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Returns a regex that matches the keyword literal even if the source file
 * uses extra internal whitespace (e.g., "git commit  --amend").
 * Uses negative lookbehind/lookahead for word boundaries.
 */
function buildKeywordRegex(literal) {
  const normalized = literal.trim().replace(/\s+/g, " ");
  // Replace each internal space in the keyword with \s+ so double spaces in
  // the scanned file still match.
  const parts = normalized.split(" ").map(escapeRegex);
  const core = parts.join("\\s+");
  // Word boundary: not preceded or followed by [A-Za-z0-9_-]
  return new RegExp(`(?<![A-Za-z0-9_\\-])${core}(?![A-Za-z0-9_\\-])`, "g");
}

const compiled = keywords
  .map((k) => {
    try {
      return { keyword: k, regex: buildKeywordRegex(k.literal) };
    } catch {
      return null;
    }
  })
  .filter(Boolean);

// ---------------------------------------------------------------------------
// Discover target files (fixed scope, unconditional tests/ exclusion)
// ---------------------------------------------------------------------------
const root = resolveAgentsRoot();

function globSync(base, pattern) {
  const results = [];
  if (!fs.existsSync(base)) return results;
  if (pattern === "*.md") {
    for (const f of fs.readdirSync(base)) {
      if (f.endsWith(".md")) results.push(path.join(base, f));
    }
    return results;
  }
  // "*/SKILL.md" — one level deep
  if (pattern === "*/SKILL.md") {
    for (const dir of fs.readdirSync(base)) {
      const candidate = path.join(base, dir, "SKILL.md");
      if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) {
        results.push(candidate);
      }
    }
    return results;
  }
  return results;
}

function normalizePath(p) {
  return p.replace(/\\/g, "/");
}

/**
 * Returns true if the file path (normalized, forward slashes) is inside
 * a `tests/` directory relative to the agents root.
 */
function isUnderTests(filePath) {
  const rel = normalizePath(filePath).replace(normalizePath(root) + "/", "");
  return rel === "tests" || rel.startsWith("tests/");
}

const targetFiles = [];

for (const [base, pattern] of [
  [path.join(root, "rules"), "*.md"],
  [path.join(root, "skills"), "*/SKILL.md"],
  [path.join(root, "agents"), "*.md"],
]) {
  for (const f of globSync(base, pattern)) {
    if (!isUnderTests(f)) targetFiles.push(f);
  }
}

// ---------------------------------------------------------------------------
// Scan files
// ---------------------------------------------------------------------------
const hotRegions = [];

for (const filePath of targetFiles) {
  let raw;
  try {
    raw = fs.readFileSync(filePath, "utf8").replace(/\r\n/g, "\n");
  } catch {
    continue;
  }
  const lines = raw.split("\n");

  for (const { keyword, regex } of compiled) {
    regex.lastIndex = 0;
    for (let i = 0; i < lines.length; i++) {
      regex.lastIndex = 0;
      if (regex.test(lines[i])) {
        const start = Math.max(0, i - contextLines);
        const end = Math.min(lines.length - 1, i + contextLines);
        const context = lines.slice(start, end + 1);
        hotRegions.push({
          file: normalizePath(filePath),
          line: i + 1, // 1-based
          matched_keyword: keyword.literal,
          keyword_source: keyword.source,
          context,
        });
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Emit JSON
// ---------------------------------------------------------------------------
process.stdout.write(
  JSON.stringify(
    {
      version: 1,
      scanned_files: targetFiles.length,
      hot_regions: hotRegions,
    },
    null,
    2
  ) + "\n"
);
