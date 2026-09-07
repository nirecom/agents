// hooks/lib/merge-detect.js — classifier for "merge to protected branch" commands.
// Consumed by workflow-gate.js (PreToolUse hard gate) and workflow-mark.js (post-push reset).
// Returns { hit, kind }: "gh-pr-merge" | "git-push-protected" | null.
// Only canonical flag forms are parsed, and only Claude Code Bash calls reach it — the
// gate is a workflow assistant, not OS-level access control.
// Segmentation owner: hooks/lib/command-ir/ (canary-1 consumer of parse()).
// Ownership map: docs/architecture/claude-code/shell-command-parsing.md.

"use strict";

const { parseGitGlobalOptions } = require("./parse-git-args");
const { parse, analysisOf } = require("./command-ir");

function getProtectedBranches() {
  const env = (process.env.DEFAULT_BRANCHES || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  return env.length ? env : ["main", "master"];
}

function checkSegment(segment) {
  if (!segment) return { hit: false, kind: null };

  // gh pr merge — any flags (--auto, --squash, --rebase, --merge, --delete-branch, etc.)
  if (/^\s*gh\s+pr\s+merge\b/.test(segment)) {
    return { hit: true, kind: "gh-pr-merge" };
  }

  // Must start with "git" to be a git push
  if (!/^\s*git\b/.test(segment)) {
    return { hit: false, kind: null };
  }

  const { subcommand, rest } = parseGitGlobalOptions(segment);
  if (subcommand !== "push") return { hit: false, kind: null };

  const protectedBranches = getProtectedBranches();

  // --all / --mirror push every local branch including protected ones
  if (/(?:^|\s)--(?:all|mirror)\b/.test(" " + rest)) {
    return { hit: true, kind: "git-push-protected" };
  }

  // Tokenize quote-aware, drop flags, drop remote name (first non-flag)
  const tokens = (rest.match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g) || []).filter(
    (t) => !t.startsWith("-")
  );
  const refspecs = tokens.slice(1);
  if (refspecs.length === 0) return { hit: false, kind: null };

  for (const spec of refspecs) {
    const s = spec.replace(/^\+/, "");  // strip force-shorthand
    let dst = s.includes(":") ? s.split(":")[1] : s;
    dst = (dst || "").replace(/^refs\/heads\//, "");
    if (dst && protectedBranches.includes(dst)) {
      return { hit: true, kind: "git-push-protected" };
    }
  }
  return { hit: false, kind: null };
}

// A backslash-escaped separator (`\;`, `\&&`) is a literal argument, not a split point:
// `echo x \; git push origin main` is ONE echo. The splitter records the split anyway and
// the IR flags the link, so rejoin those neighbours before classifying.
function segmentTexts(ir) {
  const raw = ir.segments.map((s) => s.rawText);
  const joinAfter = new Map();
  analysisOf(ir).separatorLinks.forEach((l) => {
    if (l.escaped && l.leftSegment != null && l.rightSegment != null) joinAfter.set(l.leftSegment, l.sep);
  });
  if (joinAfter.size === 0) return raw;
  const out = [];
  raw.forEach((text, i) => {
    if (i > 0 && joinAfter.has(i - 1)) out[out.length - 1] += joinAfter.get(i - 1) + text;
    else out.push(text);
  });
  return out;
}

function isMergeToProtectedCommand(command, _repoDir) {
  if (!command || typeof command !== "string") {
    return { hit: false, kind: null };
  }
  // Fail-closed on parse failure: inspect the whole command as one segment rather than
  // skipping the check, so malformed input never loosens the gate (#2125).
  const ir = parse(command);
  const segments =
    ir.parseFailure === true || !Array.isArray(ir.segments) || ir.segments.length === 0
      ? [command]
      : segmentTexts(ir);

  for (const segment of segments) {
    const result = checkSegment(segment);
    if (result.hit) return result;
  }
  return { hit: false, kind: null };
}

module.exports = { isMergeToProtectedCommand, getProtectedBranches };
