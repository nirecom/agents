"use strict";
// hooks/lib/plan-sync/project-host.js
// The project-host record and the send predicate. When a plan is written, the host of the
// project it was written for (the hook input's cwd origin) is recorded next to it as
// <sid>-note-project-host-<stage>.json; a plan leaves the machine only when its name is a
// sync target AND that record's host is the destination's host. The record holds the web
// host (and scheme/port for HTTP(S)) or "no host" — never the origin URL itself.
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { parsePlansEntry, getPlansArtifactPath, syncedArtifactStage } = require("../plans-artifact-registry");
const { toWindowsPath } = require("../branch-diff");
const { isSyncTargetName } = require("./allowlist");
const remoteUrl = require("./remote-url");
const { readVerifiedRegularFile } = require("./local-file");
const G = require("./git");

const RECORD_VERSION = 1;
const ORIGIN_TIMEOUT_MS = 5000;

// recordPathFor(planAbs) -> path | null — <sid>-<stage>.md -> <sid>-note-project-host-<stage>.json,
// for every synced artifact of the registry (intent / outline / detail / session-progress).
function recordPathFor(planAbs) {
  if (typeof planAbs !== "string" || !planAbs) return null;
  const abs = path.resolve(toWindowsPath(planAbs));
  const stage = syncedArtifactStage(path.basename(abs));
  if (!stage) return null;
  const parsed = parsePlansEntry(path.basename(abs));
  try {
    return getPlansArtifactPath(parsed.sid, "note", { topic: `project-host-${stage}`, ext: "json", plansDir: path.dirname(abs) });
  } catch (_) {
    return null;
  }
}

// originTarget(cwd) -> {host, scheme, port} | null — every URL of the origin git resolves in
// cwd (insteadOf applied) must be on one host; no cwd, no repo, no origin or a split -> null.
function originTarget(cwd) {
  if (typeof cwd !== "string" || cwd.trim() === "") return null;
  const dir = toWindowsPath(cwd);
  try { if (!fs.statSync(dir).isDirectory()) return null; } catch (_) { return null; }
  const r = G.runGit(dir, ["remote", "get-url", "--all", "origin"], { timeoutMs: ORIGIN_TIMEOUT_MS });
  if (r.status !== 0) return null;
  const urls = r.stdout.split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
  if (urls.length === 0) return null;
  const settings = remoteUrl.gitlabSettings();
  const targets = urls.map((u) => remoteUrl.resolveRemoteTarget(u, settings));
  if (!targets.every((t) => remoteUrl.sameTargetHost(targets[0], t))) return null;
  const t = targets[0];
  return { host: t.host, scheme: t.scheme, port: typeof t.port === "number" ? t.port : null };
}

// recordProjectHost(planAbs, cwd|null) -> {ok: true, path} | {ok: false, error} — atomic
// (temp file + rename). On failure the old record is removed so no stale verdict survives.
function recordProjectHost(planAbs, cwd) {
  const file = recordPathFor(planAbs);
  if (!file) return { ok: false, error: "plan file name has no record name" };
  const t = originTarget(cwd);
  const body = t ? Object.assign({ version: RECORD_VERSION }, t) : { version: RECORD_VERSION, host: null };
  const tmp = `${file}.tmp-${process.pid}-${crypto.randomBytes(4).toString("hex")}`;
  try {
    fs.writeFileSync(tmp, `${JSON.stringify(body)}\n`);
    fs.renameSync(tmp, file);
    return { ok: true, path: file };
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch (_) { /* never created */ }
    try { fs.unlinkSync(file); } catch (_) { /* absent or not a file */ }
    return { ok: false, error: String(e && e.message) };
  }
}

// readProjectHostState(planAbs, destUrl) -> "match" | "host-mismatch" | "no-project-host" |
// "missing". An absent, unreadable or malformed record is "missing", never a match.
function readProjectHostState(planAbs, destUrl) {
  const file = recordPathFor(planAbs);
  if (!file) return "missing";
  let rec;
  try { rec = JSON.parse(fs.readFileSync(file, "utf8")); } catch (_) { return "missing"; }
  if (!rec || typeof rec !== "object" || rec.version !== RECORD_VERSION) return "missing";
  if (rec.host === null) return "no-project-host";
  if (typeof rec.host !== "string" || !rec.host) return "missing";
  const dest = remoteUrl.resolveRemoteTarget(destUrl);
  return remoteUrl.sameTargetHost(rec, dest) ? "match" : "host-mismatch";
}

// sendPredicate(plansDir, destUrl) -> {isSendable(rel), keepCarried(entries)} — the one rule
// for every plan that leaves the machine. keepCarried also drops an entry taken from local
// main unless the file on disk still holds exactly that blob (an absent file is dropped).
function sendPredicate(plansDir, destUrl) {
  const dir = toWindowsPath(plansDir);
  const isSendable = (rel) => isSyncTargetName(rel) && readProjectHostState(path.join(dir, rel), destUrl) === "match";
  const onDisk = (e) => {
    const bytes = readVerifiedRegularFile(path.join(dir, e.rel));
    return Boolean(bytes) && G.blobIdOf(bytes) === e.blob;
  };
  return { isSendable, keepCarried: (entries) => entries.filter((e) => isSendable(e.rel) && onDisk(e)) };
}

module.exports = { recordPathFor, recordProjectHost, readProjectHostState, sendPredicate };
