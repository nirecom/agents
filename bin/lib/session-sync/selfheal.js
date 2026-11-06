"use strict";
// Self-heal (#2658): a clone left mid-rebase or mid-merge (#2291) is put back on main without
// touching the working tree; unmerged paths are resolved by keeping both sides.

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const G = require("./git");
const { union } = require("./jsonl");
const { siblingName } = require("./conflict");
const { writeAtomic } = require("./apply");

const STATE_ENTRIES = ["rebase-merge", "rebase-apply", "MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "AUTO_MERGE",
  "CHERRY_PICK_HEAD", "REVERT_HEAD"];

function unmergedPaths(dir) {
  const out = G.gitOut(dir, ["ls-files", "-u", "-z"]);
  const set = new Set();
  for (const rec of (out || "").split("\0")) {
    const m = rec.match(/^\d+ [0-9a-f]+ \d\t([\s\S]+)$/);
    if (m) set.add(m[1]);
  }
  return [...set];
}

// heal(dir) -> {main, unmerged}; main is refs/heads/main after the repair (null when unborn).
function heal(dir) {
  const gd = path.join(dir, ".git");
  const unmerged = unmergedPaths(dir);
  for (const n of STATE_ENTRIES) fs.rmSync(path.join(gd, n), { recursive: true, force: true });
  let main = G.revParse(dir, G.MAIN);
  if (!main) {
    const legacy = G.revParse(dir, "refs/heads/master");
    if (legacy && G.casUpdate(dir, G.MAIN, legacy, null)) main = legacy;
  }
  G.git(dir, ["symbolic-ref", "HEAD", G.MAIN]);
  G.setIndex(dir, main);
  return { main, unmerged };
}

function blobText(dir, rev, rel) {
  const sha = rev ? G.gitOut(dir, ["rev-parse", "--verify", "-q", `${rev}:${rel}`]) : null;
  return sha ? G.catBlob(dir, sha) : null;
}

// resolveUnmerged(dir, paths, otherRev, stats) — a transcript becomes the marker-free union; any
// other file moves to a conflict sibling and the other side's version takes the path.
function resolveUnmerged(dir, paths, otherRev, stats) {
  const host = os.hostname().split(".")[0];
  for (const rel of paths) {
    const abs = path.join(dir, ...rel.split("/"));
    if (!fs.existsSync(abs)) continue;
    const other = blobText(dir, otherRev, rel);
    if (rel.endsWith(".jsonl")) {
      const u = union(fs.readFileSync(abs, "utf8"), other ? other.toString("utf8") : "");
      stats.droppedMarkerLines += u.droppedMarkerLines;
      if (!u.deferred) writeAtomic(abs, u.text);
      continue;
    }
    if (!other) continue;
    const copy = siblingName(rel, host, new Date(), (r) => fs.existsSync(path.join(dir, ...r.split("/"))));
    fs.renameSync(abs, path.join(dir, ...copy.split("/")));
    writeAtomic(abs, other);
    stats.conflicts.push({ path: rel, copy, localMtime: null, remoteTime: null });
  }
}

module.exports = { STATE_ENTRIES, heal, resolveUnmerged };
