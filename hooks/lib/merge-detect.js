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
const { resolveEffectiveCommand, resolveEffectiveArgv, scanWrappedVerb, commandBasename } = require("./bash-write-patterns/segment-utils");
const { quoteIfNeeded } = require("./commit-detect");

const RECONSTRUCTED_HEADS = new Set(["gh", "git"]);

// Rewrite a wrapped segment (`rtk gh pr merge`, `env git push`) to its effective
// `gh ...` / `git ...` text so the head-anchored checks below see it. An AMBIGUOUS
// peel falls back to the raw argv after the first gh/git token (fail-closed).
function effectiveSegmentText(segment) {
  const ir = parse(segment);
  if (ir.parseFailure === true || !Array.isArray(ir.segments) || ir.segments.length === 0) return segment;
  const seg = ir.segments[0];
  const head = commandBasename(resolveEffectiveCommand(seg));
  if (RECONSTRUCTED_HEADS.has(head)) return head + " " + resolveEffectiveArgv(seg).map(quoteIfNeeded).join(" ");
  // Handle sh -c shell body produced by `rtk run "gh pr merge …"` via shellBodyVerbs
  if (head === "sh" || head === "bash") {
    const ea = resolveEffectiveArgv(seg);
    if (ea[0] === "-c" && typeof ea[1] === "string") return ea[1];
  }
  let hidden = null;
  scanWrappedVerb(seg, (tok, rest) => {
    const base = commandBasename(tok);
    if (!RECONSTRUCTED_HEADS.has(base)) return false;
    const candidate = base + " " + rest.map(quoteIfNeeded).join(" ");
    if (!checkText(candidate).hit) return false;
    hidden = candidate;
    return true;
  });
  return hidden !== null ? hidden : segment;
}

function checkSegment(segment) {
  if (!segment) return { hit: false, kind: null };
  const direct = checkText(segment);
  if (direct.hit) return direct;
  const effective = effectiveSegmentText(segment);
  if (effective === segment) return { hit: false, kind: null };
  // Parse the effective text so compound shell bodies (e.g. `echo ok && git push origin main`)
  // are split into their constituent segments before classification.
  const ir = parse(effective);
  const texts =
    !ir.parseFailure && Array.isArray(ir.segments) && ir.segments.length > 0
      ? segmentTexts(ir)
      : [effective];
  for (const t of texts) {
    const r = checkText(t);
    if (r.hit) return r;
  }
  return { hit: false, kind: null };
}

function getProtectedBranches() {
  const env = (process.env.DEFAULT_BRANCHES || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  return env.length ? env : ["main", "master"];
}

function checkText(segment) {
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
