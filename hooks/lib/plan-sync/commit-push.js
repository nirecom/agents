"use strict";
// hooks/lib/plan-sync/commit-push.js
// syncPlanFile: publish one plan file to origin/main by plumbing + CAS, always building
// add/overwrite-only on the remote tip from entries the send predicate keeps (project-host.js).
// publishedBlobUrl: the network-free "is this exact content on origin/main" check behind the URL.
const path = require("path");
const remoteUrl = require("./remote-url");
const { isSyncTarget } = require("./allowlist");
const { readProjectHostState, sendPredicate } = require("./project-host");
const { resolveRemoteUrl, checkProvisioned } = require("./provision");
const { isRegularFile, readVerifiedRegularFile } = require("./local-file");
const G = require("./git");
const { formatTurnMessage } = require("./turn-trailer");
const { turnBaseOf, turnStartOf, turnRange } = require("./turn-commit");
const { pushMainWithLease, classifyLeasePush } = require("./lease-push");
const RS = require("./remote-state");

const DEFAULT_BUDGET_MS = 20000;

function failed(reason, detail) {
  const r = { status: "failed", reason };
  if (detail) r.detail = remoteUrl.redactText(String(detail)).trim().split(/\r?\n/).slice(-3).join(" / ");
  return r;
}

const MAX_ATTEMPTS = 3;

// commitPlan(plansDir, R, target, t, deadline) -> {parent, lease, message} — how this attempt's
// commit is built on R. Within one turn, R itself (plan-sync's own commit of this turn) is
// replaced: the new commit takes R's parent and is pushed under a lease on R. Otherwise it is
// appended on R. Without a turn the message is the legacy one-line subject.
function commitPlan(plansDir, R, target, t, deadline) {
  if (!t.turn) return { parent: null, lease: null, message: `plan-sync: ${target.rel}` };
  const X = t.forceRejected || t.remoteRejected ? null : turnBaseOf(plansDir, R, t.turn, { deadline });
  const baseRels = X ? X.rels : [];
  const base = X ? X.base : turnStartOf(plansDir, R, t.turn, { deadline });
  const message = (changed) => {
    const rels = baseRels.concat(changed);
    return formatTurnMessage({ sid: t.turn.sid, turnId: t.turn.turnId, base, rels: rels.length ? rels : [target.rel] });
  };
  return { parent: X ? X.parent : null, lease: X ? R : null, message };
}

// publishOnRemoteTip -> {push, commit, remoteRejected}: every commit is built on the remote tip R
// (origin/main; fetched on a retry or when absent) from the target plus the allowlist-filtered
// local-only entries, add/overwrite only; CAS from L, then push; a non-fast-forward fetches and
// rebuilds. A no-op (overlay == R) is trusted only against a fetched R (one extra attempt).
// A replacement is pushed under its lease: a miss fetches and rebuilds; a remote refusing the
// forced update gets an append, at no cost to the budget. Design: docs/architecture/claude-code/plan-sync.md.
// pred (required) is sendPredicate(plansDir, destination): carried entries pass it in full.
function publishOnRemoteTip(plansDir, target, deadline, pred, turnOpts) {
  if (!pred || typeof pred.isSendable !== "function" || typeof pred.keepCarried !== "function") {
    throw new Error("publishOnRemoteTip: send predicate required");
  }
  const t = Object.assign({ turn: null, forceRejected: false, remoteRejected: false }, turnOpts);
  const done = (r) => Object.assign(r, { remoteRejected: t.remoteRejected });
  let last = { status: 1, stderr: "cas-conflict", timedOut: false };
  let maxAttempts = MAX_ATTEMPTS;
  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    let R = G.revParse(plansDir, G.ORIGIN_MAIN_REF, { deadline });
    const fetched = attempt > 0 || !R;
    if (fetched) {
      const f = G.fetchMain(plansDir, { deadline });
      if (f.status !== 0) return done({ push: f, commit: null });
      R = G.revParse(plansDir, G.ORIGIN_MAIN_REF, { deadline });
      if (!R) return done({ push: { status: 1, stderr: "origin/main missing after fetch", timedOut: false }, commit: null });
    }
    const L = G.revParse(plansDir, G.MAIN_REF, { deadline });
    const carried = pred.keepCarried(G.carriedEntries(plansDir, R, L, pred.isSendable, { deadline }));
    const entries = G.mergeEntries([target], carried);
    const plan = commitPlan(plansDir, R, target, t, deadline);
    const c = G.overlayCommit(plansDir, R, entries, { deadline, parent: plan.parent, message: plan.message });
    if (!c.ok) return done({ push: { status: 1, stderr: c.error, timedOut: false }, commit: null, reason: "commit-failed" });
    if (c.commit !== L && !G.casUpdate(plansDir, G.MAIN_REF, c.commit, L, { deadline })) {
      last = { status: 1, stderr: "cas-conflict", timedOut: false };
      continue;
    }
    if (c.commit === R) {
      if (fetched) return done({ push: { status: 0, stderr: "", timedOut: false }, commit: R });
      maxAttempts += 1;
      continue;
    }
    if (plan.lease) {
      last = pushMainWithLease(plansDir, plan.lease, { deadline });
      const verdict = classifyLeasePush(last);
      if (verdict === "ok") return done({ push: last, commit: c.commit, replaced: true });
      if (verdict === "lease-miss") continue;
      if (verdict === "remote-rejected") {
        t.remoteRejected = true;
        maxAttempts += 1;
        continue;
      }
      return done({ push: last, commit: null });
    }
    last = G.pushMain(plansDir, { deadline });
    if (last.status === 0) return done({ push: last, commit: c.commit });
    if (last.timedOut || !G.isNonFastForward(last)) return done({ push: last, commit: null });
  }
  return done({ push: last, commit: null });
}

// alreadyPublishedResult -> the result of a write that never reached the network: pushed when
// origin/main (as last seen) already holds the exact bytes, failed(reason, detail) otherwise.
function alreadyPublishedResult(plansDir, absPath, cp, o, reason, detail) {
  const url = publishedBlobUrl(plansDir, absPath, o.deps);
  if (url) return { status: "pushed", url };
  if (remoteUrl.resolveRemoteTarget(cp.pushUrl).type === "unknown" && remoteHoldsBytes(plansDir, absPath)) {
    return { status: "pushed", reason: "unknown-forge" };
  }
  return failed(reason, detail);
}

function remoteHoldsBytes(plansDir, absPath) {
  try {
    const remoteBlob = G.blobAt(plansDir, G.ORIGIN_MAIN_REF, path.basename(path.resolve(absPath)));
    const bytes = readVerifiedRegularFile(absPath);
    return Boolean(remoteBlob && bytes && G.hashBytesId(plansDir, bytes) === remoteBlob);
  } catch (_) {
    return false;
  }
}

// turnLinksFor(plansDir, target, commit, turn) -> {kind: "compare", urls} | {kind: "commits", urls, more}
// | null — the links that show one turn's change when its commits could not be folded into one.
const MAX_COMMIT_LINKS = 5;
function turnLinksFor(plansDir, target, commit, turn, deadline) {
  const range = turnRange(plansDir, commit, turn, { deadline });
  if (!range || range.turnCommits.length === 0) return null;
  if (!range.interleaved) {
    const url = remoteUrl.compareUrlFor(target, range.base, range.turnCommits[0]);
    return url ? { kind: "compare", urls: [url] } : null;
  }
  const oldest = range.turnCommits.slice().reverse();
  const urls = oldest.slice(0, MAX_COMMIT_LINKS).map((sha) => remoteUrl.commitUrlFor(target, sha));
  if (urls.some((u) => !u)) return null;
  return { kind: "commits", urls, more: Math.max(0, oldest.length - MAX_COMMIT_LINKS) };
}

const VALID_TURN = (t) => Boolean(t && typeof t.sid === "string" && t.sid && typeof t.turnId === "string" && /^[0-9a-f]{32}$/.test(t.turnId));

// syncPlanFile(plansDir, absPath, {budgetMs, deps, turn, now}) ->
//   {status: "pushed"|"off"|"not-provisioned"|"skipped"|"failed", url?, reason?, turnLinks?}
// turn {sid, turnId} folds the writes of one user prompt into one commit (turn-commit.js).
function syncPlanFile(plansDir, absPath, opts) {
  const o = opts || {};
  const now = typeof o.now === "function" ? o.now : Date.now;
  const turn = VALID_TURN(o.turn) ? { sid: o.turn.sid, turnId: o.turn.turnId } : null;
  const deadline = Date.now() + (o.budgetMs || DEFAULT_BUDGET_MS);
  let env;
  try { env = resolveRemoteUrl(); } catch (e) { return failed("env-load-failed", e && e.message); }
  if (!env.value) return { status: "off" };
  if (env.loadFailed) return failed("env-load-failed");
  if (!isSyncTarget(plansDir, absPath)) return { status: "skipped" };
  const hostState = readProjectHostState(absPath, env.value);
  if (hostState === "host-mismatch" || hostState === "no-project-host") return { status: "skipped", reason: hostState };
  if (hostState !== "match") return { status: "skipped" };
  if (!isRegularFile(absPath)) return { status: "skipped", reason: "not-regular-file" };
  const cp = checkProvisioned(plansDir, env.value, o.deps);
  if (!cp.ok) return { status: "not-provisioned", reason: cp.reason };
  const state = RS.readRemoteState(plansDir, cp.pushUrl);
  if (state.authBackoffUntil > now()) return alreadyPublishedResult(plansDir, absPath, cp, o, "auth-backoff");
  if (G.gitOut(plansDir, ["symbolic-ref", "-q", "HEAD"], { deadline }) !== G.MAIN_REF) {
    return { status: "not-provisioned", reason: "detached-or-branch" };
  }

  const rel = path.basename(path.resolve(absPath));
  const bytes = readVerifiedRegularFile(absPath);
  if (!bytes) return { status: "skipped", reason: "not-regular-file" };
  const blob = G.hashBytes(plansDir, bytes, { deadline });
  if (!blob) return failed("hash-failed");
  const target = { rel, blob };

  const pub = publishOnRemoteTip(plansDir, target, deadline, sendPredicate(plansDir, cp.pushUrl),
    { turn, forceRejected: state.forceRejected });
  const { push, commit } = pub;
  if (pub.reason) return failed(pub.reason, push.stderr);
  if (push.status !== 0 || !commit) {
    const reason = push.stderr === "cas-conflict" ? "cas-conflict" : G.classifyFailure(push);
    if (reason !== "auth") return failed(reason, push.stderr);
    RS.recordAuthBackoff(plansDir, cp.pushUrl, now() + RS.AUTH_BACKOFF_MS);
    return alreadyPublishedResult(plansDir, absPath, cp, o, "auth", push.stderr);
  }
  G.setRef(plansDir, G.ORIGIN_MAIN_REF, commit, { deadline });
  let forceRejected = state.forceRejected;
  if (pub.remoteRejected) {
    RS.recordForceRejected(plansDir, cp.pushUrl);
    forceRejected = true;
  }

  const url = publishedBlobUrl(plansDir, absPath, o.deps);
  const forge = remoteUrl.resolveRemoteTarget(cp.pushUrl);
  let result;
  if (url) result = { status: "pushed", url };
  else if (forge.type === "unknown") return { status: "pushed", reason: "unknown-forge" };
  else return failed("verify-failed", "origin/main does not hold the written content");
  if (forceRejected && turn) {
    const links = turnLinksFor(plansDir, forge, commit, turn, deadline);
    if (links) result.turnLinks = links;
  }
  return result;
}

// publishedBlobUrl(plansDir, absPath, deps?) -> string | null — no network. A URL only when
// the provisioned push URL is a known forge, the project-host record does not rule the plan
// out (a mismatch or no-host record never gets one), and origin/main:<rel> is byte-identical
// to the file — so without a record a URL appears only for content already at the destination.
function publishedBlobUrl(plansDir, absPath, deps) {
  try {
    const env = resolveRemoteUrl();
    if (!env.value || !isSyncTarget(plansDir, absPath) || !isRegularFile(absPath)) return null;
    const cp = checkProvisioned(plansDir, env.value, deps);
    if (!cp.ok) return null;
    const target = remoteUrl.resolveRemoteTarget(cp.pushUrl);
    if (target.type === "unknown") return null;
    const state = readProjectHostState(absPath, cp.pushUrl);
    if (state !== "match" && state !== "missing") return null;
    const rel = path.basename(path.resolve(absPath));
    const remoteBlob = G.blobAt(plansDir, G.ORIGIN_MAIN_REF, rel);
    const bytes = readVerifiedRegularFile(absPath);
    if (!remoteBlob || !bytes) return null;
    const localBlob = G.hashBytesId(plansDir, bytes);
    if (!localBlob || remoteBlob !== localBlob) return null;
    return remoteUrl.blobUrlFor(target, "main", rel);
  } catch (_) {
    return null;
  }
}

module.exports = { syncPlanFile, publishedBlobUrl, readVerifiedRegularFile };
