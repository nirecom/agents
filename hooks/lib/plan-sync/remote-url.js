"use strict";
// hooks/lib/plan-sync/remote-url.js
// Remote-URL helpers for plan-sync: the allowlist (the same SCHEME / SCP shapes as
// session-sync-init, judged against the shared fixture table), userinfo redaction, and
// the one resolver (resolveRemoteTarget) behind the forge type, the host equivalence of
// a project origin and the destination (sameRemoteHost) and blob-URL rendering.
const {
  extractHost, extractProjectPath, redactUserinfo, isValidOwner, isValidRepo, FORGE_HOST_TYPES,
} = require("../parse-remote-url");

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

// GitHub's alternate SSH endpoint serves the same repositories as github.com.
const HOST_ALIASES = Object.freeze({ "ssh.github.com": "github.com" });
const DEFAULT_PORTS = Object.freeze({ http: 80, https: 443 });

function cleanHost(v) {
  return typeof v === "string" ? v.trim().toLowerCase() : "";
}

// gitlabSettings() -> {gitlabHost, gitlabSshHost} — the agents config .env first, then the
// caller's own export (the module-load snapshot, so a project .env.local overlay that
// loadDefaultEnv injected into process.env is never read).
function gitlabSettings() {
  const le = require("../load-env");
  let file = {};
  try { file = le.readDefaultEnvFile() || {}; } catch (_) { file = {}; }
  const env = le.getPristineProcessEnv();
  const pick = (k) => cleanHost(file[k]) || cleanHost(env[k]);
  return { gitlabHost: pick("GITLAB_HOSTNAME"), gitlabSshHost: pick("GITLAB_SSH_HOSTNAME") };
}

// schemeAndPort(url) -> {scheme, port} — scheme "ssh" for the SCP form; port null when absent.
function schemeAndPort(url) {
  const m = url.match(/^([A-Za-z][A-Za-z0-9+.-]*):\/\/(?:[^@/]+@)?(?:\[[^\]]*\]|[^/:]+)(?::(\d+))?/);
  if (!m) return { scheme: "ssh", port: null };
  return { scheme: m[1].toLowerCase(), port: m[2] ? Number(m[2]) : null };
}

const isHttp = (scheme) => scheme === "http" || scheme === "https";

// resolveRemoteTarget(url, settings?) -> {type: "github"|"gitlab"|"unknown", host, project,
// scheme, port} — host is the lowercased web host (ssh.github.com and the declared GitLab SSH
// alias mapped to their web host); null host for an empty URL, a local path or garbage.
function resolveRemoteTarget(url, settings) {
  const none = { type: "unknown", host: null, project: null, scheme: null, port: null };
  if (typeof url !== "string" || url.trim() === "" || CONTROL_RE.test(url)) return none;
  const raw = extractHost(url.trim());
  if (!raw) return none;
  const s = settings || gitlabSettings();
  let host = raw.toLowerCase();
  if (Object.prototype.hasOwnProperty.call(HOST_ALIASES, host)) host = HOST_ALIASES[host];
  else if (s.gitlabSshHost && s.gitlabHost && host === s.gitlabSshHost) host = s.gitlabHost;
  const { scheme, port } = schemeAndPort(url.trim());
  const project = extractProjectPath(url.trim());
  let type = Object.prototype.hasOwnProperty.call(FORGE_HOST_TYPES, host) ? FORGE_HOST_TYPES[host] : "unknown";
  if (s.gitlabHost && host === s.gitlabHost) type = "gitlab";
  if (!project) type = "unknown";
  if (type === "github") {
    const segs = project.split("/");
    if (segs.length !== 2 || !isValidOwner(segs[0]) || !isValidRepo(segs[1])) type = "unknown";
  }
  return { type, host, project, scheme, port };
}

function effectivePort(t) {
  return typeof t.port === "number" ? t.port : DEFAULT_PORTS[t.scheme];
}

// sameTargetHost(ta, tb) — two resolved targets (or stored {host, scheme, port}) share a web
// host; when both sides are HTTP(S) the scheme and the effective port must match too.
function sameTargetHost(ta, tb) {
  if (!ta || !tb || !ta.host || !tb.host || ta.host !== tb.host) return false;
  if (isHttp(ta.scheme) && isHttp(tb.scheme)) {
    return ta.scheme === tb.scheme && effectivePort(ta) === effectivePort(tb);
  }
  return true;
}

// sameRemoteHost(a, b) — sameTargetHost on two remote URLs. The forge type is never compared.
function sameRemoteHost(a, b, settings) {
  const s = settings || gitlabSettings();
  return sameTargetHost(resolveRemoteTarget(a, s), resolveRemoteTarget(b, s));
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

// fillPlaceholder(url, owner) -> url with its first YOUR_USERNAME replaced by owner.
function fillPlaceholder(url, owner) {
  return String(url).replace(PLACEHOLDER_RE, () => owner);
}

// blobUrlFor(target, branch, relPath) -> string | null — the web page of relPath on branch;
// null for an unknown forge. An HTTP(S) destination keeps its scheme and non-default port.
function blobUrlFor(target, branch, relPath) {
  if (!target || !target.host || !target.project) return null;
  if (target.type !== "github" && target.type !== "gitlab") return null;
  let origin = `https://${target.host}`;
  if (isHttp(target.scheme)) {
    const port = typeof target.port === "number" && target.port !== DEFAULT_PORTS[target.scheme] ? `:${target.port}` : "";
    origin = `${target.scheme}://${target.host}${port}`;
  }
  const segs = String(relPath).split("/").map(encodeURIComponent).join("/");
  const sep = target.type === "gitlab" ? "/-/blob/" : "/blob/";
  return `${origin}/${target.project}${sep}${encodeURIComponent(branch)}/${segs}`;
}

module.exports = {
  isAllowedRemoteUrl,
  isPlaceholderUrl,
  fillPlaceholder,
  gitlabSettings,
  resolveRemoteTarget,
  sameTargetHost,
  sameRemoteHost,
  redactUrl,
  redactText,
  blobUrlFor,
};
