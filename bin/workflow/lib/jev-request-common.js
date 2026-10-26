"use strict";
// bin/workflow/lib/jev-request-common.js — the request-building pieces every Jev adapter
// shares: capped artifact reads, the WORKTREE_NOTES session binding, outbound redaction,
// rubric lookup, and the sections a Jev input may carry per stage.
// Point-specific knowledge (questions, answer mapping, contract lines) stays in the adapters.

const fs = require("fs");
const path = require("path");
const { StringDecoder } = require("string_decoder");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..", "..");
const SECRET_SHAPE_PATH = path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "workflow-state", "complexity-routing", "secret-shape.js");
const OUTPUT_SANITIZE_PATH = path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "output-sanitize.js");

const MAX_STATE_CHARS = 16000;
const MAX_ARTIFACT_READ_BYTES = 1048576;
const ARTIFACTS = Object.freeze(["intent", "outline", "detail"]);
const SID_RE = /^[A-Za-z0-9._-]{1,128}$/;

// Per stage, the sections a Jev input carries (the full artifacts a backup subagent reads as
// sources). A point's required sections for a stage must be a subset (validateRegistry).
const STAGE_SOURCE_SECTIONS = Object.freeze({
  complexity: Object.freeze(["intent", "outline", "issue body"]),
  outline: Object.freeze(["intent", "outline", "issue body"]),
  detail: Object.freeze(["intent", "outline", "issue body"]),
  "write-tests": Object.freeze(["intent", "outline", "detail", "issue body"]),
  "write-code": Object.freeze(["intent", "outline", "write-code files", "detail", "issue body"]),
});

// Jev input section order (a stage's required sections come first, each group in this order).
const SECTION_ORDER = Object.freeze(["intent", "outline", "write-code files", "detail", "issue body"]);
// The plans-dir artifact behind each section and the name of its ticket copy.
const SECTION_FILES = Object.freeze({
  intent: Object.freeze({ suffix: "-intent.md", copy: "intent.md" }),
  outline: Object.freeze({ suffix: "-outline.md", copy: "outline.md" }),
  "write-code files": Object.freeze({ suffix: "-write-code-files.txt", copy: "write-code-files.txt" }),
  detail: Object.freeze({ suffix: "-detail.md", copy: "detail.md" }),
  "issue body": Object.freeze({ suffix: "-context.md", copy: "context.md" }),
});
// The step whose artifact a section is; a skipped producer step exempts the section.
const SECTION_PRODUCER_STEP = Object.freeze({ outline: "outline", detail: "detail" });
// The only named reasons a required section may be absent (CPR-UNV).
const SECTION_EXEMPTIONS = Object.freeze(["producer-step-skipped", "no-issue"]);

// The body of the rubric's "### <id>" section, read at runtime (never copied here).
function rubricSection(rubric, id) {
  const lines = rubric.split("\n");
  const start = lines.indexOf("### " + id);
  if (start < 0) return null;
  const body = [];
  for (const l of lines.slice(start + 1)) {
    if (l.startsWith("#")) break;
    if (l.trim()) body.push(l.trim());
  }
  return body.length ? body.join(" ") : null;
}

// The body of a "## <heading>" section, trimmed; null when absent. It ends at the next "## "
// line, or, when `until` is given, only at the LAST "## <until>" line (else at the end of the
// text): a section of third-party text may carry that line itself, and only the last one is the
// writer's. `until` null means the end of the text: no line is a delimiter.
function mdSection(text, heading, until) {
  const lines = String(text).replace(/\r\n/g, "\n").split("\n");
  const start = lines.indexOf("## " + heading);
  if (start < 0) return null;
  let end = lines.length;
  if (until === undefined) end = lines.findIndex((l, i) => i > start && l.startsWith("## "));
  else if (until !== null) end = lines.lastIndexOf("## " + until);
  if (end <= start) end = lines.length;
  return lines.slice(start + 1, end).join("\n").trim();
}

// The Issue body of a context.md text; null when the section is absent. `capped` says the
// text is a prefix cut at the read cap: the writer's closing heading may lie beyond the cut,
// so the last such line in the prefix can be the issue's own text and nothing delimits.
function issueBodyOf(text, capped) {
  const { ISSUE_BODY_SECTION } = require(path.join(__dirname, "workflow-init", "phases", "write-context.js"));
  return mdSection(text, ISSUE_BODY_SECTION.heading, capped === true ? null : ISSUE_BODY_SECTION.next);
}

// The rubric's "## Judgment rules" section, read at runtime (the rubric stays the SSOT).
function rubricRules(rubric) {
  return mdSection(rubric, "Judgment rules");
}

// At most maxBytes of the file as raw bytes, with the file's full size; over_cap tells a
// caller that needs the whole file (a complete copy) that it did not get it.
function readCappedBytes(file, maxBytes) {
  const fd = fs.openSync(file, "r");
  try {
    const size = fs.fstatSync(fd).size;
    const cap = Math.min(size, maxBytes);
    const buf = Buffer.alloc(cap);
    let n = 0;
    while (n < cap) {
      const got = fs.readSync(fd, buf, n, cap - n, null);
      if (got === 0) break;
      n += got;
    }
    return { bytes: buf.subarray(0, n), size, over_cap: size > maxBytes };
  } finally {
    fs.closeSync(fd);
  }
}

// At most maxBytes of the file, decoded as UTF-8; when truncated, StringDecoder.write (no
// end()) drops only an incomplete trailing sequence, so a genuine U+FFFD at the cap survives.
function readCapped(file, maxBytes) {
  const r = readCappedBytes(file, maxBytes);
  return r.over_cap ? new StringDecoder("utf8").write(r.bytes) : r.bytes.toString("utf8");
}

const validSid = (sid) => typeof sid === "string" && SID_RE.test(sid) && !sid.includes("..");

// The session chain's first_session_id, or sid itself when it cannot be resolved to a valid name.
function firstSidOf(sid) {
  try {
    const { resolveFirstSid } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "workflow-state", "state-ancestry.js"));
    const first = resolveFirstSid(sid);
    return validSid(first) ? first : sid;
  } catch (_e) {
    return sid;
  }
}

// The read cap bounds memory and time far above MAX_STATE_CHARS; the header's line count
// is then over the read portion only.
// Plans carry the first_session_id name (#2748), so a session-downstream reads its chain's plans.
function readArtifactsFor(dir, id) {
  if (!validSid(id)) return [];
  const planSid = firstSidOf(id);
  const out = [];
  for (const name of ARTIFACTS) {
    try {
      const text = readCapped(path.join(dir, `${planSid}-${name}.md`), MAX_ARTIFACT_READ_BYTES);
      out.push({ name, text: text.replace(/\r\n/g, "\n") });
    } catch (_e) { /* absent artifact */ }
  }
  return out;
}

function plansDir() {
  return require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "workflow-plans-dir.js")).getWorkflowPlansDir();
}

// [{section, file, copy}] for the stage's source sections whose artifact exists, in SECTION_ORDER.
// The plan sections carry the first_session_id name (#2748); the others stay the session's own.
function artifactPathsFor(sid, stage) {
  if (!validSid(sid) || !Object.prototype.hasOwnProperty.call(STAGE_SOURCE_SECTIONS, stage)) return [];
  const dir = plansDir();
  const planSid = firstSidOf(sid);
  const out = [];
  for (const section of SECTION_ORDER) {
    if (!STAGE_SOURCE_SECTIONS[stage].includes(section)) continue;
    const owner = ARTIFACTS.includes(section) ? planSid : sid;
    const file = path.join(dir, owner + SECTION_FILES[section].suffix);
    try {
      if (fs.statSync(file).isFile()) out.push({ section, file, copy: SECTION_FILES[section].copy });
    } catch (_e) { /* absent artifact */ }
  }
  return out;
}

// The "## Issue body" of <sid>-context.md (capped read), or null when the file or section is absent.
function readIssueBody(sid) {
  if (!validSid(sid)) return null;
  try {
    const r = readCappedBytes(path.join(plansDir(), `${sid}-context.md`), MAX_ARTIFACT_READ_BYTES);
    const text = r.over_cap ? new StringDecoder("utf8").write(r.bytes) : r.bytes.toString("utf8");
    return issueBodyOf(text, r.over_cap);
  } catch (_e) {
    return null;
  }
}

// The SECTION_EXEMPTIONS reason that exempts a section for the session, or null. An
// unreadable state or context.md never exempts (safe side: the subagent decides).
function exemptionFor(sid, section) {
  if (Object.prototype.hasOwnProperty.call(SECTION_PRODUCER_STEP, section)) {
    try {
      const { readState } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "workflow-state", "state-io.js"));
      const st = readState(sid);
      const step = st && st.steps && st.steps[SECTION_PRODUCER_STEP[section]];
      return step && step.status === "skipped" ? "producer-step-skipped" : null;
    } catch (_e) {
      return null;
    }
  }
  if (section === "issue body") {
    const { NO_ISSUE_BODY } = require(path.join(__dirname, "workflow-init", "phases", "write-context.js"));
    return readIssueBody(sid) === NO_ISSUE_BODY ? "no-issue" : null;
  }
  return null;
}

// requiredSectionsStatus(sid, required, {section: full|truncated|absent}, sourcesFailed, planSections)
// -> {met, missing, exempt}: a required section that is not exempt must be full and copied whole;
// of a non-empty planSections at least one must be full or truncated and copied whole, else all
// of them are missing.
function requiredSectionsStatus(sid, required, sections, sourcesFailed, planSections) {
  const failed = Array.isArray(sourcesFailed) ? sourcesFailed : [];
  const states = sections && typeof sections === "object" ? sections : {};
  const missing = [];
  const exempt = [];
  for (const sec of Array.isArray(required) ? required : []) {
    if (exemptionFor(sid, sec) !== null) {
      exempt.push(sec);
    } else if (states[sec] !== "full" || failed.includes(sec)) {
      missing.push(sec);
    }
  }
  const plan = Array.isArray(planSections) ? planSections : [];
  const planMet = plan.some((sec) => ["full", "truncated"].includes(states[sec]) && !failed.includes(sec));
  if (plan.length && !planMet) missing.push(...plan);
  return { met: missing.length === 0, missing, exempt };
}

// Comparable form of a path: POSIX drive-letter form normalized, resolved, no trailing separator, "/"
// separators, lower-cased on win32 only. Null for a non-string or empty value.
function pathKey(p, toWindowsPath) {
  if (typeof p !== "string" || !p) return null;
  const w = toWindowsPath(p);
  if (typeof w !== "string" || !w) return null;
  let k = path.resolve(w).replace(/\\/g, "/");
  while (k.length > 1 && k.endsWith("/") && !/^[A-Za-z]:\/$/.test(k)) k = k.slice(0, -1);
  return process.platform === "win32" ? k.toLowerCase() : k;
}

// The workflow session id can differ from the hook's: <cwd>/WORKTREE_NOTES.md alone is read
// (no sibling scan, no git, no process.cwd()), and only for an absolute cwd. The notes id is
// adopted only when its state's session_worktree, or the latest worktree-entered event's own
// cwd (not a fallback-process-cwd guess), path-equals the hook cwd: every main-checkout
// session shares the start cwd, so a start-context or process cwd never binds and a stale
// notes file lends no plan or step (#2460 C12).
function notesSessionId(rawCwd) {
  try {
    if (typeof rawCwd !== "string" || !rawCwd) return null;
    const { toWindowsPath } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "branch-diff.js"));
    const cwd = toWindowsPath(rawCwd);
    if (typeof cwd !== "string" || !cwd || !path.isAbsolute(cwd)) return null;
    const notes = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "worktree-notes-session-ids.js"));
    const wsid = notes.readSessionIdFromWorktreeNotes(path.join(cwd, notes.NOTES_BASENAME));
    if (!wsid) return null;
    const { readState } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "workflow-state", "state-io.js"));
    const state = readState(wsid);
    if (!state || typeof state !== "object") return null;
    const want = pathKey(cwd, toWindowsPath);
    const same = (p) => { const k = pathKey(p, toWindowsPath); return k !== null && k === want; };
    if (same(state.session_worktree)) return wsid;
    const events = Array.isArray(state.events) ? state.events : [];
    let entered = null;
    for (const e of events) {
      if (e && e.kind === "worktree" && e.transition === "entered") entered = e;
    }
    const bound = entered !== null && typeof entered.cwd === "string"
      && entered.path_source !== "fallback-process-cwd" && same(entered.cwd);
    return bound ? wsid : null;
  } catch (_e) {
    return null;
  }
}

// At most n UTF-16 units, never ending on a lone high surrogate: bytes/sha256 must describe
// the exact string sent, and Buffer would re-encode a lone surrogate as U+FFFD.
function sliceUnits(s, n) {
  const end = Math.max(0, n);
  if (end > 0 && end < s.length) {
    const c = s.charCodeAt(end - 1);
    if (c >= 0xd800 && c <= 0xdbff) return s.slice(0, end - 1);
  }
  return s.slice(0, end);
}

// Every text that leaves the machine: provider key shapes, then the wider credential set
// (github_pat_, URL userinfo, Authorization schemes, token=/password: assignments, any PEM kind).
// Required on use, so loading this module (the registry reads STAGE_SOURCE_SECTIONS) never
// depends on the redaction modules; a module that cannot load throws here, before any send.
function redactOutbound(text) {
  const { redactSecretShaped } = require(SECRET_SHAPE_PATH);
  const { redactSecrets } = require(OUTPUT_SANITIZE_PATH);
  return redactSecrets(redactSecretShaped(text));
}

module.exports = {
  SCRIPT_CHECKOUT_ROOT,
  MAX_STATE_CHARS,
  MAX_ARTIFACT_READ_BYTES,
  ARTIFACTS,
  SID_RE,
  STAGE_SOURCE_SECTIONS,
  SECTION_ORDER,
  SECTION_FILES,
  SECTION_PRODUCER_STEP,
  SECTION_EXEMPTIONS,
  rubricSection,
  rubricRules,
  mdSection,
  issueBodyOf,
  artifactPathsFor,
  readIssueBody,
  requiredSectionsStatus,
  readCappedBytes,
  readCapped,
  readArtifactsFor,
  pathKey,
  notesSessionId,
  sliceUnits,
  redactOutbound,
};
