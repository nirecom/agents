"use strict";
// The only writer of the `pm` state key (#2941), run by the UserPromptSubmit issue-title hook
// before naming. A typed /pm-init, /pm-add, /pm-remove, /pm-rename or /resume-session --from is
// applied here; a typed /wf-init in a PM session is refused. runPmWriter(input, deps) -> {block?,
// context?, notice?}: block is the refusal shown to the user, context the `[pm-session]` note for the
// model, notice the one sentence for the user. Every PM command runs inside the PM lock (#2942), in the
// order: checks -> PM field -> state.

const path = require("path");
const { classifyTypedSlashCommand } = require("../lib/typed-slash-command");
const { NAMES } = require("./names");
const { parsePmInitArgs, parsePmAssignArgs } = require("../lib/session-name");
const io = require("../workflow-state/state-io");
const S = require("./schema");
const scan = require("./scan");
const C = require("./writer-common");
const O = require("./ownership");
const { withPmLock, PM_LOCK_WAIT_MS } = require("./pm-lock");
const { budgetOf, createHookBudget } = require("./budget");
const { inherit, wantsInherit } = require("./inherit");

const { refuse, labels } = C;

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

// assertNoOverlap(adds, ownTag, entries, home, deps, deadlineAt) — the forge check against every other
// active PM's range; skipped (no forge call) when nothing is added or no other PM is active.
function assertNoOverlap(adds, ownTag, entries, home, deps, deadlineAt) {
  const others = scan.listActivePms(entries).filter((p) => !S.sameTag(p.tag, ownTag))
    .map((p) => ({ tag: p.tag, session_id: p.session_id, issues: p.issues.map((i) => C.normalizeStoredRef(i, home)) }));
  if (adds.length === 0 || others.length === 0) return;
  const { findOverlap, refusalText } = require(path.join(__dirname, "..", "..", "bin", "lib", "pm-state", "overlap"));
  const r = findOverlap(adds.map((a) => C.normalizeRef(a, home)), ownTag, others, C.ancestryOf(deps, deadlineAt));
  if (!r.ok) refuse(refusalText(r));
}

// assertAddable(adds, pm, entries, home, ctx) — every check an issue new to pm passes before any write.
// The cards the owner check read go to the field I/O, so the write reads none of its own.
function assertAddable(adds, pm, entries, home, ctx) {
  assertNoDirectHolder(adds, pm.tag, entries, home);
  const deadlineAt = ctx.budget.checkDeadline();
  assertNoOverlap(adds, pm.tag, entries, home, ctx.deps, deadlineAt);
  if (adds.length === 0 || !ctx.io) return;
  const cards = O.assertOneOwner(adds, pm, entries, { deadlineAt, deps: ctx.deps });
  if (typeof ctx.io.seedCards === "function") ctx.io.seedCards(cards);
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

function init(sid, args, now, ctx) {
  const { tag, refs, objective } = parsePmInitArgs(args);
  if (!S.isValidPmTag(tag)) refuse("usage: /pm-init <tag> [#A …] [theme]; the tag is 1 to 40 characters of letters, digits and - only");
  if (S.hasPmMark(C.rawOf(sid))) refuse("this session already has a PM; one session holds one PM.");
  if (C.workflowBegun(sid)) refuse("this session has started a workflow; start the PM in a new session.");
  const entries = scan.listPmFiles();
  if (scan.tagInUse(tag, entries)) refuse(`the tag ${tag} is already used (tags are never reused: ended PMs and renamed tags included); choose another.`);
  const home = ctx.home;
  const issues = dedupe(refs.map((r) => C.normalizeRef(r, home)), home);
  const pm = {
    tag, issues, objective: objective || null, current_since: now, upstream_session_id: null,
    assignment_log: [{ at: now, op: "init", issues, reason: objective || S.REASON_UNSTATED }],
    sequence: { updated_at: null, tables: [], unverified: null }, archived_at: null,
  };
  assertAddable(issues, pm, entries, home, ctx);
  O.writeFields(issues.length > 0 ? ctx.io : null, issues.map((ref) => ({ ref, value: tag })));
  io.updateTopLevel(sid, (rec) => { if (S.hasPmMark(rec)) refuse("this session already has a PM."); rec.pm = pm; });
  return result("init", pm, issues, Boolean(objective));
}

function assign(op, sid, args, now, ctx) {
  const own = C.rawOf(sid);
  if (!S.hasPmMark(own)) refuse(`/pm-${op} needs a PM session; start one with /pm-init.`);
  if (!S.isActivePm(own)) refuse(`the PM ${own.pm.tag} has ended; an ended PM takes no change.`);
  const parsed = parsePmAssignArgs(args);
  const home = ctx.home;
  const same = (a, b) => S.sameIssue(a, b, home);
  const refs = dedupe(parsed.refs.map((r) => C.normalizeRef(r, home)), home);
  if (refs.length === 0) refuse(`usage: /pm-${op} #A [#B …] [reason]`);
  const entries = scan.listPmFiles();
  assertWritableGeneration(sid, own.pm, entries);
  const cur = own.pm.issues || [];
  if (op === "add") {
    const fresh = refs.filter((r) => !cur.some((i) => same(i, r)));
    if (fresh.length === 0) refuse(`${labels(refs)} is already assigned to ${own.pm.tag}.`);
    assertAddable(fresh, own.pm, entries, home, ctx);
    O.writeFields(ctx.io, fresh.map((ref) => ({ ref, value: own.pm.tag })));
  } else {
    const missing = refs.filter((r) => !cur.some((i) => same(i, r)));
    if (missing.length) refuse(`${labels(missing)} is not assigned to ${own.pm.tag}.`);
    O.writeFields(ctx.io, O.ownedOnly(ctx.io, refs, own.pm).map((ref) => ({ ref, value: null })));
  }
  const reason = parsed.reason || S.REASON_UNSTATED;
  let out = null;
  io.updateTopLevel(sid, (rec) => {
    if (!S.isActivePm(rec) || rec.pm.tag !== own.pm.tag) refuse("the PM changed while this command ran; retry.");
    const now0 = rec.pm.issues || [];
    let next;
    const extra = {};
    if (op === "add") next = now0.concat(refs.filter((r) => !now0.some((i) => same(i, r))));
    else {
      next = now0.filter((i) => !refs.some((r) => same(i, r)));
      const { removeFromSequence } = require(path.join(__dirname, "..", "..", "bin", "lib", "pm-state", "sequence"));
      const seq = rec.pm.sequence && typeof rec.pm.sequence === "object" ? rec.pm.sequence : null;
      if (seq) extra.sequence = Object.assign({}, seq, removeFromSequence(seq, refs, { homeRepo: home, at: now }));
    }
    const log = (rec.pm.assignment_log || []).concat([{ at: now, op, issues: refs, reason }]);
    rec.pm = Object.assign({}, rec.pm, extra, { issues: next, assignment_log: log, archived_at: next.length === 0 ? now : null });
    out = rec.pm;
  });
  return result(op, out, refs, Boolean(parsed.reason));
}

// gate(sid, c) -> {block} | {st}: a PM command (hit or undecidable) on an unreadable state, or an
// undecidable prompt in a PM session, is refused (#2942 fail-safe); a missing state reads as null.
function gate(sid, c) {
  const what = c.status === "hit" ? `/${c.name}` : "this prompt";
  let st;
  try { st = io.readRawState(sid); } catch (_) {
    return { block: `[pm-session] ${what} refused: the session's state file cannot be read, so whether this is a PM session is unknown. Repair or remove the state file, then retry.` };
  }
  if (c.status === "undecidable" && S.hasPmMark(st)) {
    return { block: `[pm-session] this prompt was refused in the PM session ${st.pm.tag}: its leading wrapper cannot be read (${c.reason}), so whether it carries a PM command is unknown. Retype the prompt without the wrapper.` };
  }
  return { st };
}

// dispatch(hit, sid, nowMs, input, deps) -> the writer result of one PM command, run inside the PM lock.
function dispatch(hit, sid, nowMs, input, deps) {
  const now = new Date(nowMs).toISOString();
  if (hit.name === "resume-session") {
    const r = inherit(sid, hit.args, nowMs, input, deps);
    return r ? { context: r.context, notice: r.notice } : {};
  }
  // io is resolved on first use, after the refs are normalized, so repo-unresolved is refused before origin-unknown.
  let fieldIo;
  const ctx = {
    deps, budget: budgetOf(deps), home: C.homeRepoOf(input, deps),
    get io() { if (fieldIo === undefined) fieldIo = O.fieldIoOf(input, deps); return fieldIo; },
  };
  if (hit.name === "pm-init") return init(sid, hit.args, now, ctx);
  if (hit.name === "pm-add") return assign("add", sid, hit.args, now, ctx);
  if (hit.name === "pm-remove") return assign("remove", sid, hit.args, now, ctx);
  if (hit.name === "pm-rename") return require("./rename").rename(sid, hit.args, now, ctx);
  return {};
}

// withInbox(sid, r) -> r with the PM's inbox (#2942) appended to its context, run after the PM lock is
// released; fail-open, so a failed inbox never changes the command's result. /pm-rename skips it: its
// mailbox move stays on disk for the next PM command to show. The inbox reads the forge of the writer's
// home origin (input.cwd's), the same origin O.fieldIoOf gates the PM field on.
function withInbox(sid, r, name, input, deps) {
  if (!r || r.block || !r.context || name === "pm-rename") return r;
  try {
    const origin = C.homeOriginOf(input, deps);
    const inbox = require("../../bin/lib/pm-notify/inbox");
    const budget = budgetOf(deps);
    const budgetMs = budget.limited ? budget.inboxMs() : inbox.DEFAULT_BUDGET_MS;
    const text = inbox.runInbox(sid, { budgetMs, drift: false, origin, spawnSync: deps && deps.spawnSync });
    return text ? Object.assign({}, r, { context: `${r.context}\n${text}` }) : r;
  } catch (_) {
    return r;
  }
}

// A call without deps.budget is one hook run that starts now; the hook entry hands its process-start budget.
function runPmWriter(input, given) {
  const deps = given && given.budget ? given : Object.assign({}, given, { budget: createHookBudget({ startedAt: Date.now() }) });
  const sid = input && input.session_id;
  const c = classifyTypedSlashCommand(input && input.prompt, NAMES);
  if (c.status === "none" || typeof sid !== "string" || !io.SESSION_ID_VALID_RE.test(sid)) return {};
  const g = gate(sid, c);
  if (g.block) return { block: g.block };
  if (c.status !== "hit") return {};
  const hit = c;
  if (hit.name === "wf-init" || hit.name === "workflow-init") {
    const st = g.st;
    return S.hasPmMark(st) ? { block: `[pm-session] this is a PM session (${st.pm.tag}); no workflow runs here. Start the work in a new session.` } : {};
  }
  if (hit.name === "resume-session" && !wantsInherit(sid, hit.args)) return {};
  const nowMs = deps && typeof deps.now === "function" ? deps.now() : Date.now();
  try {
    const wait = deps && Number.isFinite(deps.pmLockWaitMs) ? deps.pmLockWaitMs : PM_LOCK_WAIT_MS;
    const waitMs = Math.min(wait, deps.budget.left());
    return withInbox(sid, withPmLock(() => dispatch(hit, sid, nowMs, input, deps), { waitMs }), hit.name, input, deps);
  } catch (e) {
    const r = C.lockRefusal(e);
    if (r instanceof C.Refusal) return { block: `[pm-session] /${hit.name} refused: ${r.message}` };
    throw e;
  }
}

module.exports = { NAMES, runPmWriter };
