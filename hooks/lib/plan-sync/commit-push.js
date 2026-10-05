"use strict";
// hooks/lib/plan-sync/commit-push.js
// syncPlanFile: publish one plan file to origin/main by plumbing + CAS, always building
// add/overwrite-only on the remote tip from allowlisted entries. publishedBlobUrl: the
// network-free "is this exact content on origin/main" check behind the blob URL.
const path = require("path");
const remoteUrl = require("./remote-url");
const { isSyncTarget, isSyncTargetName } = require("./allowlist");
const { resolveRemoteUrl, checkProvisioned } = require("./provision");
const { isRegularFile, readVerifiedRegularFile } = require("./local-file");
const G = require("./git");

const DEFAULT_BUDGET_MS = 20000;

function failed(reason, detail) {
  const r = { status: "failed", reason };
  if (detail) r.detail = remoteUrl.redactText(String(detail)).trim().split(/\r?\n/).slice(-3).join(" / ");
  return r;
}

const MAX_ATTEMPTS = 3;

// publishOnRemoteTip -> {push, commit}: every published commit is built on the remote tip R
// (origin/main; fetched first on a retry or when absent) from the target plus the
// allowlist-filtered local-only entries — local main's own tree is never pushed as-is, so
// nothing it tracks beyond the allowlist can leave the machine. Nothing is deleted and the
// local side wins. CAS from L, then push; a non-fast-forward fetches and rebuilds.
// A no-op (overlay == R) is trusted only when R was fetched in that attempt: against an
// unfetched, possibly stale R it fetches and rebuilds instead (that one local-only pass
// gets an extra attempt, so the post-fetch retry budget stays MAX_ATTEMPTS - 1).
function publishOnRemoteTip(plansDir, target, deadline) {
  let last = { status: 1, stderr: "cas-conflict", timedOut: false };
  let maxAttempts = MAX_ATTEMPTS;
  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    let R = G.revParse(plansDir, G.ORIGIN_MAIN_REF, { deadline });
    const fetched = attempt > 0 || !R;
    if (fetched) {
      const f = G.fetchMain(plansDir, { deadline });
      if (f.status !== 0) return { push: f, commit: null };
      R = G.revParse(plansDir, G.ORIGIN_MAIN_REF, { deadline });
      if (!R) return { push: { status: 1, stderr: "origin/main missing after fetch", timedOut: false }, commit: null };
    }
    const L = G.revParse(plansDir, G.MAIN_REF, { deadline });
    const entries = G.mergeEntries([target], G.carriedEntries(plansDir, R, L, isSyncTargetName, { deadline }));
    const c = G.overlayCommit(plansDir, R, entries, { deadline, message: `plan-sync: ${target.rel}` });
    if (!c.ok) return { push: { status: 1, stderr: c.error, timedOut: false }, commit: null, reason: "commit-failed" };
    if (c.commit !== L && !G.casUpdate(plansDir, G.MAIN_REF, c.commit, L, { deadline })) {
      last = { status: 1, stderr: "cas-conflict", timedOut: false };
      continue;
    }
    if (c.commit === R) {
      if (fetched) return { push: { status: 0, stderr: "", timedOut: false }, commit: R };
      maxAttempts = MAX_ATTEMPTS + 1;
      continue;
    }
    last = G.pushMain(plansDir, { deadline });
    if (last.status === 0) return { push: last, commit: c.commit };
    if (last.timedOut || !G.isNonFastForward(last)) return { push: last, commit: null };
  }
  return { push: last, commit: null };
}

// syncPlanFile(plansDir, absPath, {budgetMs, deps}) ->
//   {status: "pushed"|"off"|"not-provisioned"|"skipped"|"failed", url?, reason?}
function syncPlanFile(plansDir, absPath, opts) {
  const o = opts || {};
  const deadline = Date.now() + (o.budgetMs || DEFAULT_BUDGET_MS);
  let env;
  try { env = resolveRemoteUrl(); } catch (e) { return failed("env-load-failed", e && e.message); }
  if (!env.value) return { status: "off" };
  if (env.loadFailed) return failed("env-load-failed");
  if (!isSyncTarget(plansDir, absPath)) return { status: "skipped" };
  if (!isRegularFile(absPath)) return { status: "skipped", reason: "not-regular-file" };
  const cp = checkProvisioned(plansDir, env.value, o.deps);
  if (!cp.ok) return { status: "not-provisioned", reason: cp.reason };
  if (G.gitOut(plansDir, ["symbolic-ref", "-q", "HEAD"], { deadline }) !== G.MAIN_REF) {
    return { status: "not-provisioned", reason: "detached-or-branch" };
  }

  const rel = path.basename(path.resolve(absPath));
  const bytes = readVerifiedRegularFile(absPath);
  if (!bytes) return { status: "skipped", reason: "not-regular-file" };
  const blob = G.hashBytes(plansDir, bytes, { deadline });
  if (!blob) return failed("hash-failed");
  const target = { rel, blob };

  const pub = publishOnRemoteTip(plansDir, target, deadline);
  const { push, commit } = pub;
  if (pub.reason) return failed(pub.reason, push.stderr);
  if (push.status !== 0 || !commit) {
    return failed(push.stderr === "cas-conflict" ? "cas-conflict" : G.classifyFailure(push), push.stderr);
  }
  G.setRef(plansDir, G.ORIGIN_MAIN_REF, commit, { deadline });

  const url = publishedBlobUrl(plansDir, absPath, o.deps);
  if (url) return { status: "pushed", url };
  if (!remoteUrl.parseGitHubRemote(cp.pushUrl)) return { status: "pushed", reason: "non-github" };
  return failed("verify-failed", "origin/main does not hold the written content");
}

// publishedBlobUrl(plansDir, absPath, deps?) -> string | null — no network. A URL only when
// the provisioned push URL is GitHub's and origin/main:<rel> is byte-identical to the file.
function publishedBlobUrl(plansDir, absPath, deps) {
  try {
    const env = resolveRemoteUrl();
    if (!env.value || !isSyncTarget(plansDir, absPath) || !isRegularFile(absPath)) return null;
    const cp = checkProvisioned(plansDir, env.value, deps);
    if (!cp.ok) return null;
    const gh = remoteUrl.parseGitHubRemote(cp.pushUrl);
    if (!gh) return null;
    const rel = path.basename(path.resolve(absPath));
    const remoteBlob = G.blobAt(plansDir, G.ORIGIN_MAIN_REF, rel);
    const bytes = readVerifiedRegularFile(absPath);
    if (!remoteBlob || !bytes) return null;
    const localBlob = G.hashBytesId(plansDir, bytes);
    if (!localBlob || remoteBlob !== localBlob) return null;
    return remoteUrl.blobUrlFor(gh, "main", rel);
  } catch (_) {
    return null;
  }
}

module.exports = { syncPlanFile, publishedBlobUrl, readVerifiedRegularFile };
