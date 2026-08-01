"use strict";

// Commit-time language check for staged text files (CODE_LANG surface).
// Policy from lang-config.js classifyPolicy(): english -> block CJK lines;
// japanese -> block English-only runs; other non-empty token -> hint-only;
// unset/"any" -> noop. CJK detection SSOT: detect-cjk.js hasCJK(). English-run
// detection reuses lint-plan-lang.js primitives (no reimplementation). Security:
// records store only file:line and the trimmed
// line capped at 80 chars -- never whole-file content -- so staged secrets are
// not echoed to the terminal.
//
// CODE_LANG_EXCLUDE (repo-granularity opt-out): when the repository root matches
// an entry, the whole check is skipped (return carries excluded:true so the
// pre-commit caller can emit a one-line audit trace) -- it is a repo-level
// bypass, not a per-file filter. Matching is delegated to path-coverage-match.js
// isCoveredByEntryList(), deliberately NOT shared-cmd-utils.isExcluded(): that
// helper adds basename matching and built-in exclude patterns, neither of which
// is wanted for a repo-root comparison. When the exclude list is non-empty but
// the repo root cannot be determined, check() throws -- the existing catch in
// hooks/pre-commit turns that into fail-open ("lint-commit-lang skipped").
// Known limitation (out of scope here): glob entries must be written in
// OS-native absolute path form, a constraint of the shared matcher.
// The matcher modules are required lazily, inside the gate, so the default
// (no exclusions) path keeps the pre-existing require graph unchanged.

const { spawnSync } = require("child_process");
const { hasCJK } = require("./detect-cjk");
const { loadLangConfig, classifyPolicy, loadCodeLangExclude } = require("./lang-config");
const { ENGLISH_RUN_RE } = require("./lint-plan-lang");

const MAX_LINE = 80;
const GIT_MAX_BUFFER = 64 * 1024 * 1024;

function git(args) {
  return spawnSync("git", args, { encoding: "buffer", maxBuffer: GIT_MAX_BUFFER });
}

// Absolute repository root, or null when it cannot be determined.
function repoRoot() {
  const r = git(["rev-parse", "--show-toplevel"]);
  if (r.error || r.status !== 0 || !r.stdout) return null;
  const root = r.stdout.toString("utf8").trim();
  return root.length === 0 ? null : root;
}

// Staged file paths (added/copied/modified/renamed-destination). Renames are
// included so a CJK file renamed into the commit is still scanned at its new path.
function stagedFiles() {
  const r = git(["diff", "--cached", "-z", "--name-only", "--diff-filter=ACMR"]);
  if (r.error || r.status !== 0 || !r.stdout) return [];
  return r.stdout.toString("utf8").split("\0").filter(Boolean);
}

// Staged blob bytes for a path, or null when git fails (e.g. delete race).
function stagedBlob(file) {
  const r = git(["show", ":" + file]);
  if (r.error || r.status !== 0 || !r.stdout) return null;
  return r.stdout;
}

function record(out, file, idx, line, reason) {
  out.push({ file, lineNumber: idx + 1, line: line.trim().slice(0, MAX_LINE), reason });
}

function scanCJK(file, content, out, reason) {
  content.split(/\r?\n/).forEach((line, idx) => {
    if (hasCJK(line)) record(out, file, idx, line, reason);
  });
}

function scanEnglishRun(file, content, out) {
  content.split(/\r?\n/).forEach((line, idx) => {
    if (!line.trim()) return;
    if (!hasCJK(line) && ENGLISH_RUN_RE.test(line)) {
      record(out, file, idx, line, "English-only run in japanese-policy file");
    }
  });
}

function check(options) {
  const opts = options || {};
  const violations = [];
  const hints = [];
  const saved = process.env.AGENTS_CONFIG_DIR;
  if (opts.configDir) process.env.AGENTS_CONFIG_DIR = opts.configDir;
  try {
    const policy = loadLangConfig("code");
    if (classifyPolicy(policy) === "noop") return { violations, hints };
    const raw = loadCodeLangExclude();
    // Cheap pre-filter (no entry can survive semicolon-split + trim otherwise):
    // keeps the matcher modules off the require graph for the default unset case.
    if (/[^;\s]/.test(raw)) {
      const { parseExcludePatterns } = require("./glob-match");
      if (parseExcludePatterns(raw).length > 0) {
        const { isCoveredByEntryList } = require("./path-coverage-match");
        const root = repoRoot();
        if (root === null) throw new Error("CODE_LANG_EXCLUDE is set but the repository root could not be determined");
        if (isCoveredByEntryList(raw, root)) return { violations: [], hints: [], excluded: true };
      }
    }
    for (const file of stagedFiles()) {
      const buf = stagedBlob(file);
      if (buf === null) continue;
      if (buf.includes(0x00)) continue;
      const content = buf.toString("utf8");
      if (content.includes("lang-check: ignore")) continue;
      if (policy === "english") {
        scanCJK(file, content, violations, "CJK in english-policy file");
      } else if (policy === "japanese") {
        scanEnglishRun(file, content, violations);
      } else {
        scanCJK(file, content, hints, "CJK in hint-tier file");
      }
    }
    return { violations, hints };
  } finally {
    if (opts.configDir) {
      if (saved === undefined) delete process.env.AGENTS_CONFIG_DIR;
      else process.env.AGENTS_CONFIG_DIR = saved;
    }
  }
}

module.exports = { check };
