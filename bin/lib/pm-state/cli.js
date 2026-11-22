"use strict";
// bin/pm-state (#2941): the read side of the `pm` state key and the one writer of pm.sequence.
//   show --session <sid>                       {tag, issues, archived, current, sequence} or {pm:null}
//   owner --issue <ref>… [--timeout-ms <n>]    {tag, session_id} or {pm:null} from the PM field (owner.js);
//                                              2+ --issue: {owners:[{issue, tag, session_id} | {issue, pm:null}]}
//   list                                       {tags: [...]} every tag ever used, archived included
//   set-sequence [--session <sid>] --file <f> | --revalidate   the caller's table, after the range check
//   set-reason --text <reason>                 fills the caller's last unstated assignment_log entry
// The caller is CLAUDE_CODE_SESSION_ID (deps.callerSessionId); writes touch only its PM, under the PM lock
// (#2942: an old generation is refused with stale-generation, a busy lock with pm-lock-busy).
// Exit 0 on success, 1 on a refusal or undecidable answer, 2 on a malformed request. deps: see main().

const fs = require("fs");
const path = require("path");
const HOOKS = path.join(__dirname, "..", "..", "..", "hooks");
const io = require(path.join(HOOKS, "workflow-state", "state-io"));
const S = require(path.join(HOOKS, "pm-session", "schema"));
const scan = require(path.join(HOOKS, "pm-session", "scan"));
const W = require(path.join(HOOKS, "pm-session", "writer-common"));
const { parseIssueFlagValue } = require(path.join(HOOKS, "lib", "parse-closes-issues"));
const { resolveSessionId } = require(path.join(HOOKS, "workflow-state", "session-id"));
const links = require("../forge-issue-links");
const { createAncestry } = require("./ancestry");
const { resolveOwners } = require("./owner");
const { unresolvableExit, refLabelOf } = require("./overlap");
const SEQ = require("./sequence");
const { forgeKindOf } = require("../pm-field/forge-kind");
const { withPmLock, PmLockBusy } = require(path.join(HOOKS, "pm-session", "pm-lock"));

const TOOL = "pm-state";
class Exit extends Error { constructor(code, msg) { super(msg); this.code = code; } }
const fail = (code, msg) => { throw new Exit(code, msg); };

// parseFlags(argv, valued, bare?, repeated?) -> {name: value | true | [values]}; a bare flag takes no value,
// a repeated flag collects every value in input order.
function parseFlags(argv, valued, bare, repeated) {
  const flags = bare || [];
  const many = repeated || [];
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    const a = String(argv[i]);
    const name = a.replace(/^--/, "");
    if (a.startsWith("--") && flags.includes(name)) { o[name] = true; continue; }
    if (!a.startsWith("--") || !valued.includes(name) || argv[i + 1] === undefined) fail(2, `unexpected argument: ${a}`);
    if (many.includes(name)) o[name] = (o[name] || []).concat([argv[++i]]);
    else o[name] = argv[++i];
  }
  return o;
}

const validSid = (sid) => typeof sid === "string" && io.SESSION_ID_VALID_RE.test(sid);

function sessionOf(o) {
  const sid = o.session || resolveSessionId();
  if (!validSid(sid)) fail(2, "--session <sid> is required");
  return sid;
}

// callerOf(d) -> the calling PM session id; exit 2 without one.
function callerOf(d) {
  const sid = d.callerSessionId !== undefined ? d.callerSessionId : resolveSessionId();
  if (!validSid(sid)) fail(2, "the caller session id is unknown: run this from the PM session itself (CLAUDE_CODE_SESSION_ID)");
  return sid;
}

function homeRepoOf(d) {
  const r = (d.resolveOwnerRepoFromOrigin || links.resolveOwnerRepoFromOrigin)();
  return r && r.ok ? r.ownerRepo : null;
}

// normalizer(homeRepo) -> ref -> {number, repo: "owner/repo"}; the rule is W.normalizeRef (#2942),
// whose repo-unresolved refusal becomes exit 1.
function normalizer(homeRepo) {
  return (ref) => {
    try { return W.normalizeRef(ref, homeRepo); } catch (e) {
      if (e instanceof W.Refusal) fail(1, e.message);
      throw e;
    }
  };
}

function contextOf(d) {
  const homeRepo = homeRepoOf(d);
  const entries = scan.listPmFiles();
  const now = typeof d.now === "function" ? d.now : Date.now;
  const ancestry = createAncestry({ fetchAncestorChains: d.fetchAncestorChains || links.fetchAncestorChains, now });
  const resolve = (ref) => {
    const r = W.normalizeStoredRef(ref, homeRepo);
    return r.repo && r.repo.includes("/") ? r : null;
  };
  return { S, scan, entries, homeRepo, ancestry, resolve, normalize: normalizer(homeRepo) };
}

const nowIso = (d) => new Date(typeof d.now === "function" ? d.now() : Date.now()).toISOString();

function show(argv) {
  const sid = sessionOf(parseFlags(argv, ["session"]));
  let st;
  try { st = io.readRawState(sid); } catch (_) { fail(1, `the state file of ${sid} cannot be read`); }
  if (!S.hasPmMark(st)) return { pm: null };
  const p = st.pm;
  return {
    tag: p.tag, issues: p.issues || [], archived: Boolean(p.archived_at), current: scan.isCurrentGeneration(sid),
    sequence: p.sequence === undefined ? null : p.sequence,
  };
}

// owner: one --issue prints {tag, session_id} | {pm:null} (the #2991 gate's contract); several print
// {owners:[{issue, ...owner} | {issue, pm:null}]} in input order, from one batched forge read.
function owner(argv, d) {
  const o = parseFlags(argv, ["issue", "timeout-ms"], [], ["issue"]);
  const raws = o.issue || [];
  const refs = raws.map(parseIssueFlagValue);
  if (refs.length === 0 || refs.some((r) => !r)) fail(2, "--issue <N | #N | owner/repo#N> is required");
  let timeoutMs;
  if (o["timeout-ms"] !== undefined) {
    if (!/^[1-9][0-9]*$/.test(o["timeout-ms"])) fail(2, "--timeout-ms takes a positive integer (milliseconds)");
    timeoutMs = Number(o["timeout-ms"]);
  }
  // The PM field lives on GitHub only: a GitLab checkout has no owner and makes no gh call.
  const gitlab = (d.forgeKindOf || forgeKindOf)({ cwd: process.cwd() }) === "gitlab";
  if (gitlab && refs.length === 1) return { pm: null };
  if (gitlab) return { owners: refs.map((r) => ({ issue: S.refLabel(r), pm: null })) };
  const ctx = contextOf(d);
  const norm = refs.map(ctx.normalize);
  const rs = resolveOwners(norm, Object.assign({}, ctx, { timeoutMs }));
  rs.forEach((r, i) => {
    if (!r.ok) fail(1, `the owner of ${raws[i]} could not be decided (${r.reason}); check \`gh auth status\` and retry`);
  });
  if (rs.length === 1) return rs[0].owner || { pm: null };
  return { owners: rs.map((r, i) => Object.assign({ issue: S.refLabel(norm[i]) }, r.owner || { pm: null })) };
}

// sequenceRefusal(r) -> the refusal text of a failed checkSequence: the kind, the issues, the reason, the exit.
function sequenceRefusal(r) {
  const refs = r.issues.map(refLabelOf).join(" ");
  if (r.kind === "structure") return `structure: ${r.reason}`;
  if (r.kind === "out-of-range") return `out-of-range: ${refs} is outside the range of this PM; add it (or its meta) with /pm-add first, or drop it from the table`;
  if (r.kind === "unresolvable") {
    const exitReason = r.reason.split(",").includes("label-overflow") ? "label-overflow" : r.reason;
    return `unresolvable (${r.reason}): ${refs}; retrying will not fix it. ${unresolvableExit(exitReason, r.ancestor)}`;
  }
  return `unverified (${r.reason}): ${refs}; ${SEQ.RETRY}`;
}

// ownPm(sid, entries) -> the caller's PM entry; exit 1 unless it is the current generation of an active PM.
function ownPm(sid, entries) {
  const me = entries.find((e) => e.session_id === sid);
  if (!me) fail(1, `set-sequence refused: session ${sid} is not a PM session`);
  if (me.pm.archived_at) fail(1, `set-sequence refused: the PM ${me.pm.tag} has ended; an ended PM takes no sequence`);
  if (!scan.isCurrentGeneration(sid, entries)) {
    const cur = scan.currentOf(me.pm.tag, entries);
    fail(1, `set-sequence refused: stale-generation: session ${sid} is an old generation of ${me.pm.tag}; write from the current one, ${cur ? cur.session_id : "(unknown)"}`);
  }
  return me;
}

// locked(d, fn) — runs fn under the PM lock (#2942); a busy lock is exit 1 with pm-lock-busy.
function locked(d, fn) {
  try { return withPmLock(fn, { waitMs: d.pmLockWaitMs }); } catch (e) {
    if (e instanceof PmLockBusy) fail(1, e.message);
    throw e;
  }
}

function setSequence(argv, d) {
  const o = parseFlags(argv, ["session", "file"], ["revalidate"]);
  const caller = callerOf(d);
  if (Boolean(o.file) === Boolean(o.revalidate)) fail(2, "set-sequence takes exactly one of --file <json> and --revalidate");
  if (o.session !== undefined && o.session !== caller) fail(1, "set-sequence writes only the calling PM's table: write another PM's table from inside that PM session");
  let tables;
  if (o.file) {
    let payload;
    try { payload = JSON.parse(fs.readFileSync(o.file, "utf8")); } catch (e) { fail(1, `cannot read the sequence file: ${e.message}`); }
    try { tables = SEQ.validatePayload(payload); } catch (e) {
      if (e instanceof SEQ.SeqRefusal) fail(1, `set-sequence refused: structure: ${e.message}`);
      throw e;
    }
  }
  return locked(d, () => {
    const ctx = contextOf(d);
    const me = ownPm(caller, ctx.entries);
    if (o.revalidate) tables = me.pm.sequence && Array.isArray(me.pm.sequence.tables) ? me.pm.sequence.tables : [];
    const r = SEQ.checkSequence(tables, { tag: me.pm.tag, session_id: caller, issues: me.pm.issues || [] }, { ancestry: ctx.ancestry, homeRepo: ctx.homeRepo });
    if (!r.ok) fail(1, `set-sequence refused: ${sequenceRefusal(r)}`);
    const now = nowIso(d);
    try { SEQ.writeSequence(caller, tables, { io, S, now, checkedIssues: me.pm.issues || [], homeRepo: ctx.homeRepo }); } catch (e) {
      if (e instanceof SEQ.SeqRefusal) fail(1, `set-sequence refused: ${e.message}`);
      throw e;
    }
    return { ok: true, session_id: caller, updated_at: now };
  });
}

const REASON_OPS = ["init", "add", "remove"];
const NOT_WRITABLE = "the last entry already has a reason, or is an entry that cannot take one";

function setReason(argv, d) {
  const o = parseFlags(argv, ["text"]);
  if (typeof o.text !== "string" || o.text.trim() === "") fail(2, "--text <reason> is required (not blank)");
  const caller = callerOf(d);
  const text = o.text.trim();
  return locked(d, () => writeReason(caller, text));
}

function writeReason(caller, text) {
  const entries = scan.listPmFiles();
  const me = entries.find((e) => e.session_id === caller);
  if (me && !scan.isCurrentGeneration(caller, entries)) {
    const cur = scan.currentOf(me.pm.tag, entries);
    fail(1, `set-reason refused: stale-generation: session ${caller} is an old generation of ${me.pm.tag}; write from the current one, ${cur ? cur.session_id : "(unknown)"}`);
  }
  try {
    io.updateTopLevel(caller, (rec) => {
      if (!S.hasPmMark(rec)) throw new Exit(1, `set-reason refused: session ${caller} is not a PM session`);
      const log = Array.isArray(rec.pm.assignment_log) ? rec.pm.assignment_log : [];
      const last = log[log.length - 1];
      if (!last || typeof last !== "object" || !REASON_OPS.includes(last.op) || last.reason !== S.REASON_UNSTATED) {
        throw new Exit(1, `set-reason refused: ${NOT_WRITABLE}`);
      }
      const next = log.slice(0, -1).concat([Object.assign({}, last, { reason: text })]);
      rec.pm = Object.assign({}, rec.pm, { assignment_log: next });
    });
  } catch (e) {
    if (e instanceof Exit) throw e;
    fail(1, `set-reason failed: ${e.message}`);
  }
  return { ok: true, session_id: caller };
}

const COMMANDS = {
  show,
  owner,
  list: (argv) => { parseFlags(argv, []); return { tags: scan.listPmTags() }; },
  "set-sequence": setSequence,
  "set-reason": setReason,
};

// inboxAfter(sid, err): the PM's inbox (#2942) once a write has released the PM lock; fail-open.
function inboxAfter(sid, err) {
  try {
    const text = require("../pm-notify/inbox").runInbox(sid, { budgetMs: 2000, drift: true });
    if (text) err(`${text}\n`);
  } catch (_) { /* fail-open: the inbox runs at the next PM command */ }
}

// main(argv, deps) — deps: {fetchAncestorChains?, resolveOwnerRepoFromOrigin?, forgeKindOf?, pmLockWaitMs?,
//   callerSessionId?, now?, out?, err?}.
function main(argv, deps) {
  const d = deps || {};
  const out = d.out || ((s) => process.stdout.write(s));
  const err = d.err || ((s) => process.stderr.write(s));
  try {
    const cmd = COMMANDS[argv[0]];
    if (!cmd) fail(2, `usage: ${TOOL} show|owner|list|set-sequence|set-reason …`);
    const res = cmd(argv.slice(1), d);
    out(`${JSON.stringify(res)}\n`);
    if (argv[0].startsWith("set-") && res && res.session_id) inboxAfter(res.session_id, err);
    return 0;
  } catch (e) {
    err(`${TOOL}: ${e.message}\n`);
    return e instanceof Exit ? e.code : 1;
  }
}

module.exports = { main, normalizer };
