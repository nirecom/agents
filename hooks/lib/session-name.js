"use strict";
// The session names find-peer looks up (#2668): work "#A[ #B …] <title> sid-xxxxxxxx",
// pm "[PM] <tag>: [#A …] <title of #A | objective> sid-xxxxxxxx" (#2941), none "<repo> sid-xxxxxxxx". The suffix is the first 8
// hex digits of a UUID session id, lower-cased; a non-UUID id gets none. Matching reads the suffix
// through SESSION_NAME_SUFFIX_RE only. Design: docs/architecture/cross-session-messaging.md.

const { parseIssueToken } = require("./parse-closes-issues");

const TITLE_MAX = 200;
const SESSION_NAME_SUFFIX_RE = /\ssid-([0-9a-f]{8})$/;
const PM_NAME_PREFIX_RE = /^\[PM\]\s/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const KINDS = Object.freeze(["work", "pm", "none"]);

// cleanTitle(raw) -> control characters and space runs collapsed, cut at TITLE_MAX; null when empty.
function cleanTitle(raw) {
  if (typeof raw !== "string") return null;
  // eslint-disable-next-line no-control-regex
  const t = raw.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim().slice(0, TITLE_MAX);
  return t || null;
}

const refLabel = (ref) => (ref.repo ? `${ref.repo}#${ref.number}` : `#${ref.number}`);

// sessionSuffix(sessionId) -> " sid-xxxxxxxx", or "" when the id is not a UUID.
function sessionSuffix(sessionId) {
  return typeof sessionId === "string" && UUID_RE.test(sessionId) ? ` sid-${sessionId.slice(0, 8).toLowerCase()}` : "";
}

// composeSessionName({kind, refs, title, repo, sessionId}) -> the name; pure. The issue numbers
// and the suffix are never cut, only the title.
function composeSessionName(o) {
  const { kind, tag, refs, title, repo, sessionId } = o || {};
  if (!KINDS.includes(kind)) throw new Error(`session-name: unknown kind ${JSON.stringify(kind)}`);
  const parts = [];
  if (kind === "none") {
    parts.push(cleanTitle(repo));
  } else {
    if (kind === "pm") parts.push("[PM]", typeof tag === "string" && tag ? `${tag}:` : null);
    parts.push(...(Array.isArray(refs) ? refs : []).map(refLabel), cleanTitle(title));
  }
  return parts.filter(Boolean).join(" ") + sessionSuffix(sessionId);
}

const isRefWord = (w) => w.includes("#") && Boolean(parseIssueToken(w));
const textOf = (args) => (Array.isArray(args) ? args.join(" ") : String(args || ""));

// splitLeadingRefs(text) -> {refs, rest}: the refs at the head (split on spaces / commas), and the
// verbatim remainder from the first non-ref word, ends trimmed ("" when none); a #N in rest is no ref.
function splitLeadingRefs(text) {
  const s = String(text || "");
  const refs = [];
  const re = /[^\s,]+/g;
  let m;
  while ((m = re.exec(s)) !== null) {
    if (!isRefWord(m[0])) return { refs, rest: s.slice(m.index).trim() };
    refs.push(parseIssueToken(m[0]));
  }
  return { refs, rest: "" };
}

// parsePmInitArgs(args) -> {tag, refs, objective} for `<tag> [#A…] [theme]`: the first word is the
// tag unless it is an issue ref (tag null then; validity is schema.isValidPmTag), then the leading
// refs, and the verbatim rest as the objective (null when empty).
function parsePmInitArgs(args) {
  const text = textOf(args);
  const m = text.match(/[^\s,]+/);
  const tag = m && !isRefWord(m[0]) ? m[0] : null;
  const { refs, rest } = splitLeadingRefs(tag ? text.slice(m.index + m[0].length) : text);
  return { tag, refs, objective: rest || null };
}

// parsePmAssignArgs(args) -> {refs, reason} for `/pm-add|/pm-remove #A… [reason]` (reason null when empty).
function parsePmAssignArgs(args) {
  const { refs, rest } = splitLeadingRefs(textOf(args));
  return { refs, reason: rest || null };
}

// repoNameOf(originUrl) -> the repo part of an origin URL ("o/r.git" -> "r"), or null.
function repoNameOf(url) {
  if (typeof url !== "string") return null;
  const seg = url.trim().replace(/\/+$/, "").replace(/\.git$/i, "").split(/[/:]/).pop();
  return cleanTitle(seg);
}

// The resume mark: SessionStart (source resume) arms it in the session's control dir, and the first
// UserPromptSubmit after it takes it to give the name again. Both fail-open.
const RESUME_MARK_FILE = "session-name-resume";

function armResumeMark(sid) {
  try {
    const fs = require("fs");
    const { controlPath } = require("../workflow-state/state-io/control-dir");
    fs.writeFileSync(controlPath(sid, RESUME_MARK_FILE, { forWrite: true }), "");
    return true;
  } catch (_) {
    return false;
  }
}

// takeResumeMark(sid) -> true when the mark was there; it is removed either way.
function takeResumeMark(sid) {
  try {
    const fs = require("fs");
    const { controlPath } = require("../workflow-state/state-io/control-dir");
    fs.unlinkSync(controlPath(sid, RESUME_MARK_FILE));
    return true;
  } catch (_) {
    return false;
  }
}

module.exports = {
  TITLE_MAX, SESSION_NAME_SUFFIX_RE, PM_NAME_PREFIX_RE, KINDS, RESUME_MARK_FILE,
  cleanTitle, refLabel, sessionSuffix, composeSessionName, splitLeadingRefs, parsePmInitArgs, parsePmAssignArgs, repoNameOf,
  armResumeMark, takeResumeMark,
};
