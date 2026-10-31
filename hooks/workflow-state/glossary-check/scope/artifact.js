"use strict";
// Input 1 (artifact) of the glossary-check fingerprint (#2529 I-FP): rule R-A reads a plan
// artifact once and cuts its approval range; rule R-S reads the staged blobs of one stage.
// During a merge, R-S leaves out the merge-incoming files (#2761); mergeIncoming is diagnostic only.
// Each staged file carries changedLines (#2770): the scan reports only those lines; the digest
// stays over the staged blobs.

const fs = require("fs");
const crypto = require("crypto");
const { spawnSync } = require("child_process");
const { toWindowsPath } = require("../../../lib/branch-diff");
const { artifactRangeOfBuffer } = require("../../completion-approval");
const { rowFor } = require("../../plan-stage-table");
const { stagedOids } = require("../../../workflow-gate/staged-evidence");
const { detectMergeIncoming, MERGE_INCOMING_STATE } = require("../../../lib/merge-incoming");
const { changedLinesOf } = require("./changed-lines");

const sha256 = (data) => crypto.createHash("sha256").update(data).digest("hex");
const kindOf = (p) => (/\.md$/i.test(p) ? "markdown" : "code");

// range line i -> its 1-based line in the whole file. One cut: the common prefix, then the
// rest aligned from the end; a range that does not align that way falls back to a forward walk.
function lineMapOf(origText, rangeText) {
  const orig = origText.split("\n");
  const range = rangeText.split("\n");
  let suffix = 0;
  while (suffix < range.length && range[range.length - 1 - suffix] === orig[orig.length - 1 - suffix]) suffix++;
  const cut = range.length - suffix;
  const map = range.map((_, i) => (i < cut ? i + 1 : orig.length - (range.length - i) + 1));
  if (map.every((n, i) => orig[n - 1] === range[i])) return map;
  let j = 0;
  return range.map((line) => {
    while (j < orig.length && orig[j] !== line) j++;
    j++;
    return Math.min(j, orig.length);
  });
}

// readPlanRange(sid, step) -> { ok, buf, text, file } over one read of the plan artifact.
function readPlanRange(sid, step) {
  let file;
  let buf;
  try {
    // Owner-resolved like every plan reader (#2633): an adopted session reads its upstream's file.
    file = require("../../plan-artifact-owner").resolvePlanArtifactOwner(sid, rowFor(step).suffix).path;
    buf = fs.readFileSync(toWindowsPath(file));
  } catch (e) {
    return { ok: false, error: "artifact-unreadable", detail: e && e.code ? e.code : String(e && e.message) };
  }
  const range = artifactRangeOfBuffer(buf, step);
  const text = range.toString("utf8");
  return { ok: true, file, text, lineMap: lineMapOf(buf.toString("utf8"), text) };
}

function artifactRA(sid, step) {
  const r = readPlanRange(sid, step);
  if (!r.ok) return r;
  return {
    ok: true,
    artifact: {
      files: [{ path: r.file, kind: "markdown", text: r.text, lineMap: r.lineMap }],
      digest: sha256(Buffer.from(r.text, "utf8")),
      empty: false,
    },
    rangeText: r.text,
  };
}

function git(repoDir, args, input) {
  // No `encoding`: stdout stays a Buffer, and a string `input` would be encoded with it.
  const r = spawnSync("git", ["-C", toWindowsPath(repoDir)].concat(args), {
    input: input === undefined ? undefined : Buffer.from(input, "utf8"), timeout: 15000, maxBuffer: 256 * 1024 * 1024,
  });
  if (r.error || r.status !== 0) {
    throw new Error(`git ${args[0]} failed: ${r.error ? r.error.message : String(r.stderr || "").trim()}`);
  }
  return r.stdout;
}

// `git cat-file --batch` frames: "<oid> blob <size>\n<content>\n" per OID.
function readBlobs(repoDir, oids) {
  if (oids.length === 0) return new Map();
  const out = git(repoDir, ["cat-file", "--batch"], oids.join("\n") + "\n");
  const blobs = new Map();
  let at = 0;
  for (const oid of oids) {
    const nl = out.indexOf(0x0a, at);
    if (nl === -1) throw new Error("git cat-file: truncated output");
    const header = out.slice(at, nl).toString("utf8").split(" ");
    if (header[1] !== "blob") throw new Error(`git cat-file: ${oid} is ${header[1] || "unreadable"}`);
    const size = Number(header[2]);
    blobs.set(oid, out.slice(nl + 1, nl + 1 + size).toString("utf8"));
    at = nl + 1 + size + 1;
  }
  return blobs;
}

// artifactRS(repoDir, stage, classify) -> the staged paths classify() puts in `stage`.
function artifactRS(repoDir, stage, classify) {
  try {
    const names = git(repoDir, ["diff", "--cached", "--name-only", "-z", "--no-renames"]).toString("utf8");
    const listed = names.split("\0").filter(Boolean).filter((p) => classify(p) === stage).sort();
    let paths = listed;
    let mergeIncoming = { state: "skipped", excluded: 0 };
    if (listed.length > 0) {
      const r = detectMergeIncoming(repoDir, listed);
      if (r.state === MERGE_INCOMING_STATE.MERGING) paths = listed.filter((p) => !r.paths.has(p));
      mergeIncoming = { state: r.state, excluded: listed.length - paths.length };
      if (r.state === MERGE_INCOMING_STATE.UNDECIDABLE) mergeIncoming.reason = r.reason;
    }
    const oids = paths.length > 0 ? stagedOids(toWindowsPath(repoDir), paths) : {};
    const pairs = paths.map((p) => [p, oids[p] || "deleted"]);
    const present = pairs.filter(([, oid]) => oid !== "deleted");
    const blobs = readBlobs(repoDir, [...new Set(present.map(([, oid]) => oid))]);
    const changed = present.length > 0 ? changedLinesOf(git, repoDir) : new Map();
    // A staged deletion is listed with empty text: it is part of the artifact but has nothing to scan.
    const files = pairs.map(([p, oid]) => (oid === "deleted"
      ? { path: p, kind: kindOf(p), text: "", deleted: true }
      : { path: p, kind: kindOf(p), text: blobs.get(oid), changedLines: changed.get(p) || [] }));
    return { ok: true, artifact: { files, digest: sha256(JSON.stringify(pairs)), empty: paths.length === 0, mergeIncoming } };
  } catch (e) {
    return { ok: false, error: "git-failed", detail: e && e.message ? e.message : String(e) };
  }
}

module.exports = { sha256, lineMapOf, artifactRA, artifactRS, git };
