"use strict";
// bin/worker-dispatch/workers/commit-push/commit-timeout.js
//
// The commit timeout limit of the commit-push worker (#2762): how long `git commit`,
// pre-commit included, may run before it is stopped, and what the worker reports
// when it is. Every git call here goes through the caller's runGit at its default
// limit. What/Why — the order the limit is decided in, the coefficients, the
// pre-commit section marker contract, and the after-stop probes:
// docs/architecture/claude-code/worker-dispatch/commit-push.md
// "The commit timeout limit and the pre-commit section marker"

const fs = require("fs");
const path = require("path");

const COMMIT_TIMEOUT_KEY = "COMMIT_TIMEOUT_SECS";
const COMMIT_TIMEOUT_FLOOR_MS = 300000;
const COMMIT_TIMEOUT_PER_FILE_MS = 5000;
const COMMIT_TIMEOUT_CAP_MS = 3600000;
const COMMIT_TIMEOUT_SETTING_MAX_SECS = 86400;
const MARKER_MAX_CHARS = 48;

const SECTION_MARKER_RE = /^pre-commit-section: ([a-z0-9][a-z0-9-]*)\s*$/;

function parseCommitTimeoutSetting(raw) {
  if (raw === undefined || raw === null) return { kind: "unset", ms: null, raw };
  const v = String(raw).trim();
  if (v === "") return { kind: "unset", ms: null, raw };
  // The length check runs first so an overlong digit string never reaches Number().
  if (v.length > 5 || !/^[1-9][0-9]*$/.test(v) || Number(v) > COMMIT_TIMEOUT_SETTING_MAX_SECS) {
    return { kind: "invalid", ms: null, raw };
  }
  return { kind: "valid", ms: Number(v) * 1000, raw };
}

function computeCommitTimeoutMs(stagedCount) {
  if (!Number.isInteger(stagedCount) || stagedCount < 0) return COMMIT_TIMEOUT_FLOOR_MS;
  return Math.min(COMMIT_TIMEOUT_CAP_MS, Math.max(COMMIT_TIMEOUT_FLOOR_MS, stagedCount * COMMIT_TIMEOUT_PER_FILE_MS));
}

// A valid setting is used as-is, with neither floor nor cap. `staged` is the count or a
// function returning it, called only when the limit is computed.
function resolveCommitTimeoutLimit(cfg, staged) {
  const setting = parseCommitTimeoutSetting((cfg || {})[COMMIT_TIMEOUT_KEY]);
  if (setting.kind === "valid") {
    return { ms: setting.ms, source: "env", invalidRaw: null, stagedCount: typeof staged === "function" ? null : staged };
  }
  const stagedCount = typeof staged === "function" ? staged() : staged;
  return {
    ms: computeCommitTimeoutMs(stagedCount),
    source: "computed",
    invalidRaw: setting.kind === "invalid" ? setting.raw : null,
    stagedCount,
  };
}

function answered(res) {
  return res !== null && res !== undefined && res.spawnError === null && !res.timedOut;
}

function countStagedFiles(runGit, ctx, payload, log) {
  const res = runGit(ctx, payload, ["diff", "--cached", "--name-only", "-z"], log);
  if (!answered(res) || res.status !== 0) {
    log.push("staged files could not be counted; the commit timeout limit falls back to its floor");
    return null;
  }
  return String(res.stdout || "").split("\0").filter((n) => n !== "").length;
}

// status 1 with no output is an unborn branch: known, but no commit yet.
function probeHead(runGit, ctx, payload, log) {
  const res = runGit(ctx, payload, ["rev-parse", "--verify", "--quiet", "HEAD"], log);
  if (!answered(res)) return { known: false };
  const sha = String(res.stdout || "").trim();
  if (res.status === 0 && sha !== "") return { known: true, sha };
  if (res.status === 1 && sha === "") return { known: true, sha: null };
  return { known: false };
}

function describeAfterState({ headBefore, headAfter }) {
  if (!headBefore || !headAfter || headBefore.known !== true || headAfter.known !== true) return "unknown";
  return headBefore.sha === headAfter.sha ? "unchanged" : "advanced";
}

// Read-only: a left index.lock is reported, never removed.
function probeIndexLock(runGit, ctx, payload, log) {
  const res = runGit(ctx, payload, ["rev-parse", "--git-path", "index.lock"], log);
  if (!answered(res) || res.status !== 0) return "unknown";
  const rel = String(res.stdout || "").trim();
  if (rel === "") return "unknown";
  try {
    return fs.existsSync(path.resolve(payload.worktree_path, rel)) ? "left" : "none";
  } catch (_e) {
    return "unknown";
  }
}

function inspectAfterCommitTimeout(runGit, ctx, payload, log, headBefore) {
  const headAfter = probeHead(runGit, ctx, payload, log);
  const after = {
    head: describeAfterState({ headBefore, headAfter }),
    indexLock: probeIndexLock(runGit, ctx, payload, log),
  };
  log.push(`after the commit timeout: HEAD ${after.head}, index.lock ${after.indexLock}`);
  return after;
}

function sectionMarkerName(line) {
  const m = SECTION_MARKER_RE.exec(String(line).replace(/\r$/, ""));
  return m ? m[1] : null;
}

function lastSectionMarker(stderr) {
  let last = "unknown";
  for (const line of String(stderr || "").split("\n")) {
    const name = sectionMarkerName(line);
    if (name !== null) last = name;
  }
  return last;
}

// The first non-blank stderr line that is not a pre-commit section marker, or "".
function firstNonMarkerLine(stderr) {
  return String(stderr || "")
    .split(/\r?\n/)
    .find((l) => l.trim() !== "" && sectionMarkerName(l) === null) || "";
}

const HEAD_WORDS = { unchanged: "HEAD unchanged", advanced: "HEAD advanced", unknown: "HEAD unknown" };
const LOCK_WORDS = { left: "index.lock left", none: "no index.lock", unknown: "index.lock unknown" };

function formatCommitTimeoutSummary({ elapsedMs, limit, marker, after }) {
  const secs = (ms) => Math.round((Number(ms) || 0) / 1000);
  const source = limit.source === "env"
    ? `limit ${secs(limit.ms)}s set by ${COMMIT_TIMEOUT_KEY}`
    : `limit ${secs(limit.ms)}s from ${limit.stagedCount === null || limit.stagedCount === undefined ? "an unknown number of" : limit.stagedCount} staged files`;
  const name = String(marker || "unknown").slice(0, MARKER_MAX_CHARS);
  const head = HEAD_WORDS[after && after.head] || HEAD_WORDS.unknown;
  const lock = LOCK_WORDS[after && after.indexLock] || LOCK_WORDS.unknown;
  return `git commit timed out after ${secs(elapsedMs)}s (${source}); last pre-commit section: ${name}; `
    + `after stop: ${head}, ${lock}. Raise ${COMMIT_TIMEOUT_KEY} in .env to allow longer.`;
}

module.exports = {
  parseCommitTimeoutSetting,
  computeCommitTimeoutMs,
  resolveCommitTimeoutLimit,
  countStagedFiles,
  probeHead,
  describeAfterState,
  inspectAfterCommitTimeout,
  lastSectionMarker,
  firstNonMarkerLine,
  formatCommitTimeoutSummary,
  COMMIT_TIMEOUT_KEY,
  COMMIT_TIMEOUT_FLOOR_MS,
  COMMIT_TIMEOUT_PER_FILE_MS,
  COMMIT_TIMEOUT_CAP_MS,
  COMMIT_TIMEOUT_SETTING_MAX_SECS,
};
