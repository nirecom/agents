"use strict";
// hooks/lib/jev/two-stage/snapshot.js — the query-time snapshot of the jev-judge CLI (#2460).
// Each stage source artifact is copied whole into jev-sources/<ticket>/ (the subagent reads
// only these copies), then packed into one redacted text: a header stating what survived the
// budget, the required sections first, then the optional ones, then the copy names. Jev is
// sent exactly the snapshot file's bytes.

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { StringDecoder } = require("string_decoder");

const { sha256, sourcesDir } = require("./paths");
const { artifactSha } = require("./source-fresh");
const {
  SCRIPT_CHECKOUT_ROOT, MAX_STATE_CHARS, MAX_ARTIFACT_READ_BYTES, STAGE_SOURCE_SECTIONS,
  SECTION_ORDER, artifactPathsFor, readCappedBytes, issueBodyOf, sliceUnits, redactOutbound,
} = require(path.join(__dirname, "..", "..", "..", "..", "bin", "workflow", "lib", "jev-request-common.js"));

const DET_PATH = path.join(__dirname, "..", "..", "..", "workflow-state", "complexity-routing", "deterministic-signals.js");
// The longest section state word: the header is sized with it before the body is packed.
const WIDEST_STATE = "truncated";

function plansDir() {
  return require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "workflow-plans-dir.js")).getWorkflowPlansDir();
}

function snapshotPath(sid, tid) {
  return path.join(plansDir(), `${sid}-jev-${tid}-snapshot.md`);
}

// The fixed answer file of a ticket: finalize reads only this name, never a caller-given path.
function answerPath(sid, tid) {
  return path.join(plansDir(), `${sid}-jev-${tid}-answer.txt`);
}

// The write-code list is shown as the parser sees it (status and normalized paths), never
// computed from a capped prefix.
function writeCodeListText(read, repoRoot) {
  if (read.over_cap) return "status: over-cap";
  const { parseWriteCodeFiles } = require(DET_PATH);
  const list = parseWriteCodeFiles(read.bytes, repoRoot || null);
  return [`status: ${list.status}`].concat(list.paths).join("\n");
}

function sectionText(section, read, repoRoot) {
  if (section === "write-code files") return redactOutbound(writeCodeListText(read, repoRoot));
  const raw = read.over_cap ? new StringDecoder("utf8").write(read.bytes) : read.bytes.toString("utf8");
  const text = raw.replace(/\r\n/g, "\n");
  const body = section === "issue body" ? issueBodyOf(text, read.over_cap) : text;
  if (body === null || body.trim() === "") return null;
  return redactOutbound(body);
}

// Copy one artifact whole; the copy is verified against the bytes read. Returns the failure
// reason (over-cap | copy-failed) or null with copy filled in.
function copyArtifact(art, read, dir, opts, copies) {
  if (read.over_cap) return "over-cap";
  if (Array.isArray(opts.failCopyFor) && opts.failCopyFor.includes(art.section)) return "copy-failed";
  const dst = path.join(dir, art.copy);
  try {
    fs.writeFileSync(dst, read.bytes);
    const sha = sha256(read.bytes);
    if (sha256(fs.readFileSync(dst)) !== sha) throw new Error("copy differs");
    copies[art.section] = { path: dst, sha256: sha };
    return null;
  } catch (_e) {
    try { fs.unlinkSync(dst); } catch (_e2) { /* never written */ }
    return "copy-failed";
  }
}

function orderedSections(stage, required) {
  const all = STAGE_SOURCE_SECTIONS[stage] || [];
  const req = SECTION_ORDER.filter((s) => all.includes(s) && required.includes(s));
  return req.concat(SECTION_ORDER.filter((s) => all.includes(s) && !required.includes(s)));
}

// Packs the texts into the body budget; a section that does not fit whole is cut once and
// every later section is absent.
function packBody(order, texts, overCap, budget) {
  const states = {};
  let body = "";
  let cut = false;
  for (const s of order) {
    if (cut || texts[s] === null || texts[s] === undefined) { states[s] = "absent"; continue; }
    const chunk = `## ${s}\n${texts[s]}\n\n`;
    const room = budget - body.length;
    if (chunk.length <= room) {
      body += chunk;
      states[s] = overCap.includes(s) ? "truncated" : "full";
    } else if (room > `## ${s}\n`.length) {
      body += sliceUnits(chunk, room).replace(/\n*$/, "\n\n");
      states[s] = "truncated";
      cut = true;
    } else {
      states[s] = "absent";
      cut = true;
    }
  }
  return { body, states };
}

// buildSnapshot(sid, stage, tid, required, opts) -> {file, text, sha256, sections, truncated,
// included, copies, sources, sources_sha256, sources_dir, artifacts_sha256, sources_failed,
// sources_failed_reasons}. artifacts_sha256 names every source artifact present at query time
// (null when it could not be hashed whole): the fingerprint a settle re-checks.
function buildSnapshot(sid, stage, tid, required, opts = {}) {
  const cap = Number.isSafeInteger(opts.maxArtifactBytes) && opts.maxArtifactBytes > 0
    ? opts.maxArtifactBytes : MAX_ARTIFACT_READ_BYTES;
  const dir = sourcesDir(sid, tid, true);
  fs.mkdirSync(dir, { recursive: true });
  const texts = {};
  const copies = {};
  const failed = [];
  const reasons = {};
  const overCap = [];
  const artifactsSha = {};
  for (const art of artifactPathsFor(sid, stage)) {
    let read;
    try { read = readCappedBytes(art.file, cap); } catch (_e) { artifactsSha[art.section] = null; continue; }
    artifactsSha[art.section] = artifactSha(read);
    texts[art.section] = sectionText(art.section, read, opts.repoRoot);
    if (read.over_cap) overCap.push(art.section);
    const reason = copyArtifact(art, read, dir, opts, copies);
    if (reason) { failed.push(art.section); reasons[art.section] = reason; }
  }
  if (typeof opts.afterCopy === "function") opts.afterCopy();
  const order = orderedSections(stage, required);
  const copied = SECTION_ORDER.filter((s) => copies[s]);
  // The snapshot leaves the machine: a copy is named by its file name only, and the caller
  // learns the directory from query's SOURCES_DIR line.
  const headerOf = (stateOf) => [`stage: ${stage}`]
    .concat(order.map((s) => `${s}: ${stateOf(s)}`))
    .concat(["sources:"], copied.map((s) => path.basename(copies[s].path)))
    .concat([`sources_unavailable: ${failed.length ? failed.join(",") : "-"}`]).join("\n");
  const artifacts = `## artifacts\n${copied.map((s) => `- ${path.basename(copies[s].path)}`).join("\n")}\n`;
  const fixed = headerOf(() => WIDEST_STATE).length + 2 + artifacts.length;
  const { body, states } = packBody(order, texts, overCap, MAX_STATE_CHARS - fixed);
  const text = `${headerOf((s) => states[s])}\n\n${body}${artifacts}`;
  const file = snapshotPath(sid, tid);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text);
  const sourcesSha = {};
  for (const s of copied) sourcesSha[s] = copies[s].sha256;
  return {
    file, text, sha256: crypto.createHash("sha256").update(text).digest("hex"),
    sections: states, truncated: order.some((s) => states[s] === "truncated"),
    included: order.filter((s) => states[s] !== "absent"), copies,
    sources: copied.map((s) => copies[s].path), sources_sha256: sourcesSha, sources_dir: dir,
    artifacts_sha256: artifactsSha, sources_failed: failed, sources_failed_reasons: reasons,
  };
}

module.exports = { snapshotPath, answerPath, buildSnapshot };
