"use strict";
// hooks/lib/jev/two-stage/jev-input.js — the query-time Jev input of the jev-judge CLI (#2460).
// Each stage source artifact is copied whole into jev-sources/<ticket>/ (the subagent reads
// only these copies), then packed into one redacted text: a header stating what survived the
// budget, the required sections first, then the plan sections in priority order, then the
// rest, then the copy names. Jev is sent exactly the Jev input file's bytes.

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { StringDecoder } = require("string_decoder");

const { sha256, sourcesDir } = require("./paths");
const { artifactSha } = require("./source-fresh");
const {
  SCRIPT_CHECKOUT_ROOT, MAX_ARTIFACT_READ_BYTES, STAGE_SOURCE_SECTIONS,
  SECTION_ORDER, artifactPathsFor, readCappedBytes, issueBodyOf, sliceUnits, redactOutbound,
} = require(path.join(__dirname, "..", "..", "..", "..", "bin", "workflow", "lib", "jev-request-common.js"));

const DET_PATH = path.join(__dirname, "..", "..", "..", "workflow-state", "complexity-routing", "deterministic-signals.js");
// Jev's state holds 32,000 tokens; at a safe-side 1.0 token/char that is about 32,000 chars,
// less about 6% margin (the observed maximum is 0.81 token/char).
const MAX_JEV_INPUT_CHARS = 30000;
// The longest section state word: the header is sized with it before the body is packed.
const WIDEST_STATE = "truncated";
const WRITE_CODE_LIST = "write-code files";
// A detail plan's step blocks: moved to the end, so a cut detail keeps its other sections.
const STEP_HEADINGS = Object.freeze(["## Steps", "## \\u5b9f\\u88c5\\u30b9\\u30c6\\u30c3\\u30d7"]);

function plansDir() {
  return require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "workflow-plans-dir.js")).getWorkflowPlansDir();
}

function jevInputPath(sid, tid) {
  return path.join(plansDir(), `${sid}-jev-${tid}-input.md`);
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
  if (section === WRITE_CODE_LIST) return redactOutbound(writeCodeListText(read, repoRoot));
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

// {lead, plan, rest}: the required sections and the write-code list, the plan sections in
// priority order, then every other stage source section (each group in SECTION_ORDER).
function sectionGroups(stage, required, planSections) {
  const all = STAGE_SOURCE_SECTIONS[stage] || [];
  const req = SECTION_ORDER.filter((s) => all.includes(s) && required.includes(s));
  const plan = planSections.filter((s) => all.includes(s) && !required.includes(s));
  const lead = plan.length && all.includes(WRITE_CODE_LIST) && !req.includes(WRITE_CODE_LIST)
    ? req.concat([WRITE_CODE_LIST]) : req;
  const rest = SECTION_ORDER.filter((s) => all.includes(s) && !lead.includes(s) && !plan.includes(s));
  return { lead, plan, rest };
}

const chunkOf = (s, text) => `## ${s}\n${text}\n\n`;

// The chunk cut to at most room chars, or null when not even its heading fits.
function cutChunk(s, chunk, room) {
  return room > `## ${s}\n`.length ? sliceUnits(chunk, room).replace(/\n*$/, "\n\n") : null;
}

// Packs sections in order into the room; a section that does not fit whole is cut once and
// every later section is absent. Returns {parts, used, cut}.
function packSequential(order, texts, overCap, room, states, cutAlready) {
  const parts = {};
  let used = 0;
  let cut = cutAlready;
  for (const s of order) {
    if (cut || texts[s] === null || texts[s] === undefined) { states[s] = "absent"; continue; }
    const chunk = chunkOf(s, texts[s]);
    if (chunk.length <= room - used) {
      parts[s] = chunk;
      states[s] = overCap.includes(s) ? "truncated" : "full";
    } else {
      const part = cutChunk(s, chunk, room - used);
      if (part !== null) parts[s] = part;
      states[s] = part !== null ? "truncated" : "absent";
      cut = true;
    }
    if (parts[s]) used += parts[s].length;
  }
  return { parts, used, cut };
}

// The text with its step blocks (a STEP_HEADINGS line up to the next "## " line) moved to the end.
function stepsLast(text) {
  const head = [];
  const steps = [];
  let inSteps = false;
  for (const line of text.split("\n")) {
    if (line.startsWith("## ")) inSteps = STEP_HEADINGS.includes(line.trimEnd());
    (inSteps ? steps : head).push(line);
  }
  return head.concat(steps).join("\n");
}

// The plan sections: the first whole when it fits, the others after it in the room left.
// Otherwise the second is reserved first (whole when it takes at most half the room, else cut
// to half), the first fills what remains with its step blocks moved last, and the others follow.
function packPlan(plan, texts, overCap, room, states) {
  const [first, second, ...others] = plan;
  const present = (s) => s !== undefined && texts[s] !== null && texts[s] !== undefined;
  if (!present(first) || chunkOf(first, texts[first]).length <= room) {
    return packSequential(plan, texts, overCap, room, states, false);
  }
  const parts = {};
  let used = 0;
  if (present(second)) {
    const chunk = chunkOf(second, texts[second]);
    const half = Math.floor(room / 2);
    const part = chunk.length <= half ? chunk : cutChunk(second, chunk, half);
    if (part !== null) parts[second] = part;
    if (part === null) states[second] = "absent";
    else states[second] = part === chunk && !overCap.includes(second) ? "full" : "truncated";
    used += part === null ? 0 : part.length;
  } else if (second !== undefined) {
    states[second] = "absent";
  }
  const firstPart = cutChunk(first, chunkOf(first, stepsLast(texts[first])), room - used);
  if (firstPart !== null) parts[first] = firstPart;
  states[first] = firstPart !== null ? "truncated" : "absent";
  used += firstPart === null ? 0 : firstPart.length;
  const tail = packSequential(others, texts, overCap, room - used, states, false);
  return { parts: Object.assign(parts, tail.parts), used: used + tail.used, cut: true };
}

// Packs the texts into the body budget, in header order: lead, plan, rest.
function packBody(groups, texts, overCap, budget) {
  const states = {};
  const lead = packSequential(groups.lead, texts, overCap, budget, states, false);
  const plan = lead.cut
    ? packSequential(groups.plan, texts, overCap, 0, states, true)
    : packPlan(groups.plan, texts, overCap, budget - lead.used, states);
  const rest = packSequential(groups.rest, texts, overCap, budget - lead.used - plan.used, states, lead.cut || plan.cut);
  const parts = Object.assign({}, lead.parts, plan.parts, rest.parts);
  const order = groups.lead.concat(groups.plan, groups.rest);
  return { body: order.map((s) => parts[s] || "").join(""), states };
}

// buildJevInput(sid, stage, tid, required, opts) -> {file, text, sha256, sections, truncated,
// included, copies, sources, sources_sha256, sources_dir, artifacts_sha256, sources_failed,
// sources_failed_reasons}. opts.planSections: the stage's plan sections in priority order.
// artifacts_sha256 names every source artifact present at query time (null when it could not
// be hashed whole): the fingerprint a settle re-checks.
function buildJevInput(sid, stage, tid, required, opts = {}) {
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
  const groups = sectionGroups(stage, required, Array.isArray(opts.planSections) ? opts.planSections : []);
  const order = groups.lead.concat(groups.plan, groups.rest);
  const copied = SECTION_ORDER.filter((s) => copies[s]);
  // The Jev input leaves the machine: a copy is named by its file name only, and the caller
  // learns the directory from query's SOURCES_DIR line.
  const headerOf = (stateOf) => [`stage: ${stage}`]
    .concat(order.map((s) => `${s}: ${stateOf(s)}`))
    .concat(["sources:"], copied.map((s) => path.basename(copies[s].path)))
    .concat([`sources_unavailable: ${failed.length ? failed.join(",") : "-"}`]).join("\n");
  const artifacts = `## artifacts\n${copied.map((s) => `- ${path.basename(copies[s].path)}`).join("\n")}\n`;
  const fixed = headerOf(() => WIDEST_STATE).length + 2 + artifacts.length;
  const { body, states } = packBody(groups, texts, overCap, MAX_JEV_INPUT_CHARS - fixed);
  const text = `${headerOf((s) => states[s])}\n\n${body}${artifacts}`;
  const file = jevInputPath(sid, tid);
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

module.exports = { MAX_JEV_INPUT_CHARS, jevInputPath, answerPath, buildJevInput };
