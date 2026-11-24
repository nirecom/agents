"use strict";
// hooks/workflow-gate/user-verified-pm-review.js — #3144 S4-1, the PM review in front of <<WORKFLOW_USER_VERIFIED>>.
// With an assigned PM the sentinel passes only on the PM's OK in the last requested round, or on the user's
// row (WORKFLOW_PM_REVIEW_ACCEPTED), each tied to the current HEAD and PR, so an OK on an older commit or a
// recreated PR never approves the release. A forge that does not answer passes only the user-pr-unconfirmed
// row tied to the last request's PR. Passing means "go on to the TR5 audit": approveFn is never called here.
// Record shapes and the round reader are owned by hooks/lib/pm-review-writer.js.

const { spawnSync } = require("../lib/limited-child-process");
const { withConvLang } = require("../lib/conv-lang");

const W = () => require("../lib/pm-review-writer");
const SENTINEL = "WORKFLOW_PM_REVIEW_ACCEPTED";
const REQUEST = "skills/_shared/pm-pre-pr-contact.md `## Review request`";

function headOf(cwd) {
  try {
    const r = spawnSync("git", ["-C", cwd, "rev-parse", "HEAD"], { encoding: "utf8", timeout: 5000, windowsHide: true });
    const fp = r && r.status === 0 ? String(r.stdout || "").trim() : "";
    return W().FP_RE.test(fp) ? fp : null;
  } catch { return null; }
}

// currentPr(cwd) -> the PR number string, "" when the branch has none, or null when the forge did not answer.
function currentPr(cwd) {
  let r;
  try {
    // Read through the module object so a test seam on gh-detect.prForBranch is honored.
    const { FORGE_QUERY_TIMEOUT_MS } = require("../lib/forge/merge-state");
    r = require("./gh-detect").prForBranch(cwd, { timeoutMs: FORGE_QUERY_TIMEOUT_MS });
  } catch { return null; }
  if (!r || r.state === "UNKNOWN") return null;
  return /^[1-9][0-9]*$/.test(String(r.number || "")) ? String(r.number) : "";
}

const safe = (s) => String(s == null ? "" : s).replace(/[^A-Za-z0-9_.:#-]/g, "");

function blockReason(why) {
  return withConvLang([
    `[EM Supervisor] user_verification PM review: ${why}`,
    `Send the PR to the assigned PM by ${REQUEST} and re-issue the sentinel once the PM's OK is recorded for the current HEAD and PR,`,
    `or, with the user's explicit choice, have the user run echo "<<${SENTINEL}: PR#<n> <reason>>>" for the conventional audit.`,
  ].join("\n"));
}

function unconfirmedReason(lastReq) {
  const pr = lastReq ? safe(String(lastReq.run_id || "").slice(W().PR_RUN_PREFIX.length)) : "";
  return withConvLang([
    "[EM Supervisor] user_verification PM review: the forge did not answer, so the current PR cannot be confirmed.",
    `Show the user the PR URL sent in the Review request${pr ? ` (PR #${pr})` : ""} and ask with AskUserQuestion ` +
      "(metadata.source=pm-review.pr-unconfirmed): retry later, or, after checking that PR, " +
      `run echo "<<${SENTINEL}: PR#<n> <reason>>>".`,
  ].join("\n"));
}

// verdictOf(rows, head, pr) -> null (pass) or a block message. pr null means the forge did not answer.
function verdictOf(rows, head, pr) {
  const w = W();
  const last = rows[rows.length - 1] || null;
  const reqs = rows.filter((r) => typeof r.source === "string" && r.source.startsWith(w.SOURCE_REQUEST_PREFIX));
  const lastReq = reqs[reqs.length - 1] || null;
  const prRun = pr ? w.PR_RUN_PREFIX + pr : null;
  if (!head) return blockReason("the HEAD SHA of the worktree cannot be read (fail-closed).");
  if (last && last.source === w.SOURCE_USER_PR_UNCONFIRMED) {
    const want = pr === null ? (lastReq && lastReq.run_id) : prRun;
    if (last.fingerprint === head && want && last.run_id === want) return null;
  } else if (pr === null) {
    return unconfirmedReason(lastReq);
  } else if (last && last.source === w.SOURCE_USER) {
    if (last.fingerprint === head && prRun && last.run_id === prRun) return null;
  } else {
    const st = w.roundState(rows);
    const p = st.pmRow;
    if (st.request && p && p === last && p.verdict === "OK" && p.writer_sid === st.request.source.slice(w.SOURCE_REQUEST_PREFIX.length) &&
      p.fingerprint === head && p.fingerprint === st.request.fingerprint && prRun && p.run_id === prRun &&
      p.run_id === st.request.run_id) return null;
  }
  return blockReason("no PM OK in the last requested round and no user's row match the current HEAD and PR.");
}

// checkUserVerifiedPmReview(sessionId, cwd, {approveFn, blockFn}) -> {ok, route}. A block calls blockFn
// (which exits in the hook) and returns {ok:false}; no assigned PM returns {ok:true} without a forge call.
function checkUserVerifiedPmReview(sessionId, cwd, opts) {
  const blockFn = (opts && opts.blockFn) || (() => {});
  const stop = (msg) => { blockFn(msg); return { ok: false, reason: msg }; };
  if (!sessionId) return { ok: true, route: "unknown-session" };
  let pc;
  try { pc = W().pmCandidatesOf(sessionId); } catch (e) { pc = { decided: false, cands: [], reason: e.message }; }
  if (pc.decided && pc.cands.length === 0) return { ok: true, route: "subagent" };
  let rows;
  try { rows = W().readPmRows(sessionId); } catch (e) {
    return stop(blockReason(`the pm-review record cannot be read (${safe(e.message)}; fail-closed).`));
  }
  const dir = cwd || process.cwd();
  const msg = verdictOf(rows, headOf(dir), currentPr(dir));
  return msg ? stop(msg) : { ok: true, route: pc.decided ? "pm" : "ask" };
}

module.exports = { checkUserVerifiedPmReview, verdictOf, headOf, currentPr };
