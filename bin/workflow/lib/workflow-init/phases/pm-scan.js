"use strict";
// pm-scan phase (#2942 S13): runs between wip-check and route-decision. Asks owner (per-issue bound 2000 ms,
// 10 s overall) for each selected issue, keeps the answer as the issue's first owner record, records an
// undecidable issue as an undelivered start notification, and blocks with multi-pm when two or more PMs own
// the issues (one notification per PM). Fail-open: any error lets the init continue.

const path = require("path");
const C = require(path.join(__dirname, "..", "..", "..", "..", "lib", "pm-notify", "common"));
const W = require(path.join(__dirname, "..", "..", "..", "..", "..", "hooks", "pm-session", "writer-common"));

const { keep } = require(path.join(__dirname, "..", "..", "..", "..", "lib", "pm-notify", "record"));

const SCAN_BUDGET_MS = 10000;

// refsOf(state, unresolved?) -> the normalized refs; an issue whose repo cannot be resolved is pushed onto
// `unresolved` (as "#N") instead of vanishing.
function refsOf(state, unresolved) {
  const issues = Array.isArray(state && state.issues) ? state.issues : [];
  const map = (state && state.repo_map) || {};
  const refs = [];
  issues.forEach((n, i) => {
    try { refs.push(W.normalizeRef({ number: n, repo: map[i] || C.homeRepo() || undefined }, C.homeRepo())); } catch (_) {
      if (Array.isArray(unresolved)) unresolved.push(`#${n}`);
    }
  });
  return refs;
}

function ask(refs) {
  const entries = C.scan.listPmFiles();
  const deadline = Date.now() + SCAN_BUDGET_MS;
  return refs.map((ref) => {
    const left = deadline - Date.now();
    if (left <= 0) return { ref, r: { ok: false, reason: "timeout" } };
    return { ref, r: C.ownerOf(ref, Math.min(C.OWNER_TIMEOUT_MS, left), entries) };
  });
}

function pmScan(state, sid) {
  try {
    const unresolved = [];
    const refs = refsOf(state, unresolved);
    if ((refs.length === 0 && unresolved.length === 0) || !sid) return { done: false };
    const answers = ask(refs);
    const owners = [];
    for (const a of answers) {
      if (a.r.ok && a.r.owner && !owners.some((o) => C.S.sameTag(o.tag, a.r.owner.tag))) owners.push({ tag: a.r.owner.tag, ref: a.ref });
    }
    const at = new Date().toISOString();
    try {
      C.updateNotes(sid, (notes, records) => {
        for (const issue of unresolved) keep(notes, "start", issue, sid, { result: "undelivered", reason: "repo-unresolved" });
        for (const a of answers) {
          if (!a.r.ok) {
            keep(notes, "start", C.issueOf(a.ref), sid, { result: "undelivered", reason: a.r.reason });
            continue;
          }
          records[C.keyOf(a.ref)] = { tag: a.r.owner ? a.r.owner.tag : null, at };
        }
        if (owners.length > 1) {
          for (const o of owners) keep(notes, "multi-pm", C.issueOf(o.ref), sid, { to_tag: o.tag });
        }
      });
    } catch (_) { /* fail-open: a lost notes write must not drop the multi-pm block */ }
    if (owners.length < 2) return { done: false };
    const tags = owners.map((o) => o.tag).join(", ");
    return {
      blocked: true,
      reason: "multi-pm",
      hint: `the selected issues are owned by more than one PM (${tags}); have one PM own them all with /pm-remove and /pm-add, then rerun /workflow-init`,
    };
  } catch (_) {
    return { done: false };
  }
}

// recordStart(state, sid): the start notification (write-context) for each issue whose owner record names a
// PM or is missing (pm-scan did not answer); an issue pm-scan found ownerless is skipped. Fail-open.
function recordStart(state, sid) {
  try {
    const refs = refsOf(state);
    if (refs.length === 0 || !sid) return;
    const { records } = C.readNotes(sid);
    const want = refs.filter((ref) => { const r = records[C.keyOf(ref)]; return !r || r.tag; });
    if (want.length === 0) return;
    C.updateNotes(sid, (notes) => { for (const ref of want) keep(notes, "start", C.issueOf(ref), sid); });
  } catch (_) { /* fail-open: the init goes on without the notification */ }
}

module.exports = { pmScan, recordStart };
