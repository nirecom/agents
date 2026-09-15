"use strict";

// #2256 S2-e — working-tree diff resolution for the supervisor audit.
// changedFiles is the UNION of committed, staged, unstaged and untracked paths:
// scope drift and the input version must not miss a change state.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { getProtectedBranches } = require("./merge-detect");

// Git Bash delivers `/c/path`; Node fs/spawnSync need `C:\path`. No-op on POSIX.
function toWindowsPath(raw) {
  if (typeof raw !== "string" || raw === "") return raw;
  if (process.platform !== "win32") return raw;
  const m = raw.match(/^\/([a-zA-Z])(\/.*)?$/);
  if (m) return `${m[1].toUpperCase()}:${(m[2] || "/").replace(/\//g, "\\")}`;
  return raw;
}

function git(cwd, args, encoding) {
  return spawnSync("git", args, { cwd, encoding: encoding || "utf8", maxBuffer: 256 * 1024 * 1024 });
}

function resolveMergeBase(cwd) {
  const refs = [];
  for (const b of getProtectedBranches()) {
    refs.push(`origin/${b}`);
    refs.push(b);
  }
  for (const ref of refs) {
    const r = git(cwd, ["merge-base", ref, "HEAD"]);
    if (r.status === 0 && r.stdout && r.stdout.trim()) return r.stdout.trim();
  }
  return null;
}

// Parse `git diff --raw -z` output into { raw, paths, dstMode, dstSha } records.
function parseRawZ(text) {
  const records = [];
  if (!text) return records;
  const fields = text.split("\0");
  let i = 0;
  while (i < fields.length) {
    const meta = fields[i];
    if (!meta || meta[0] !== ":") { i += 1; continue; }
    const m = meta.match(/^:(\d{6}) (\d{6}) ([0-9a-f]+) ([0-9a-f]+) ([A-Z])(\d*)$/);
    const status = m ? m[5] : "M";
    const pathCount = (status === "R" || status === "C") ? 2 : 1;
    const paths = [];
    for (let k = 1; k <= pathCount; k++) {
      const p = fields[i + k];
      if (typeof p === "string" && p !== "") paths.push(p.replace(/\\/g, "/"));
    }
    records.push({
      raw: meta + "\0" + paths.join("\0"),
      paths,
      dstMode: m ? m[2] : null,
      dstSha: m ? m[4] : null,
    });
    i += pathCount + 1;
  }
  return records;
}

function listUntracked(cwd) {
  const r = git(cwd, ["ls-files", "--others", "--exclude-standard", "-z"]);
  if (r.status !== 0 || !r.stdout) return [];
  return r.stdout.split("\0").filter(Boolean).map((p) => p.replace(/\\/g, "/"));
}

// Resolve the whole change surface of a working tree against its merge base.
// Returns null when git is unavailable, the cwd is not a repo, or no merge base
// against a protected branch can be resolved.
function computeWorkingTreeDiff(rawCwd) {
  try {
    const cwd = toWindowsPath(rawCwd);
    if (!cwd || !fs.existsSync(cwd)) return null;
    const inside = git(cwd, ["rev-parse", "--is-inside-work-tree"]);
    if (inside.status !== 0 || String(inside.stdout || "").trim() !== "true") return null;
    const mergeBase = resolveMergeBase(cwd);
    if (!mergeBase) return null;

    const committed = git(cwd, ["diff", "--raw", "-z", "--abbrev=40", "--find-renames", `${mergeBase}...HEAD`]);
    const working = git(cwd, ["diff", "--raw", "-z", "--abbrev=40", "HEAD"]);
    const rawRecords = []
      .concat(committed.status === 0 ? parseRawZ(committed.stdout) : [])
      .concat(working.status === 0 ? parseRawZ(working.stdout) : []);

    const untrackedFiles = listUntracked(cwd);
    const changed = new Set(untrackedFiles);
    for (const rec of rawRecords) for (const p of rec.paths) changed.add(p);

    const branchDiff = git(cwd, ["diff", `${mergeBase}...HEAD`]);
    const uncommittedDiff = git(cwd, ["diff", "HEAD"]);

    return {
      cwd,
      mergeBase,
      rawRecords,
      changedFiles: Array.from(changed).sort(),
      untrackedFiles: untrackedFiles.slice().sort(),
      branchDiffText: branchDiff.status === 0 ? String(branchDiff.stdout || "") : "",
      uncommittedDiffText: uncommittedDiff.status === 0 ? String(uncommittedDiff.stdout || "") : "",
    };
  } catch (_) {
    return null;
  }
}

// Declared "## Files to modify" paths from the session's detail plan.
function parseDetailFilesToModify(plansDir, wsid) {
  try {
    if (!plansDir || !wsid) return null;
    const detailPath = path.join(toWindowsPath(plansDir), `${wsid}-detail.md`);
    let text;
    try { text = fs.readFileSync(detailPath, "utf8"); } catch (_) { return null; }
    const paths = [];
    let inSection = false;
    for (const line of text.split(/\r?\n/)) {
      if (line.trim() === "## Files to modify") { inSection = true; continue; }
      if (inSection && /^## /.test(line)) break;
      if (inSection) {
        // Two declared-file spellings appear in real detail plans and fixtures:
        // backtick-wrapped `path` and a plain dash bullet `- path`. Prefer the
        // backtick form; fall back to a single-token dash/star bullet so a prose
        // bullet with spaces is never mistaken for a declared file.
        const bt = line.match(/`([^`]+)`/);
        if (bt) { paths.push(bt[1].replace(/\\/g, "/")); continue; }
        const bullet = line.match(/^\s*[-*]\s+(\S+)\s*$/);
        if (bullet) paths.push(bullet[1].replace(/\\/g, "/"));
      }
    }
    return paths;
  } catch (_) {
    return null;
  }
}

// Paths present in the working tree that no declared path covers.
function computeScopeDrift(changedFiles, declaredFiles) {
  if (!Array.isArray(changedFiles) || !Array.isArray(declaredFiles) || declaredFiles.length === 0) return null;
  return changedFiles.filter(
    (p) => !declaredFiles.some((d) => p === d || p.startsWith(d.endsWith("/") ? d : `${d}/`))
  );
}

module.exports = {
  toWindowsPath,
  computeWorkingTreeDiff,
  parseDetailFilesToModify,
  computeScopeDrift,
};
