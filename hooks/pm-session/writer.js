"use strict";
// The only writer of the `pm` state key (#2941), run by the UserPromptSubmit issue-title hook
// before naming. A typed /pm-init, /pm-add, /pm-remove or /resume-session --from is applied here;
// a typed /wf-init in a PM session is refused. runPmWriter(input, deps) -> {block?, context?, notice?}:
// block is the refusal shown to the user, context the `[pm-session]` note for the model, notice the
// one sentence for the user. init/add check the other PMs' range (overlap.findOverlap) outside the lock.

const path = require("path");
const { typedSlashCommand } = require("../lib/typed-slash-command");
const { parsePmInitArgs, parsePmAssignArgs } = require("../lib/session-name");
const io = require("../workflow-state/state-io");
const S = require("./schema");
const scan = require("./scan");
const C = require("./writer-common");
const { inherit } = require("./inherit");

const NAMES = Object.freeze(["pm-init", "pm-add", "pm-remove", "resume-session", "wf-init", "workflow-init"]);
const { WRITER_FORGE_BUDGET_MS, refuse, labels } = C;

function assertWritableGeneration(sid, pm, entries) {
  if (scan.isCurrentGeneration(sid, entries)) return;
  const cur = scan.currentOf(pm.tag, entries);
  refuse(`this session is an old generation of ${pm.tag}; the current one is session ${cur ? cur.session_id : "(unknown)"}. Make the change there.`);
}

// assertNoDirectHolder(refs, ownTag, entries, home) — the cheap check: another active PM lists the issue.
function assertNoDirectHolder(refs, ownTag, entries, home) {
  for (const ref of refs) {
    const h = scan.directHoldersOf(ref, { entries, homeRepo: home }).find((x) => !S.sameTag(x.tag, ownTag));
    if (h) refuse(`${S.refLabel(ref)} is already assigned to ${h.tag} (session ${h.session_id}). Remove it there with /pm-remove first.`);
  }
}

// assertNoOverlap(adds, ownTag, entries, home, deps) — the forge check against every other active PM's
// range; skipped (no forge call) when nothing is added or no other PM is active.
function assertNoOverlap(adds, ownTag, entries, home, deps) {
  const others = scan.listActivePms(entries).filter((p) => !S.sameTag(p.tag, ownTag))
    .map((p) => ({ tag: p.tag, session_id: p.session_id, issues: p.issues.map((i) => C.resolved(i, home)) }));
  if (adds.length === 0 || others.length === 0) return;
  const { findOverlap, refusalText } = require(path.join(__dirname, "..", "..", "bin", "lib", "pm-state", "overlap"));
  const r = findOverlap(adds.map((a) => C.resolved(a, home)), ownTag, others, C.ancestryOf(deps));
  if (!r.ok) refuse(refusalText(r));
}

function dedupe(refs, home) {
  const out = [];
  for (const r of refs) if (!out.some((x) => S.sameIssue(x, r, home))) out.push(r);
  return out;
}

const reasonWord = (given) => (given ? "given" : "unstated");

// result(op, pm, refs, given) -> {context, notice}: both carry the refs and reason=<given|unstated>.
function result(op, pm, refs, given) {
  const line = `refs=${labels(refs)} reason=${reasonWord(given)}`;
  const ask = given ? [] : ["The reason is unstated: run `bin/pm-state set-reason --text \"<reason>\"` once only when the user's last message states it plainly; never guess."];
  const notice = `[pm-session] /pm-${op} ${pm.tag}: ${labels(refs)} (reason=${reasonWord(given)})`;
  return { context: C.note(op, pm, [line].concat(ask)), notice };
}

function init(sid, args, now, input, deps) {
  const { tag, refs, objective } = parsePmInitArgs(args);
  if (!S.isValidPmTag(tag)) refuse("usage: /pm-init <tag> [#A …] [theme]; the tag is 1 to 40 characters of letters, digits and - only");
  if (S.hasPmMark(C.rawOf(sid))) refuse("this session already has a PM; one session holds one PM.");
  if (C.workflowBegun(sid)) refuse("this session has started a workflow; start the PM in a new session.");
  const entries = scan.listPmFiles();
  if (scan.tagInUse(tag, entries)) refuse(`the tag ${tag} is already used (tags are never reused, archived PMs included); choose another.`);
  const home = C.homeRepoOf(input, deps);
  const issues = dedupe(refs.map((r) => C.resolved(r, home)), home);
  assertNoDirectHolder(issues, tag, entries, home);
  assertNoOverlap(issues, tag, entries, home, deps);
  const pm = {
    tag, issues, objective: objective || null, current_since: now, upstream_session_id: null,
    assignment_log: [{ at: now, op: "init", issues, reason: objective || S.REASON_UNSTATED }],
    sequence: { updated_at: null, tables: [], unverified: null }, archived_at: null,
  };
  io.updateTopLevel(sid, (rec) => { if (S.hasPmMark(rec)) refuse("this session already has a PM."); rec.pm = pm; });
  return result("init", pm, issues, Boolean(objective));
}

function assign(op, sid, args, now, input, deps) {
  const own = C.rawOf(sid);
  if (!S.hasPmMark(own)) refuse(`/pm-${op} needs a PM session; start one with /pm-init.`);
  if (!S.isActivePm(own)) refuse(`the PM ${own.pm.tag} has ended; an ended PM takes no change.`);
  const parsed = parsePmAssignArgs(args);
  const home = C.homeRepoOf(input, deps);
  const same = (a, b) => S.sameIssue(a, b, home);
  const refs = dedupe(parsed.refs.map((r) => C.resolved(r, home)), home);
  if (refs.length === 0) refuse(`usage: /pm-${op} #A [#B …] [reason]`);
  const entries = scan.listPmFiles();
  assertWritableGeneration(sid, own.pm, entries);
  if (op === "add") {
    assertNoDirectHolder(refs, own.pm.tag, entries, home);
    assertNoOverlap(refs.filter((r) => !(own.pm.issues || []).some((i) => same(i, r))), own.pm.tag, entries, home, deps);
  }
  const reason = parsed.reason || S.REASON_UNSTATED;
  let out = null;
  io.updateTopLevel(sid, (rec) => {
    if (!S.isActivePm(rec)) refuse("the PM changed while this command ran; retry.");
    const cur = rec.pm.issues || [];
    let next;
    if (op === "add") {
      const fresh = refs.filter((r) => !cur.some((i) => same(i, r)));
      if (fresh.length === 0) refuse(`${labels(refs)} is already assigned to ${rec.pm.tag}.`);
      next = cur.concat(fresh);
    } else {
      const missing = refs.filter((r) => !cur.some((i) => same(i, r)));
      if (missing.length) refuse(`${labels(missing)} is not assigned to ${rec.pm.tag}.`);
      next = cur.filter((i) => !refs.some((r) => same(i, r)));
    }
    const log = (rec.pm.assignment_log || []).concat([{ at: now, op, issues: refs, reason }]);
    rec.pm = Object.assign({}, rec.pm, { issues: next, assignment_log: log, archived_at: next.length === 0 ? now : null });
    out = rec.pm;
  });
  return result(op, out, refs, Boolean(parsed.reason));
}

function runPmWriter(input, deps) {
  const sid = input && input.session_id;
  const hit = typedSlashCommand(input && input.prompt, NAMES);
  if (!hit || typeof sid !== "string" || !io.SESSION_ID_VALID_RE.test(sid)) return {};
  const nowMs = deps && typeof deps.now === "function" ? deps.now() : Date.now();
  const now = new Date(nowMs).toISOString();
  try {
    if (hit.name === "wf-init" || hit.name === "workflow-init") {
      let st = null;
      try { st = io.readRawState(sid); } catch (_) { return {}; }
      return S.hasPmMark(st) ? { block: `[pm-session] this is a PM session (${st.pm.tag}); no workflow runs here. Start the work in a new session.` } : {};
    }
    if (hit.name === "pm-init") return init(sid, hit.args, now, input, deps);
    if (hit.name === "pm-add") return assign("add", sid, hit.args, now, input, deps);
    if (hit.name === "pm-remove") return assign("remove", sid, hit.args, now, input, deps);
    const r = inherit(sid, hit.args, nowMs, input, deps);
    return r ? { context: r.context, notice: r.notice } : {};
  } catch (e) {
    if (e instanceof C.Refusal) return { block: `[pm-session] /${hit.name} refused: ${e.message}` };
    throw e;
  }
}

module.exports = { NAMES, WRITER_FORGE_BUDGET_MS, runPmWriter };
