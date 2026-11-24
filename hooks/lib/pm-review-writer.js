"use strict";
// hooks/lib/pm-review-writer.js — who may write a review verdict for a workflow session (#3144 S1-1).
// The assigned PM of the issues a session closes reviews it instead of the supervisor-audit subagent:
// on a pre-confirm audit run (kind=audit) or on a pm-review round of the PR (kind=pm-review). A PM writes
// only while it is the decided owner now AND the destination the session recorded for that run / round,
// so a stale owner, a local holder or a candidate the user did not pick never writes. Every judge fails
// closed: an unreadable record, an undecidable owner or a malformed argument is a refusal with a reason.
// The record shapes below are the one place the C2 / C4 writers and readers take them from.

const path = require("path");

const REPORTER_DEST = "route:pm-dest";
const REPORTER_FALLBACK = "user:pm-review-fallback";
const SOURCE_REQUEST_PREFIX = "request:";
const SOURCE_USER = "user";
const SOURCE_USER_PR_UNCONFIRMED = "user-pr-unconfirmed";
const SOURCE_PM = "pm";
const PR_RUN_PREFIX = "pr:";
const FORMAT = "pm-review";
const VERDICT_REQUESTED = "REQUESTED";
const VERDICT_AUTO_EXTEND = "AUTO_EXTEND";

const SID_RE = /^[A-Za-z0-9_-]+$/;
const FP_RE = /^[0-9a-f]{40}$/;
const RUN_TOKEN_RE = /(?:^|\s)run=([A-Za-z0-9_-]+)(?=$|\s)/;
const PM_TOKEN_RE = /(?:^|\s)pm=([A-Za-z0-9_-]+)(?=$|\s)/;

const ROOT = path.resolve(__dirname, "..", "..");
const common = () => require(path.join(ROOT, "bin", "lib", "pm-notify", "common.js"));
const rounds = () => require(path.join(ROOT, "bin", "lib", "codex-review-loop", "review-rounds.js"));
const store = () => require(path.join(ROOT, "bin", "lib", "codex-review-loop", "review-rounds-store.js"));

const isSid = (s) => typeof s === "string" && s !== "" && SID_RE.test(s);
const refuse = (reason) => ({ ok: false, reason });
const runTokenOf = (detail) => { const m = RUN_TOKEN_RE.exec(String(detail || "")); return m ? m[1] : null; };

// destFinding(runId, pmSid) / fallbackFinding(runId) -> the S2-2 / S2-4 findings. A null runId leaves the
// run token out; armCore adds `run=<id>` once the run id exists, in the same commit as the run.
function destFinding(runId, pmSid) {
  const run = runId ? ` run=${runId}` : "";
  return { categories: ["workflow"], severity: "notice", reporter: REPORTER_DEST,
    detail: `pm-review destination: the assigned PM reviews this pre-confirm run pm=${pmSid}${run}` };
}
function fallbackFinding(runId) {
  const run = runId ? ` run=${runId}` : "";
  return { categories: ["workflow"], severity: "notice", reporter: REPORTER_FALLBACK,
    detail: `pm-review fallback: the user chose the conventional supervisor audit for this run${run}` };
}

// destOfRun(findings, runId) -> the pm sid of the last destination finding of runId, or null.
function destOfRun(findings, runId) {
  let dest = null;
  for (const f of Array.isArray(findings) ? findings : []) {
    if (!f || f.reporter !== REPORTER_DEST || runTokenOf(f.detail) !== runId) continue;
    const m = PM_TOKEN_RE.exec(String(f.detail || ""));
    dest = m ? m[1] : null;
  }
  return dest;
}
const isFallbackRun = (findings, runId) => (Array.isArray(findings) ? findings : [])
  .some((f) => f && f.reporter === REPORTER_FALLBACK && runTokenOf(f.detail) === runId);

// pmCandidatesOf(targetSid, opts?) -> {decided, cands:[{tag, session_id}], reason}. Asks the decided owner of
// every closed issue (no short circuit, so each ref is looked up now); any undecidable ref empties the list.
function pmCandidatesOf(targetSid, opts) {
  const C = common();
  let refs;
  try {
    refs = require("../workflow-state/session-facts").getClosesIssues(targetSid, opts && opts.plansDir ? { plansDir: opts.plansDir } : undefined);
  } catch (e) {
    return { decided: false, cands: [], reason: `closes-issues-unreadable: ${e.message}` };
  }
  const deadline = Date.now() + C.OWNER_TIMEOUT_MS;
  const cands = [];
  const undecided = [];
  let entries;
  try { entries = C.scan.listPmFiles(); } catch (e) { return { decided: false, cands: [], reason: `pm-files-unreadable: ${e.message}` }; }
  for (const raw of Array.isArray(refs) ? refs : []) {
    let ref;
    try { ref = C.W.normalizeRef(raw, raw && raw.repo ? null : C.homeRepo()); } catch (e) {
      // A ref with no resolvable repo has no board to ask; with no PM state file registered either, no
      // PM can own it, so it has no owner. With a PM registered it stays undecidable (asked, never guessed).
      if (Array.isArray(entries) && entries.length === 0) continue;
      undecided.push(`#${raw && raw.number}: ${e.message}`);
      continue;
    }
    let r;
    try { r = C.decidedOwnerOf(ref, Math.max(1, Math.min(C.OWNER_TIMEOUT_MS, deadline - Date.now())), entries); } catch (e) {
      r = { ok: false, reason: `owner-error: ${e.message}` };
    }
    if (!r || r.ok !== true) { undecided.push(`${ref.repo}#${ref.number}: ${(r && r.reason) || "no answer"}`); continue; }
    const o = r.owner;
    if (o && isSid(o.session_id) && !cands.some((c) => c.session_id === o.session_id)) cands.push({ tag: o.tag, session_id: o.session_id });
  }
  if (undecided.length > 0) return { decided: false, cands: [], reason: `owner-undecidable: ${undecided.join("; ")}` };
  return { decided: true, cands, reason: cands.length > 0 ? "" : "no-owner" };
}

// readPmRows(sid) -> the pm-review rows of the session chain; throws when the record cannot be read.
const readPmRows = (sid) => store().readRows(sid, FORMAT, { strict: true }).parsed.filter((r) => r && typeof r === "object");
const isRequest = (r) => typeof r.source === "string" && r.source.startsWith(SOURCE_REQUEST_PREFIX);
const isUser = (r) => r.source === SOURCE_USER || r.source === SOURCE_USER_PR_UNCONFIRMED;
const destOfRequest = (r) => r.source.slice(SOURCE_REQUEST_PREFIX.length);

// roundState(rows) -> {round, request, pmRow, userRow, extensions}: the current round (S3-4: the max
// counter_round of the request and user rows) and the rows written on it.
function roundState(rows) {
  let round = 0;
  for (const r of rows) if ((isRequest(r) || isUser(r)) && Number.isInteger(r.counter_round)) round = Math.max(round, r.counter_round);
  const at = rows.filter((r) => r.counter_round === round);
  const last = (pred) => { const xs = at.filter(pred); return xs.length ? xs[xs.length - 1] : null; };
  return {
    round, request: last(isRequest), pmRow: last((r) => r.source === SOURCE_PM), userRow: last(isUser),
    extensions: rows.filter((r) => r.source === SOURCE_PM && r.verdict === VERDICT_AUTO_EXTEND).length,
  };
}

// nextRoundAllowed(rows) -> {ok, reason, round}: below CAP, or at CAP with the destination's AUTO_EXTEND
// while an extension is left (the codex-review-loop Parameters table, pm-review column).
function nextRoundAllowed(rows) {
  const { PM_REVIEW_CAP: CAP, PM_REVIEW_MAX_EXTENSIONS: MAX } = rounds();
  const st = roundState(rows);
  if (st.round < CAP) return { ok: true, reason: "", round: st.round };
  const ext = st.round === CAP && st.request && st.pmRow && st.pmRow.verdict === VERDICT_AUTO_EXTEND &&
    st.pmRow.writer_sid === destOfRequest(st.request) && st.extensions <= MAX && st.round < CAP + MAX;
  return ext ? { ok: true, reason: "", round: st.round } : { ok: false, reason: `cap-reached: round ${st.round}`, round: st.round };
}

const posInt = (v) => (typeof v === "number" && Number.isInteger(v) && v > 0) || (typeof v === "string" && /^[1-9][0-9]*$/.test(v));

function candidateRefusal(callerSid, targetSid) {
  const pc = pmCandidatesOf(targetSid);
  if (!pc.decided) return `owner-undecidable: ${pc.reason}`;
  if (!pc.cands.some((c) => c.session_id === callerSid)) return "caller-not-candidate: the caller is not the current assigned PM";
  return null;
}

function judgeAudit(callerSid, targetSid, runId) {
  if (typeof runId !== "string" || !/^run-[0-9]+$/.test(runId)) return refuse("invalid-run-id");
  let audit;
  try { audit = (require("./supervisor-state-writer").readState(targetSid) || {}).audit || null; } catch (e) {
    return refuse(`state-unreadable: ${e.message}`);
  }
  if (!audit || audit.audit_run_id !== runId) return refuse(`run-mismatch: ${runId} is not the armed run`);
  if (audit.audit_phase !== "pending" && audit.audit_phase !== "in_progress") return refuse(`run-not-pending: phase ${audit.audit_phase}`);
  const ledger = Array.isArray(audit.ledger) ? audit.ledger.find((e) => e && e.id === runId) : null;
  const cause = (ledger && ledger.cause) || audit.audit_cause || "";
  if (!String(cause).startsWith("pre-confirm:")) return refuse(`not-pre-confirm: cause ${cause}`);
  if (isFallbackRun(audit.findings, runId)) return refuse("fallback-run: the user chose the conventional audit for this run");
  const dest = destOfRun(audit.findings, runId);
  if (!dest) return refuse("no-destination: no PM destination is recorded for this run");
  if (dest !== callerSid) return refuse("not-destination: the caller is not the recorded destination");
  const c = candidateRefusal(callerSid, targetSid);
  return c ? refuse(c) : { ok: true, reason: "", pmSid: callerSid };
}

function judgeReview(callerSid, targetSid, target) {
  const t = target && typeof target === "object" ? target : null;
  if (!t || !posInt(t.round) || !posInt(t.pr) || typeof t.fingerprint !== "string" || !FP_RE.test(t.fingerprint)) {
    return refuse("invalid-target: --round, --fingerprint (40 hex) and --pr are required");
  }
  let rows;
  try { rows = readPmRows(targetSid); } catch (e) { return refuse(`record-unreadable: ${e.message}`); }
  const st = roundState(rows);
  if (!st.request) return refuse(`no-request: round ${st.round} has no request row`);
  if (st.userRow) return refuse(`user-decided: round ${st.round} already has the user's row`);
  if (st.pmRow) return refuse(`already-written: round ${st.round} already has a PM verdict`);
  if (Number(t.round) !== st.round || t.fingerprint !== st.request.fingerprint || `${PR_RUN_PREFIX}${Number(t.pr)}` !== st.request.run_id) {
    return refuse(`target-mismatch: the request is round ${st.round}, ${st.request.fingerprint}, ${st.request.run_id}`);
  }
  if (destOfRequest(st.request) !== callerSid) return refuse("not-destination: the request is addressed to another PM");
  const c = candidateRefusal(callerSid, targetSid);
  return c ? refuse(c) : { ok: true, reason: "", pmSid: callerSid, round: st.round };
}

// judgePmWrite({callerSid, targetSid, kind, runId, target}) -> {ok, reason, pmSid}.
function judgePmWrite(input) {
  const { callerSid, targetSid, kind, runId, target } = input || {};
  if (!isSid(callerSid) || !isSid(targetSid)) return refuse("invalid-sid: caller and target must be session ids");
  if (callerSid === targetSid) return refuse("self-write: the audited session cannot write its own PM verdict");
  if (kind === "audit") return judgeAudit(callerSid, targetSid, runId);
  if (kind === FORMAT) return judgeReview(callerSid, targetSid, target);
  return refuse(`invalid-kind: ${kind}`);
}

// judgeRequestWrite({callerSid, targetSid, pmSid, pr?}) -> {ok, reason, pmSid, round}: the session's own
// request row to a decided candidate, while S3-4 allows the next round.
function judgeRequestWrite(input) {
  const { callerSid, targetSid, pmSid, pr } = input || {};
  if (!isSid(callerSid) || !isSid(targetSid) || !isSid(pmSid)) return refuse("invalid-sid: caller, target and pm must be session ids");
  if (callerSid !== targetSid) return refuse("not-self: only the workflow session writes its own request row");
  if (pr !== undefined && pr !== null && !posInt(pr)) return refuse("invalid-pr: --pr must be a positive integer");
  const pc = pmCandidatesOf(targetSid);
  if (!pc.decided) return refuse(`owner-undecidable: ${pc.reason}`);
  if (!pc.cands.some((c) => c.session_id === pmSid)) return refuse("pm-not-candidate: --pm-sid is not a current assigned PM");
  let rows;
  try { rows = readPmRows(targetSid); } catch (e) { return refuse(`record-unreadable: ${e.message}`); }
  const n = nextRoundAllowed(rows);
  return n.ok ? { ok: true, reason: "", pmSid, round: n.round + 1 } : refuse(n.reason);
}

module.exports = {
  REPORTER_DEST, REPORTER_FALLBACK, SOURCE_REQUEST_PREFIX, SOURCE_USER, SOURCE_USER_PR_UNCONFIRMED, SOURCE_PM,
  PR_RUN_PREFIX, FORMAT, VERDICT_REQUESTED, VERDICT_AUTO_EXTEND, SID_RE, FP_RE,
  destFinding, fallbackFinding, destOfRun, isFallbackRun, runTokenOf, pmCandidatesOf,
  readPmRows, roundState, nextRoundAllowed, judgePmWrite, judgeRequestWrite,
};
