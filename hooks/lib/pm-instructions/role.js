"use strict";
// Role of a session for the PM duties (#3019, #2942), from PM state and the forge PM field only — a
// peer-msg `role=pm` header is a self-claim and never an input. pm: the session's own active PM mark.
// workflow: an active PM owns one of the session's issues. Ownership lives in the Projects v2 PM field
// (#2942), so each issue's owner is `bin/pm-state owner --timeout-ms <slice>`, spawned through
// ./owner-child.js inside a deadline slice so a timeout kills the whole tree (an orphaned gh would
// outlive the hook). A lookup that fails omits the injection and carries a one-line reason (fail-open).

const cp = require("child_process");
const path = require("path");
const io = require("../../workflow-state/state-io");
const S = require("../../pm-session/schema");
const scan = require("../../pm-session/scan");
const { toWindowsPath } = require("../branch-diff");

const OWNER_CHILD = path.join(__dirname, "owner-child.js");
const SPAWN_CAP_MS = 1500;
const TREE_KILL_MARGIN_MS = 1000;

// spawnOwner(ref, deadline, reserveMs, cwd) -> {ok:true, owner:{tag, session_id}|null} | {ok:false, reason}.
function spawnOwner(ref, deadline, reserveMs, cwd) {
  if (!deadline) return { ok: false, reason: "no-deadline" };
  // The kill margin comes out of the slice too, so t + margin never passes the hook deadline.
  const t = deadline.sliceMs(SPAWN_CAP_MS, reserveMs + TREE_KILL_MARGIN_MS);
  if (t <= 0) return { ok: false, reason: "deadline-exhausted" };
  const r = cp.spawnSync(process.execPath, [OWNER_CHILD, S.refLabel(ref), String(t)], {
    cwd: toWindowsPath(cwd), encoding: "utf8", timeout: t + TREE_KILL_MARGIN_MS, stdio: ["ignore", "pipe", "pipe"], windowsHide: true,
  });
  if (r.error) return { ok: false, reason: r.error.code === "ETIMEDOUT" ? "timeout" : "spawn-failed" };
  if (r.status === 124) return { ok: false, reason: "timeout" };
  if (r.status !== 0) return { ok: false, reason: `exit ${r.status}` };
  try {
    const o = JSON.parse(String(r.stdout).trim());
    if (o && typeof o.tag === "string" && typeof o.session_id === "string") return { ok: true, owner: { tag: o.tag, session_id: o.session_id } };
    if (o && o.pm === null) return { ok: true, owner: null };
  } catch (_) { /* falls through to parse-failed */ }
  return { ok: false, reason: "parse-failed" };
}

// resolveRole(sessionId, {issues, deadline, reserveMs, cwd}) -> {role:"pm", tag, issues} |
// {role:"workflow", owners:[{issue, tag, session_id}]} | {role:null, reason?}. A pm mark holds the role
// only in the current generation of its tag: the upstream of a hand-over keeps an active mark. reason is
// set only when an owner lookup failed and no owner was found.
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
  const owners = [];
  const failures = [];
  for (const issue of issues) {
    const r = spawnOwner(issue, o.deadline, reserveMs, cwd);
    if (!r.ok) failures.push(`${S.refLabel(issue)} ${r.reason}`);
    else if (r.owner) owners.push({ issue, tag: r.owner.tag, session_id: r.owner.session_id });
  }
  if (owners.length > 0) return { role: "workflow", owners };
  return failures.length > 0 ? { role: null, reason: `owner lookup failed (${failures.join(", ")})` } : { role: null };
}

module.exports = { resolveRole, SPAWN_CAP_MS };
