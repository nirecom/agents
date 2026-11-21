"use strict";
// Role of a session for the PM duties (#3019), from PM state only — a peer-msg `role=pm` header is a
// self-claim and never an input. pm: the session's own active PM mark. workflow: an active PM owns one
// of the session's issues. The owner choice is #2941's resolveOwner on a local-only ctx; only an issue
// with no direct holder while an active PM exists spawns `bin/pm-state owner` inside a deadline slice,
// through ./owner-child.js so a timeout kills the whole tree (an orphaned gh would outlive the hook).
// #2942 swaps the local-only ctx and the spawn when ownership moves to the forge.

const cp = require("child_process");
const path = require("path");
const io = require("../../workflow-state/state-io");
const S = require("../../pm-session/schema");
const scan = require("../../pm-session/scan");
const { homeRepoOf, ORIGIN_TIMEOUT_MS } = require("../../pm-session/writer-common");
const { toWindowsPath } = require("../branch-diff");
const { resolveOwner } = require("../../../bin/lib/pm-state/owner");

const OWNER_CHILD = path.join(__dirname, "owner-child.js");
const SPAWN_CAP_MS = 1500;
const TREE_KILL_MARGIN_MS = 1000;

const LOCAL_ONLY = Object.freeze({ holdersOf: () => ({ ok: false, reason: "local-only" }) });

// spawnOwner(ref, deadline, reserveMs, cwd) -> {tag, session_id} | null (timeout, non-zero exit, no owner).
function spawnOwner(ref, deadline, reserveMs, cwd) {
  // The kill margin comes out of the slice too, so t + margin never passes the hook deadline.
  const t = deadline.sliceMs(SPAWN_CAP_MS, reserveMs + TREE_KILL_MARGIN_MS);
  if (t <= 0) return null;
  const r = cp.spawnSync(process.execPath, [OWNER_CHILD, S.refLabel(ref), String(t)], {
    cwd: toWindowsPath(cwd), encoding: "utf8", timeout: t + TREE_KILL_MARGIN_MS, stdio: ["ignore", "pipe", "pipe"], windowsHide: true,
  });
  if (r.error || r.status !== 0) return null;
  try {
    const o = JSON.parse(String(r.stdout).trim());
    return o && typeof o.tag === "string" && typeof o.session_id === "string" ? { tag: o.tag, session_id: o.session_id } : null;
  } catch (_) {
    return null;
  }
}

// homeRepoIn(cwd, deadline, reserveMs) -> the cwd origin's owner/repo, or null when the git read
// would not fit in what is left of the hook deadline.
function homeRepoIn(cwd, deadline, reserveMs) {
  if (deadline && deadline.remainingMs() - reserveMs < ORIGIN_TIMEOUT_MS) return null;
  return homeRepoOf({ cwd });
}

// resolveRole(sessionId, {issues, deadline, reserveMs, cwd}) -> {role:"pm", tag, issues} |
// {role:"workflow", owners:[{issue, tag, session_id}]} | {role:null}. A pm mark holds the role only
// in the current generation of its tag: the upstream of a hand-over keeps an active mark.
function resolveRole(sessionId, opts) {
  const o = opts || {};
  const reserveMs = o.reserveMs || 0;
  const own = io.readRawState(sessionId);
  if (S.hasPmMark(own) && !S.isActivePm(own)) return { role: null };
  const issues = Array.isArray(o.issues) ? o.issues : [];
  if (!S.isActivePm(own) && issues.length === 0) return { role: null };
  const entries = scan.listPmFiles();
  if (S.isActivePm(own)) {
    if (!scan.isCurrentGeneration(sessionId, entries)) return { role: null };
    return { role: "pm", tag: own.pm.tag, issues: Array.isArray(own.pm.issues) ? own.pm.issues : [] };
  }
  const cwd = typeof o.cwd === "string" && o.cwd ? o.cwd : process.cwd();
  const ctx = { scan, entries, homeRepo: homeRepoIn(cwd, o.deadline, reserveMs), resolve: () => null, ancestry: LOCAL_ONLY };
  const owners = [];
  for (const issue of issues) {
    const r = resolveOwner(issue, ctx);
    let owner = r.ok ? r.owner : null;
    if (!r.ok && r.reason === "local-only" && o.deadline) owner = spawnOwner(issue, o.deadline, reserveMs, cwd);
    if (owner) owners.push({ issue, tag: owner.tag, session_id: owner.session_id });
  }
  return owners.length > 0 ? { role: "workflow", owners } : { role: null };
}

module.exports = { resolveRole, SPAWN_CAP_MS };
