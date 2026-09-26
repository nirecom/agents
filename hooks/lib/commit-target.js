"use strict";
// hooks/lib/commit-target.js — commit repo-dir resolution + inline Bash write extractor.
// Extracted from hooks/scan-outbound.js (file-split rule: >300 lines).

const path = require("path");
const { spawnSync } = require("child_process");
const { parse, analysisOf } = require("./command-ir");
const { FLAGS_WITH_ARG } = require("./parse-git-args");
const { parseCdCommand } = require("./parse-git-args");
const { toNativePath } = require("./is-private-repo");

// Split a shell command into top-level parts at && / || / ; / | separators.
// Quote-aware so separators inside strings are not treated as boundaries.
function splitTopLevel(cmd) {
  const parts = [];
  let cur = "";
  let inSingle = false, inDouble = false;
  for (let i = 0; i < cmd.length; i++) {
    const c = cmd[i];
    if (c === "\\" && inDouble && i + 1 < cmd.length) { cur += c + cmd[++i]; continue; }
    if (c === "'" && !inDouble) { inSingle = !inSingle; cur += c; continue; }
    if (c === '"' && !inSingle) { inDouble = !inDouble; cur += c; continue; }
    if (!inSingle && !inDouble) {
      const two = cmd.slice(i, i + 2);
      if (two === "&&" || two === "||") { parts.push(cur); cur = ""; i++; continue; }
      if (c === ";" || c === "|") { parts.push(cur); cur = ""; continue; }
    }
    cur += c;
  }
  if (cur.trim()) parts.push(cur);
  return parts;
}

// Tokenize a shell fragment the same way bash tokenizes flags before a subcommand.
// Returns an array of tokens with outer quotes stripped but inner content intact.
function tokenizeGitTail(tail) {
  return (tail.match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g) || []).map((t) => {
    if ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'"))) {
      return t.slice(1, -1);
    }
    return t;
  });
}

// Find the git commit segment in a command and collect ordered -C values.
// Returns { cValues } when a commit segment is found, null otherwise.
function findCommitCValues(command) {
  if (!command || typeof command !== "string") return null;
  for (const part of splitTopLevel(command)) {
    const m = part.match(/^[^|;&]*\bgit(?:\.exe)?\b\s+(.*)/i);
    if (!m) continue;
    const tokens = tokenizeGitTail(m[1]);
    const cValues = [];
    let i = 0;
    while (i < tokens.length && tokens[i].startsWith("-")) {
      const tok = tokens[i];
      const eq = tok.indexOf("=");
      const key = eq === -1 ? tok : tok.slice(0, eq);
      if (key === "-C") {
        const val = eq !== -1 ? tok.slice(eq + 1) : (i + 1 < tokens.length ? tokens[i + 1] : "");
        cValues.push(eq !== -1 ? val : (i + 1 < tokens.length ? (i++, tokens[i]) : ""));
        i++;
      } else if (FLAGS_WITH_ARG.has(key) && eq === -1) {
        i += 2;
      } else {
        i++;
      }
    }
    if (i < tokens.length && tokens[i] === "commit") return { cValues };
  }
  return null;
}

/**
 * Resolve the git repo directory for a Bash `git commit` command.
 * Uses parseCdCommand → toolInputCwd → process.cwd() as base, then folds -C chain.
 * Returns a Windows-native path string.
 */
function resolveCommitRepoDir(command, toolInputCwd) {
  const rawBase = parseCdCommand(command || "") || toolInputCwd || process.cwd();
  const baseCwd = toNativePath(rawBase);

  if (!command || typeof command !== "string") return baseCwd;

  const result = findCommitCValues(command);
  if (result === null) return baseCwd;

  const { cValues } = result;

  let effective = baseCwd;
  for (const val of cValues) {
    if (!val) continue;
    const norm = toNativePath(val);
    if (path.isAbsolute(norm)) {
      effective = norm;
    } else {
      effective = path.resolve(effective, norm);
    }
  }

  if (cValues.length === 0) {
    try {
      const r = spawnSync("git", ["-C", effective, "rev-parse", "--show-toplevel"], {
        encoding: "utf8", timeout: 5000,
      });
      if (r.status === 0 && r.stdout) return toNativePath(r.stdout.trim());
    } catch (_) { /* fall-open */ }
  }

  return effective;
}

/**
 * Extract inline content from a non-forge, non-commit Bash file-write command.
 * Only returns content when the command writes to a file (has a redirect or
 * heredoc-to-file). Returns null when no file-write inline content is found.
 */
function extractInlineBashWriteContent(command) {
  if (!command || typeof command !== "string") return null;
  const ir = parse(command);
  if (!ir || ir.parseFailure) return null;
  const analysis = analysisOf(ir);
  const parts = [];

  if (analysis.heredocs.length > 0) {
    const lines = command.split("\n");
    for (const h of analysis.heredocs) {
      if (!h.terminated) continue;
      const openerLine = lines[h.line] || "";
      if (!openerLine.includes(">")) continue;
      const body = lines.slice(h.bodyStart, h.bodyEnd).join("\n");
      if (body) parts.push(body);
    }
  }

  const echoRe = /^\s*(?:echo|printf)\s+((?:'[^']*'|"[^"]*"|[^\s>])+)\s*>/;
  const echoM = command.match(echoRe);
  if (echoM) {
    let arg = echoM[1].trim();
    if ((arg.startsWith("'") && arg.endsWith("'")) || (arg.startsWith('"') && arg.endsWith('"'))) {
      arg = arg.slice(1, -1);
    }
    if (arg) parts.push(arg);
  }

  return parts.length ? parts.join("\n") : null;
}

module.exports = { resolveCommitRepoDir, extractInlineBashWriteContent };
