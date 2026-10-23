"use strict";
// Edit-time file-size check of hooks/block-post-edit-size.js (#2631). Every Write/Edit/MultiEdit
// target is classified (plan artifact, progress, or repo code/prompt/docs) and judged with the
// size-limits predicate: over HARD blocks unless the edit shrinks it, over WARN advises. Runs only
// for a started, non-WORKFLOW_OFF session (size-session-gate). Fails open on anything unexpected.

const path = require("path");
const { LIMITS, measure, judge, newlineDelta, codePointDelta } = require("../lib/size-limits");
const { classifyPlansPath, classifyRepoPath } = require("../lib/size-classify");
const { resolveTargetPath, readPre, applyEdits, groupEditTargets } = require("../lib/post-edit-content");
const { resolveRepoCwd } = require("../lib/path-normalize");
const { parseExtensions } = require("../lib/comment-block-scan");

const RULE_DOC = "rules/coding/file-split.md";
const TOOLS = ["Write", "Edit", "MultiEdit"];
const PATTERN = { code: "A", prompt: "B", docs: "C", intent: "D", outline: "D", detail: "D", progress: "E" };
const NONE = Object.freeze({});

function classify(absPath, input, exts) {
  const plan = classifyPlansPath(absPath);
  if (plan) return plan;
  const rel = path.relative(resolveRepoCwd({ input }), absPath);
  if (!rel || rel === ".." || rel.startsWith(".." + path.sep) || path.isAbsolute(rel)) return null;
  return classifyRepoPath(rel, exts);
}

function sessionActive(input) {
  const { resolveSessionId } = require("../workflow-state/session-id");
  const { sizeCheckActive } = require("../lib/size-session-gate");
  const sid = resolveSessionId({ sessionIdFromInput: input.session_id, transcriptPath: input.transcript_path });
  return sizeCheckActive(sid);
}

// judgeTarget -> a judge() verdict, { verdict: "unreadable" }, or null (approve).
function judgeTarget(t) {
  const preText = readPre(t.absPath);
  if (t.group.kind === "Write") {
    if (typeof t.group.content !== "string") return null;
    const pre = preText === null ? null : measure(t.kind, preText);
    return judge(t.kind, pre, measure(t.kind, t.group.content));
  }
  if (preText !== null) {
    const post = applyEdits(preText, t.group.edits);
    return post === null ? null : judge(t.kind, measure(t.kind, preText), measure(t.kind, post));
  }
  // Unread file: only a certain shrink passes. Dropping a final "\n" lowers the newline count by one
  // without lowering the line count, so a newline delta of -1 is not proof.
  const chars = LIMITS[t.kind].unit === "chars";
  const delta = chars ? codePointDelta(t.group.edits) : newlineDelta(t.group.edits);
  return delta < (chars ? 0 : -1) ? null : { verdict: "unreadable", kind: t.kind, hard: LIMITS[t.kind].hard, unit: LIMITS[t.kind].unit };
}

// Loaded only for a progress target: progress-file pulls in more than the per-Edit path needs.
function currentStateSection() {
  return require("../lib/progress-file").CURRENT_STATE_SECTION;
}

function label(t) {
  const base = path.basename(t.absPath);
  return t.kind === "progress" ? `${base} "${currentStateSection()}"` : base;
}

function remedy(kind) {
  const see = `see ${RULE_DOC} (Pattern ${PATTERN[kind]})`;
  if (kind === "progress") {
    return `Per rules/progress-update.md, rewrite "${currentStateSection()}" as a few lines of now and next — ${see}.`;
  }
  if (PATTERN[kind] === "D") return `Return the plan to its planner for a compressed revision — ${see}.`;
  return `Split or trim the file; an edit that shrinks it still passes — ${see}.`;
}

function blockText(t, v) {
  const head = v.verdict === "unreadable"
    ? `File size: ${label(t)} is too large to read before the edit, and the edit does not shrink it; ` +
      `it may be over the HARD limit of ${v.hard} ${v.unit} (${v.kind}).`
    : `File size: ${label(t)} would be ${v.value} ${v.unit}, over the HARD limit of ${v.hard} (${v.kind}; was ${v.pre}).`;
  return `${head} ${remedy(t.kind)}`;
}

function adviceText(t, v) {
  if (v.verdict === "shrink") {
    return `File size: ${label(t)} shrinks to ${v.value} ${v.unit} but stays over the HARD limit of ${v.hard} (${v.kind}). ${remedy(t.kind)}`;
  }
  return `File size: ${label(t)} is ${v.value} ${v.unit}, over WARN ${v.warn} (HARD ${v.hard}, ${v.kind}). ${remedy(t.kind)}`;
}

// check(input, env) -> { blocks: [reason...], advice: [text...] } | {}
function check(input, env) {
  if (TOOLS.indexOf(input.tool_name) === -1) return NONE;
  const exts = parseExtensions(env.CODE_FILE_EXTENSIONS);
  const targets = [];
  for (const group of groupEditTargets(input.tool_name, input.tool_input, input)) {
    const absPath = resolveTargetPath(input, group.rawPath);
    const kind = absPath ? classify(absPath, input, exts) : null;
    if (kind) targets.push({ group, absPath, kind });
  }
  if (targets.length === 0 || !sessionActive(input)) return NONE;

  const blocks = [];
  const advice = [];
  for (const t of targets) {
    let v = null;
    try { v = judgeTarget(t); } catch (_) { v = null; }
    if (!v) continue;
    if (v.verdict === "hard" || v.verdict === "unreadable") blocks.push(blockText(t, v));
    else if (v.verdict === "warn" || v.verdict === "shrink") advice.push(adviceText(t, v));
  }
  return { blocks, advice };
}

module.exports = { check };
