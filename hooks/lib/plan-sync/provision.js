"use strict";
// hooks/lib/plan-sync/provision.js
// The provisioned-repo contract (checkProvisioned, five ordered conditions) and the
// init body (provisionRepo) bin/plan-sync-init wraps. Both judge the remote URL the
// same way, so init's post-check and the hook can never disagree on "provisioned".
// Only provisionRepo asks the codehost for the repo's visibility (a public remote is
// refused before anything is written); checkProvisioned stays network-free.
const fs = require("fs");
const path = require("path");
const remoteUrl = require("./remote-url");
const { renderGitignore, isSyncTargetName } = require("./allowlist");
const G = require("./git");

const INIT_VERSION = 1;
const NETWORK_TIMEOUT_MS = 30000;

function resolveRemoteUrl() {
  const { resolveConfigVar } = require("../load-env");
  return resolveConfigVar("PLAN_SYNC_REMOTE_URL", "");
}

function allowFn(deps) {
  return deps && typeof deps.isAllowedRemoteUrl === "function" ? deps.isAllowedRemoteUrl : remoteUrl.isAllowedRemoteUrl;
}

function visFn(deps) {
  if (deps && typeof deps.repoVisibility === "function") return deps.repoVisibility;
  return (u) => require("../forge-router").resolveCodehostDescriptor(u).repoVisibility(u);
}

function remoteVisibility(url, deps) {
  try { return visFn(deps)(url); } catch (_) { return null; }
}

function listFn(deps) {
  if (deps && typeof deps.listPrivateRepoNames === "function") return deps.listPrivateRepoNames;
  return (u) => require("../forge-router").resolveCodehostDescriptor(u).listPrivateRepoNames();
}

// listedAsPrivate(url, id, deps) — true only when the codehost's private/internal list holds id.
function listedAsPrivate(url, id, deps) {
  let names;
  try { names = listFn(deps)(url); } catch (_) { return false; }
  if (!Array.isArray(names)) return false;
  const want = id.toLowerCase();
  return names.some((n) => typeof n === "string" && n.toLowerCase() === want);
}

// effectivePushUrl — the URL git really pushes to, after pushurl / pushInsteadOf / insteadOf.
function effectivePushUrl(plansDir) {
  return G.gitOut(plansDir, ["remote", "get-url", "--push", "origin"]);
}

function dotGitKind(plansDir) {
  let st;
  try { st = fs.lstatSync(path.join(plansDir, ".git")); } catch (_) { return "absent"; }
  if (st.isSymbolicLink() || !st.isDirectory()) return "other";
  return "dir";
}

// rewriteFree(plansDir, raw) -> pushUrl | null — condition (d): fetch URL, push URL and
// the raw URL agree, and no explicit pushurl exists. Never replaceable through deps.
function rewriteFree(plansDir, raw) {
  const fetchUrl = G.gitOut(plansDir, ["remote", "get-url", "origin"]);
  const pushUrl = effectivePushUrl(plansDir);
  const pushurls = G.runGit(plansDir, ["config", "--get-all", "remote.origin.pushurl"]);
  if (fetchUrl !== raw || pushUrl !== raw) return null;
  if (pushurls.status === 0 && pushurls.stdout.trim() !== "") return null;
  return pushUrl;
}

function gitignoreMatches(plansDir) {
  let bytes;
  try { bytes = fs.readFileSync(path.join(plansDir, ".gitignore")); } catch (_) { return false; }
  return bytes.equals(Buffer.from(renderGitignore(), "utf8"));
}

// checkProvisioned(plansDir, url, deps?) -> {ok: true, pushUrl} | {ok: false, reason}
function checkProvisioned(plansDir, url, deps) {
  if (typeof plansDir !== "string" || !plansDir || dotGitKind(plansDir) !== "dir") return { ok: false, reason: "no-repo" };
  const ver = G.gitOut(plansDir, ["config", "--local", "--get", "plansync.version"]);
  if (ver !== String(INIT_VERSION)) return { ok: false, reason: "version-mismatch" };
  const raw = G.gitOut(plansDir, ["config", "--get", "remote.origin.url"]);
  if (!raw || raw !== url || !allowFn(deps)(raw)) return { ok: false, reason: "remote-mismatch" };
  const pushUrl = rewriteFree(plansDir, raw);
  if (!pushUrl) return { ok: false, reason: "url-rewritten" };
  if (!gitignoreMatches(plansDir)) return { ok: false, reason: "gitignore-drift" };
  return { ok: true, pushUrl };
}

function fail(reason, notes, detail) {
  if (detail) notes.push(remoteUrl.redactText(String(detail)).trim().split(/\r?\n/).slice(-3).join(" / "));
  return { ok: false, reason, notes };
}

function ensureRepo(plansDir) {
  if (dotGitKind(plansDir) === "absent") {
    fs.mkdirSync(plansDir, { recursive: true });
    const init = G.runGit(plansDir, ["init", "-q"]);
    if (init.status !== 0) return init.stderr || "git init failed";
  }
  // No checkout and no index exist, so pointing HEAD at main moves nothing on disk.
  const head = G.runGit(plansDir, ["symbolic-ref", "HEAD", G.MAIN_REF]);
  if (head.status !== 0) return head.stderr || "symbolic-ref failed";
  for (const [k, v] of [["core.hooksPath", G.NULL_DEV], ["core.fsmonitor", "false"], ["core.autocrlf", "false"]]) {
    const r = G.runGit(plansDir, ["config", "--local", k, v]);
    if (r.status !== 0) return r.stderr || `config ${k} failed`;
  }
  return null;
}

function writeGitignore(plansDir) {
  const p = path.join(plansDir, ".gitignore");
  if (!gitignoreMatches(plansDir)) fs.writeFileSync(p, renderGitignore());
}

function ensureOrigin(plansDir, url) {
  const has = G.runGit(plansDir, ["config", "--get", "remote.origin.url"]).status === 0;
  const r = G.runGit(plansDir, has ? ["remote", "set-url", "origin", url] : ["remote", "add", "origin", url]);
  if (r.status !== 0) return r.stderr || "remote setup failed";
  // remote.origin.pushurl is owned by init: an explicit pushurl would split push from fetch.
  G.runGit(plansDir, ["config", "--local", "--unset-all", "remote.origin.pushurl"]);
  return null;
}

// converge(plansDir) -> {ok, commit, push, error?} — the commit to publish, always a fresh
// root or the remote tip plus allowlist-filtered local entries; a local ref is never pushed as-is.
function converge(plansDir, opts) {
  const ls = G.runGit(plansDir, ["ls-remote", "--heads", "origin", G.MAIN_REF], opts);
  if (ls.status !== 0) return { ok: false, reason: G.classifyFailure(ls) === "auth" ? "auth" : "remote-unreachable", error: ls.stderr };
  const L = G.revParse(plansDir, G.MAIN_REF);
  if (ls.stdout.trim() === "") {
    const gi = G.hashBytes(plansDir, renderGitignore());
    if (!gi) return { ok: false, reason: "commit-failed", error: "hash-object failed" };
    const carried = L ? G.treeEntries(plansDir, L, isSyncTargetName) : [];
    const c = G.overlayCommit(plansDir, null, G.mergeEntries([{ rel: ".gitignore", blob: gi }], carried),
      Object.assign({ message: "plan-sync: initial" }, opts));
    if (!c.ok) return { ok: false, reason: "commit-failed", error: c.error };
    return { ok: true, commit: c.commit, push: true, local: L };
  }
  const f = G.fetchMain(plansDir, opts);
  if (f.status !== 0) return { ok: false, reason: "fetch-failed", error: f.stderr };
  const R = G.revParse(plansDir, G.ORIGIN_MAIN_REF);
  if (!R) return { ok: false, reason: "fetch-failed", error: "origin/main missing after fetch" };
  const entries = G.carriedEntries(plansDir, R, L, isSyncTargetName);
  const c = G.overlayCommit(plansDir, R, entries, Object.assign({ message: "plan-sync: rebuild onto origin/main" }, opts));
  if (!c.ok) return { ok: false, reason: "commit-failed", error: c.error };
  return { ok: true, commit: c.commit, push: c.commit !== R, local: L };
}

// fixGitignore(plansDir, commit) -> {ok, commit, changed} — the remote's .gitignore re-rendered.
function fixGitignore(plansDir, commit, opts) {
  const gi = G.hashBytes(plansDir, renderGitignore());
  if (!gi) return { ok: false, error: "hash-object failed" };
  if (G.blobAt(plansDir, commit, ".gitignore") === gi) return { ok: true, commit, changed: false };
  const c = G.overlayCommit(plansDir, commit, [{ rel: ".gitignore", blob: gi }],
    Object.assign({ message: "plan-sync: render .gitignore" }, opts));
  return c.ok ? { ok: true, commit: c.commit, changed: true } : { ok: false, error: c.error };
}

function publish(plansDir, local, commit) {
  if (local !== commit && !G.casUpdate(plansDir, G.MAIN_REF, commit, local)) {
    return { ok: false, reason: "main-moved", error: "refs/heads/main changed during init; re-run" };
  }
  return { ok: true };
}

// provisionRepo(plansDir, url, deps?) -> {ok, reason?, notes[]}
function provisionRepo(plansDir, url, deps) {
  const notes = [];
  const shown = remoteUrl.redactUrl(String(url || ""));
  if (!url || !allowFn(deps)(url)) return fail("url-denied", notes, `remote URL refused by the allowlist: ${shown}`);
  if (remoteUrl.isPlaceholderUrl(url)) return fail("url-placeholder", notes, `replace the YOUR_USERNAME placeholder in ${shown}`);
  const gh = remoteUrl.parseGitHubRemote(url);
  if (!gh) notes.push("non-GitHub remote: no blob URL can be shown; breadcrumbs fall back to the local path");
  const vis = remoteVisibility(url, deps);
  if (vis === "public") {
    return fail("remote-public", notes, `remote repository is public; PLAN_SYNC_REMOTE_URL must point at a private repo: ${shown}`);
  }
  if (vis !== "private" && vis !== "internal") {
    notes.push("remote visibility could not be verified (check gh/glab install and auth); confirm the repo is private yourself");
  }
  if (dotGitKind(plansDir) === "other") return fail("git-not-directory", notes, `${path.join(plansDir, ".git")} is a file or symlink; refusing to touch it`);

  const opts = { timeoutMs: NETWORK_TIMEOUT_MS };
  let err = ensureRepo(plansDir);
  if (err) return fail("init-failed", notes, err);
  writeGitignore(plansDir);
  err = ensureOrigin(plansDir, url);
  if (err) return fail("remote-setup-failed", notes, err);
  if (!rewriteFree(plansDir, url)) {
    return fail("url-rewritten", notes,
      "git rewrites this URL (insteadOf / pushInsteadOf / pushurl); put the rewritten form in PLAN_SYNC_REMOTE_URL");
  }

  const cv = converge(plansDir, opts);
  if (!cv.ok) return fail(cv.reason, notes, cv.error);
  const gi = fixGitignore(plansDir, cv.commit, opts);
  if (!gi.ok) return fail("commit-failed", notes, gi.error);
  const commit = gi.commit;
  const pub = publish(plansDir, cv.local, commit);
  if (!pub.ok) return fail(pub.reason, notes, pub.error);
  if (cv.push || gi.changed) {
    const p = G.pushMain(plansDir, opts);
    if (p.status !== 0) return fail(G.classifyFailure(p), notes, p.stderr);
  }
  G.setRef(plansDir, G.ORIGIN_MAIN_REF, commit);

  const v = G.runGit(plansDir, ["config", "--local", "plansync.version", String(INIT_VERSION)]);
  if (v.status !== 0) return fail("init-failed", notes, v.stderr);
  const post = checkProvisioned(plansDir, url, deps);
  if (!post.ok) return fail(post.reason, notes, "post-init check failed");
  const id = gh ? `${gh.owner}/${gh.repo}` : "the remote's repo identifier";
  if (!gh || !listedAsPrivate(url, id, deps)) {
    notes.push(`add ${id} to .private-info-blocklist so public outbound (commits, PRs, issues) blocks it mechanically`);
  }
  return { ok: true, notes };
}

module.exports = {
  INIT_VERSION,
  resolveRemoteUrl,
  effectivePushUrl,
  checkProvisioned,
  provisionRepo,
};
