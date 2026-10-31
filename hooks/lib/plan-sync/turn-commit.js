"use strict";
// hooks/lib/plan-sync/turn-commit.js
// Reading a turn's commits back from history through their trailers (turn-trailer.js):
// whether a commit is this turn's own replaceable commit, where a turn starts, and the
// range of commits one turn produced. A turn is {sid, turnId}.
const G = require("./git");
const { UNKNOWN_BASE, parseTurnMessage } = require("./turn-trailer");

const SCAN_LIMIT = 200;

const sameTurn = (t, turn) => Boolean(t && turn && t.sid === turn.sid && t.turnId === turn.turnId);

// turnBaseOf(plansDir, R, turn, opts) -> {X, parent, base, rels} | null — R is replaceable only
// when plan-sync itself wrote it for this very turn on a single parent.
function turnBaseOf(plansDir, R, turn, opts) {
  if (!R || !turn) return null;
  const out = G.gitOut(plansDir, ["log", "-1", "--format=%an%x00%ae%x00%P%x00%B", R, "--"], opts);
  if (out === null) return null;
  const [name, email, parents, body] = out.split("\0");
  if (name !== G.COMMIT_IDENTITY.GIT_AUTHOR_NAME || email !== G.COMMIT_IDENTITY.GIT_AUTHOR_EMAIL) return null;
  const ps = (parents || "").trim().split(/\s+/).filter(Boolean);
  if (ps.length !== 1) return null;
  const t = parseTurnMessage(body);
  if (!sameTurn(t, turn)) return null;
  return { X: R, parent: ps[0], base: t.base, rels: t.rels };
}

// logRecords(plansDir, args, tip, opts) -> [{sha, parents, trailer}] newest first, from `git log <args>`,
// or null when the log could not be read (failure, timeout, deadline passed, unreadable tip).
function logRecords(plansDir, args, tip, opts) {
  const out = G.gitOut(plansDir, ["log", "--first-parent", ...args, "--format=%H%x00%P%x00%B%x1e", tip, "--"], opts);
  if (out === null) return null;
  return out.split("\x1e").map((rec) => rec.replace(/^\r?\n/, "")).filter(Boolean).map((rec) => {
    const [sha, parents, body] = rec.split("\0");
    return { sha: sha.trim(), parents: (parents || "").trim().split(/\s+/).filter(Boolean), trailer: parseTurnMessage(body) };
  });
}

// firstParentLog(plansDir, tip, opts) -> [{sha, parents, trailer}] newest first, at most SCAN_LIMIT, or null.
const firstParentLog = (plansDir, tip, opts) => logRecords(plansDir, ["-n", String(SCAN_LIMIT)], tip, opts);

// sessionStart(log, R, turn) -> the base of the turn's newest commit (UNKNOWN_BASE included), R when
// the same session's previous turn comes first, or undefined when the log holds no commit of this session.
function sessionStart(log, R, turn) {
  for (const c of log) {
    if (!c.trailer || c.trailer.sid !== turn.sid) continue;
    return c.trailer.turnId === turn.turnId ? c.trailer.base : R;
  }
  return undefined;
}

// turnStartOf(plansDir, R, turn, opts) -> the Turn-Base a new commit of turn on R carries: the base
// of the turn's newest commit, or R when the same session's previous turn (or nothing) comes first.
// A full scan with no commit of this session cannot tell "none" from "older than the scan", so the
// whole history is searched for commits naming the sid or turnId, each judged by its trailer.
// Either log unreadable -> UNKNOWN_BASE (fail closed): R would drop this turn's older commits from its link.
function turnStartOf(plansDir, R, turn, opts) {
  if (!turn) return R;
  const log = firstParentLog(plansDir, R, opts);
  if (log === null) return UNKNOWN_BASE;
  const near = sessionStart(log, R, turn);
  if (near !== undefined) return near;
  if (log.length < SCAN_LIMIT) return R;
  const hits = logRecords(plansDir, ["--fixed-strings", `--grep=${turn.turnId}`, `--grep=${turn.sid}`], R, opts);
  if (hits === null) return UNKNOWN_BASE;
  const far = sessionStart(hits, R, turn);
  return far !== undefined ? far : R;
}

// turnRange(plansDir, tip, turn, opts) -> {base, turnCommits (newest first), interleaved} | null —
// null when the log is unreadable, the turn has no commit within the scan, its newest commit's base
// is UNKNOWN_BASE, or its base lies beyond the scan.
function turnRange(plansDir, tip, turn, opts) {
  const log = firstParentLog(plansDir, tip, opts);
  if (log === null) return null;
  const at = log.findIndex((c) => sameTurn(c.trailer, turn));
  if (at < 0) return null;
  const base = log[at].trailer.base;
  if (base === UNKNOWN_BASE) return null;
  const turnCommits = [];
  let interleaved = false;
  // Commits newer than the turn's last one do not interleave it.
  for (const c of log.slice(at)) {
    if (c.sha === base) return { base, turnCommits, interleaved };
    if (sameTurn(c.trailer, turn)) turnCommits.push(c.sha);
    else interleaved = true;
  }
  return null;
}

module.exports = { SCAN_LIMIT, turnBaseOf, turnStartOf, turnRange };
