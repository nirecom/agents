"use strict";
// hooks/lib/plan-sync/remote-url.js
// Remote-URL helpers for plan-sync: the allowlist (the same SCHEME / SCP shapes as
// session-sync-init, judged against the shared fixture table), userinfo redaction,
// GitHub owner/repo parsing and blob-URL rendering.
const { parseOriginOwnerRepo, redactUserinfo } = require("../parse-remote-url");

// Verbatim JS copies of _URL_RE_SCHEME / _URL_RE_SCP in install/linux/session-sync-init.sh.
const URL_RE_SCHEME = /^(https|ssh|git):\/\/([^/@]+@)?(\[[0-9A-Fa-f:]*[0-9A-Fa-f][0-9A-Fa-f:]*\]|[A-Za-z0-9][A-Za-z0-9.-]*)(:[0-9]+)?(\/.*)?$/;
const URL_RE_SCP = /^[A-Za-z0-9_][A-Za-z0-9_.-]*@[A-Za-z0-9][A-Za-z0-9.-]*:[^:].*$/;

// A JS `.` does not match a line break while the bash ERE does; refusing control
// characters outright keeps one URL one git argv element on every engine.
const CONTROL_RE = /[\r\n\0]/;

function isAllowedRemoteUrl(url) {
  if (typeof url !== "string" || url.length === 0 || CONTROL_RE.test(url)) return false;
  return URL_RE_SCHEME.test(url) || URL_RE_SCP.test(url);
}

// parseGitHubRemote(url) -> {owner, repo} | null. Any host other than github.com is null.
function parseGitHubRemote(url) {
  if (typeof url !== "string" || CONTROL_RE.test(url)) return null;
  const p = parseOriginOwnerRepo(url);
  return p.ok ? { owner: p.owner, repo: p.repo } : null;
}

// Userinfo is hidden when it carries a password (":") or rides on http(s), where it is
// usually a token; ssh://git@host stays readable because "git" is no secret, so the
// keep-or-hide decision stays here and only the masking itself is redactUserinfo's.
function redactOne(url) {
  return url.replace(/^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^/@\s]+)@/, (whole, scheme, info) => {
    if (info.includes(":") || /^https?$/i.test(scheme)) return redactUserinfo(whole);
    return whole;
  });
}

function redactUrl(url) {
  if (typeof url !== "string") return "";
  return redactOne(url);
}

// redactText(text) — the same redaction applied to every URL inside free text (git stderr).
function redactText(text) {
  if (typeof text !== "string") return "";
  return text.replace(/[A-Za-z][A-Za-z0-9+.-]*:\/\/[^/@\s]+@/g, (m) => redactOne(m));
}

// The owner placeholder .env.example ships; a copied-but-unedited value must never provision.
const PLACEHOLDER_RE = /YOUR_USERNAME/i;

function isPlaceholderUrl(url) {
  return typeof url === "string" && PLACEHOLDER_RE.test(url);
}

function blobUrlFor(gh, branch, relPath) {
  const segs = String(relPath).split("/").map(encodeURIComponent).join("/");
  return `https://github.com/${gh.owner}/${gh.repo}/blob/${encodeURIComponent(branch)}/${segs}`;
}

module.exports = { isAllowedRemoteUrl, isPlaceholderUrl, parseGitHubRemote, redactUrl, redactText, blobUrlFor };
