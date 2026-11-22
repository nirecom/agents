"use strict";
// Role of a session for the PM duties (#3019, #2942), from PM state and the forge PM field only — a
// peer-msg `role=pm` header is a self-claim and never an input. pm: the session's own active PM mark.
// workflow: an active PM owns one of the session's issues. Ownership lives in the Projects v2 PM field
// (#2942), so every issue's owner comes from one `bin/pm-state owner --issue … --timeout-ms <slice>`, spawned through
// ./owner-child.js inside a deadline slice so a timeout kills the whole tree (an orphaned gh would
// outlive the hook). A lookup that fails omits the injection and carries a one-line reason (fail-open).

const cp = require("child_process");
const path = require("path");
const io = require("../../workflow-state/state-io");
const S = require("../../pm-session/schema");
const scan = require("../../pm-session/scan");
const { toWindowsPath } = require("../branch-diff");

const OWNER_CHILD = path.join(__dirname, "owner-child.js");
// One batched spawn for every issue: 3000 + the 1000 kill margin must fit the 5000 ms PostCompact deadline.
const SPAWN_CAP_MS = 3000;
const TREE_KILL_MARGIN_MS = 1000;

// ownerOf(o) -> {tag, session_id} | null | undefined (undefined: not an owner answer).
function ownerOf(o) {
  if (o && typeof o.tag === "string" && typeof o.session_id === "string") return { tag: o.tag, session_id: o.session_id };
  if (o && o.pm === null) return null;
  return undefined;
}

// parseOwners(stdout, n) -> [{tag, session_id}|null] in input order, or null when the answer is malformed.
function parseOwners(stdout, n) {
  let o;
  try { o = JSON.parse(String(stdout).trim()); } catch (_) { return null; }
  if (n === 1) {
    const one = ownerOf(o);
    return one === undefined ? null : [one];
  }
  if (!o || !Array.isArray(o.owners) || o.owners.length !== n) return null;
  const list = o.owners.map(ownerOf);
  return list.includes(undefined) ? null : list;
}

// spawnOwners(refs, deadline, reserveMs, cwd) -> {ok:true, owners:[{tag, session_id}|null]} | {ok:false, reason}.
function spawnOwners(refs, deadline, reserveMs, cwd) {
  if (!deadline) return { ok: false, reason: "no-deadline" };
  // The kill margin comes out of the slice too, so t + margin never passes the hook deadline.
  // A slice below the cap is fractional (remaining time minus reserve); spawnSync takes an integer timeout only.
  const t = Math.floor(deadline.sliceMs(SPAWN_CAP_MS, reserveMs + TREE_KILL_MARGIN_MS));
  if (t <= 0) return { ok: false, reason: "deadline-exhausted" };
  let r;
  try {
    r = cp.spawnSync(process.execPath, [OWNER_CHILD, ...refs.map(S.refLabel), String(t)], {
      cwd: toWindowsPath(cwd), encoding: "utf8", timeout: t + TREE_KILL_MARGIN_MS, stdio: ["ignore", "pipe", "pipe"], windowsHide: true,
    });
  } catch (_) { return { ok: false, reason: "spawn-failed" }; }
  if (r.error) return { ok: false, reason: r.error.code === "ETIMEDOUT" ? "timeout" : "spawn-failed" };
  if (r.status === 124) return { ok: false, reason: "timeout" };
  if (r.status !== 0) return { ok: false, reason: `exit ${r.status}` };
  const owners = parseOwners(r.stdout, refs.length);
  return owners ? { ok: true, owners } : { ok: false, reason: "parse-failed" };
}

// resolveRole(sessionId, {issues, deadline, reserveMs, cwd}) -> {role:"pm", tag, issues} |
// {role:"workflow", owners:[{issue, tag, session_id}]} | {role:null, reason?}. A pm mark holds the role
// only in the current generation of its tag: the upstream of a hand-over keeps an active mark. reason is
// set only when the one batched owner lookup failed (one undecidable issue fails the whole batch).
function resolveRole(sessionId, opts) {
  const o = opts || {};
  const reserveMs = o.reserveMs || 0;
  const own = io.readRawState(sessionId);
  if (S.hasPmMark(own) && !S.isActivePm(own)) return { role: null };
  const issues = Array.isArray(o.issues) ? o.issues : [];
  if (!S.isActivePm(own) && issues.length === 0) return { role: null };
  if (S.isActivePm(own)) {
    if (!scan.isCurrentGeneration(sessionId, scan.listPmFiles())) return { role: null };
    return { role: "pm", tag: own.pm.tag, issues: Array.isArray(own.pm.issues) ? own.pm.issues : [] };
  }
  const cwd = typeof o.cwd === "string" && o.cwd ? o.cwd : process.cwd();
  const r = spawnOwners(issues, o.deadline, reserveMs, cwd);
  if (!r.ok) return { role: null, reason: `owner lookup failed (${issues.map(S.refLabel).join(", ")} ${r.reason})` };
  const owners = [];
  r.owners.forEach((w, i) => { if (w) owners.push({ issue: issues[i], tag: w.tag, session_id: w.session_id }); });
  return owners.length > 0 ? { role: "workflow", owners } : { role: null };
}

module.exports = { resolveRole, SPAWN_CAP_MS };
