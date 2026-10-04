"use strict";
// Per-session segments and user-wait intervals, read from the workflow state file
// (<sid>.json events) when it exists and estimated from the transcript otherwise.
const fs = require("fs");
const path = require("path");
const readline = require("readline");
const { STEP_TO_SKILL } = require("../workflow/lib/next-step/steps");

const SKILL_TO_STEP = new Map();
for (const [step, skill] of Object.entries(STEP_TO_SKILL)) if (skill) SKILL_TO_STEP.set(skill, step);
// Workflow skills that start a phase but are not a step's primary skill.
const BOUNDARY_SKILLS = new Set([
  "wf-init", "survey-history", "review-plan-codex", "review-plan-security", "worktree-start",
  "review-code-codex", "commit-push", "worktree-end", "session-close", "issue-close-finalize",
]);
const NOT_HUMAN = /^\s*(<task-notification|<local-command|Stop hook|\[Request interrupted|Caveat:)/;
// Encoded project dirs: "-home-x-repo" (POSIX) or "c--src-repo" (Windows).
const TRANSCRIPT_DIR_RE = /^(-|[A-Za-z]--)/;
const SID_JSONL_RE = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/;
const SID_STATE_RE = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.json$/;

function listDir(dir) {
  try { return fs.readdirSync(dir); } catch (_) { return []; }
}

function findTranscripts(base) {
  const map = new Map();
  for (const proj of listDir(base)) {
    if (!TRANSCRIPT_DIR_RE.test(proj)) continue;
    for (const f of listDir(path.join(base, proj))) {
      const m = f.match(SID_JSONL_RE);
      if (m) map.set(m[1], path.join(base, proj, f));
    }
  }
  return map;
}

function findStateSids(stateDir) {
  return listDir(stateDir).map((f) => (f.match(SID_STATE_RE) || [])[1]).filter(Boolean);
}

function skillLabel(name) {
  const skill = String(name).replace(/^.*:/, "");
  if (SKILL_TO_STEP.has(skill)) return SKILL_TO_STEP.get(skill);
  return BOUNDARY_SKILLS.has(skill) ? skill : null;
}

// null when the record carries no human-typed text (tool results, non-text content).
function textOf(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return null;
  if (content.some((c) => c && c.type === "tool_result")) return null;
  const t = content.find((c) => c && c.type === "text");
  return t ? t.text : null;
}

async function scanTranscript(file) {
  const r = { title: "", first: null, last: null, skills: [], waits: [] };
  const askOpen = new Map();
  let prevTs = null;
  const rl = readline.createInterface({ input: fs.createReadStream(file, "utf8"), crlfDelay: Infinity });
  for await (const line of rl) {
    if (!line) continue;
    let rec;
    try { rec = JSON.parse(line); } catch (_) { continue; }
    if (rec.type === "custom-title" && rec.customTitle) { r.title = rec.customTitle; continue; }
    if (rec.isSidechain) continue;
    const ts = rec.timestamp ? Date.parse(rec.timestamp) : NaN;
    if (!Number.isFinite(ts)) continue;
    if (r.first === null || ts < r.first) r.first = ts;
    if (r.last === null || ts > r.last) r.last = ts;
    const content = rec.message && rec.message.content;
    if (rec.type === "assistant" && Array.isArray(content)) {
      for (const c of content) {
        if (!c || c.type !== "tool_use") continue;
        const label = c.name === "Skill" && c.input ? skillLabel(c.input.skill) : null;
        if (label) r.skills.push({ at: ts, label });
        if (c.name === "AskUserQuestion") askOpen.set(c.id, ts);
      }
    } else if (rec.type === "user") {
      for (const c of Array.isArray(content) ? content : []) {
        if (c && c.type === "tool_result" && askOpen.has(c.tool_use_id)) {
          r.waits.push([askOpen.get(c.tool_use_id), ts]);
          askOpen.delete(c.tool_use_id);
        }
      }
      const t = textOf(content);
      if (t !== null && !rec.isMeta && !rec.isCompactSummary && !NOT_HUMAN.test(t) && prevTs !== null && ts > prevTs) {
        r.waits.push([prevTs, ts]);
      }
    }
    // Queue / attachment / system records written just before a prompt must not move the wait start.
    if (rec.type === "assistant" || (rec.type === "user" && textOf(content) === null)) prevTs = ts;
  }
  r.waits = union(r.waits);
  return r;
}

// Steps settled in one batch share a timestamp; fold them into the preceding row.
function collapseInstant(segs) {
  const out = [];
  for (const g of segs) {
    const prev = out[out.length - 1];
    if (prev && g.e === g.s && g.s === prev.e) { prev.label += " + " + g.label; continue; }
    out.push(Object.assign({}, g));
  }
  return out;
}

function stateSegments(stateDir, sid) {
  let state;
  try { state = JSON.parse(fs.readFileSync(path.join(stateDir, sid + ".json"), "utf8")); } catch (_) { return null; }
  const ev = (Array.isArray(state.events) ? state.events : [])
    .filter((e) => e && (e.kind === "step_status" || e.kind === "reset") && e.provenance !== "backfilled" && e.at)
    .sort((a, b) => (a.seq || 0) - (b.seq || 0));
  if (ev.length === 0) return null;
  const segs = [];
  let start = Date.parse(ev[0].at);
  let lastAt = start;
  let open = null;
  let resetAt = null;
  for (const e of ev) {
    const at = Date.parse(e.at);
    lastAt = Math.max(lastAt, at);
    if (e.kind === "reset") {
      // A reset also marks every earlier step complete in the same batch; that batch is bookkeeping.
      segs.push({ label: (open || "?") + " -> reset(from " + e.from_step + ")", s: start, e: Math.max(at, start) });
      start = Math.max(at, start);
      resetAt = e.at;
      open = e.from_step;
      continue;
    }
    if (e.at === resetAt) continue;
    if (e.status === "in_progress") open = e.step;
    if (e.status !== "complete" && e.status !== "skipped") continue;
    segs.push({ label: e.step + (e.status === "skipped" ? " (skip)" : ""), s: start, e: Math.max(at, start) });
    start = Math.max(at, start);
  }
  if (lastAt > start) segs.push({ label: "(in progress: " + (open || "?") + ")", s: start, e: lastAt });
  return collapseInstant(segs);
}

function transcriptSegments(t) {
  if (t.skills.length === 0) return null;
  // Rewound / resumed branches append older timestamps later in the file.
  const skills = t.skills.slice().sort((a, b) => a.at - b.at);
  const segs = [];
  if (skills[0].at > t.first) segs.push({ label: "(before first skill)", s: t.first, e: skills[0].at });
  for (let i = 0; i < skills.length; i++) {
    const e = i + 1 < skills.length ? skills[i + 1].at : t.last;
    segs.push({ label: skills[i].label, s: skills[i].at, e });
  }
  return collapseInstant(segs);
}

// Prompt waits, AskUserQuestion waits and duplicated branches overlap; count each instant once.
function union(waits) {
  const merged = [];
  for (const [a, b] of waits.slice().sort((x, y) => x[0] - y[0])) {
    const last = merged[merged.length - 1];
    if (last && a <= last[1]) last[1] = Math.max(last[1], b);
    else merged.push([a, b]);
  }
  return merged;
}

function overlap(waits, s, e) {
  let sum = 0;
  for (const [a, b] of waits) sum += Math.max(0, Math.min(b, e) - Math.max(a, s));
  return sum;
}

const EMPTY_TRANSCRIPT = Object.freeze({ title: "", first: null, last: null, skills: [], waits: [] });

// One row per session that has at least one segment; the period filters on the first segment's start.
async function collectSessions({ transcriptBase, stateDir, sessionPrefix, from, to }) {
  const transcripts = findTranscripts(transcriptBase);
  const sids = new Set([...transcripts.keys(), ...findStateSids(stateDir)]);
  const rows = [];
  for (const sid of sids) {
    if (sessionPrefix && !sid.startsWith(sessionPrefix)) continue;
    const t = transcripts.has(sid) ? await scanTranscript(transcripts.get(sid)) : EMPTY_TRANSCRIPT;
    let segs = stateSegments(stateDir, sid);
    let source = "state";
    if (!segs) { segs = transcriptSegments(t); source = "transcript"; }
    if (!segs || segs.length === 0) continue;
    const start = segs[0].s;
    if (start < from || start >= to) continue;
    for (const g of segs) g.w = overlap(t.waits, g.s, g.e);
    const gross = segs.reduce((a, g) => a + (g.e - g.s), 0);
    const wait = segs.reduce((a, g) => a + g.w, 0);
    // Whole-session wall clock; without a transcript it falls back to the workflow span.
    const wall = t.first !== null ? t.last - t.first : gross;
    rows.push({ sid, title: t.title, source, segs, gross, wait, wall, start });
  }
  return rows.sort((a, b) => a.start - b.start);
}

module.exports = { collectSessions, findTranscripts, scanTranscript, stateSegments, transcriptSegments, union, overlap };
