"use strict";

// Receipt store for the InstructionsLoaded audit hook. The host dispatches InstructionsLoaded once per injected file,
// asynchronously, in a separate process; with no shared memory or ordering guarantee, the only way to reconstruct
// "what the session actually loaded" is for each process to publish one small file and a later reader to aggregate them.
//
// Layout: <workflowDir>/<session>.instructions-loaded/<sha1(file_path)>.json — one entry per loaded file (a repeated
// load collides on its own key by design), published atomically (temp name + rename) so a reader never sees a partial
// entry and a killed writer leaves no `.json` debris.
// Nothing here decides a verdict — classification lives in hooks/instructions-loaded-audit.js. This module owns paths,
// bytes, and the quiescence protocol only.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const os = require("os");

const RECEIPT_DIR_SUFFIX = ".instructions-loaded";
const UNKNOWN_SESSION = "unknown";
const MAX_SESSION_SEGMENT = 96;

// --- redaction -------------------------------------------------------------

// Credential shapes that must never be persisted, even in the two fields the
// receipt is required to keep (file_path, load_reason). Prefix-anchored so an
// ordinary path or reason string is never mangled.
const SECRET_PATTERNS = [
  /(?<![A-Za-z0-9])sk-[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?/g,
  /(?<![A-Za-z0-9])gh[pousr][-_][A-Za-z0-9]{8,}/g,
  /(?<![A-Za-z0-9])xox[baprs][-_][A-Za-z0-9-]{8,}/g,
  /(?<![A-Za-z0-9])AKIA[0-9A-Z]{12,}/g,
];

// Control characters that can rewrite a reviewer's terminal line. \t, \n and \r
// are deliberately preserved: they are ordinary text, not an injection vector.
const CONTROL_CHARS = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g;

// Redact secrets, neutralize sentinel-shaped substrings, and drop control bytes.
// Any non-string input yields the empty string.
function redact(value) {
  if (typeof value !== "string") return "";
  let out = value;
  for (const re of SECRET_PATTERNS) out = out.replace(re, "[redacted]");
  out = out.replace(/<<\s*WORKFLOW_/g, "[sentinel] ");
  out = out.replace(CONTROL_CHARS, "");
  return out;
}

// --- path identity ---------------------------------------------------------

function sha1(value) {
  return crypto.createHash("sha1").update(String(value)).digest("hex");
}

// The entry key stays sha1(file_path AS RECEIVED) so a receipt is addressable
// from the payload alone, without re-deriving which project root was active.
function entryKey(filePath) {
  return sha1(filePath);
}

// Repo-relative, POSIX-separated identity for a loaded file. Cross-run
// comparison (the TL3 gate's Q1 barrier) rests on this value being independent
// of the root the file was loaded from. A path with no repo-relative form is
// recorded as a deterministic digest rather than an absolute path.
function toRepoRelative(filePath, projectRoot) {
  if (typeof filePath !== "string" || filePath === "") return "";
  const posix = filePath.split("\\").join("/");
  if (projectRoot) {
    try {
      const rel = path
        .relative(path.resolve(projectRoot), path.resolve(projectRoot, filePath))
        .split(path.sep)
        .join("/");
      if (rel && rel !== ".." && !rel.startsWith("../") && !path.isAbsolute(rel)) {
        return rel;
      }
    } catch (_) {
      // fall through to the out-of-root form
    }
  }
  if (!path.isAbsolute(posix) && !posix.startsWith("../") && !/^[A-Za-z]:/.test(posix)) {
    return posix;
  }
  return "out-of-root:" + sha1(posix).slice(0, 16);
}

// A rules file reaches the loader from several roots — <project>/.claude/rules/, $CLAUDE_CONFIG_DIR/rules/,
// ~/.claude/rules/ — and only one of them yields a repo-relative path that starts with `rules/`. The policy tables are
// keyed on the `rules/<subpath>.md` form, so identity has to be recovered by asking which KNOWN root the path lies
// under, not by pattern-matching its tail. A tail match ("does a `rules/` segment appear anywhere") is not identity: it
// turns `~/.ssh/rules/id_rsa.md` into `rules/id_rsa.md`, which both defeats the deliberate out-of-root digest redaction
// and feeds an unrelated file to the policy comparison as a bogus S-MISSING.

// Windows compares paths case-insensitively; POSIX does not. The choice is made
// once, here, rather than per call site.
const PATH_CASE_INSENSITIVE = process.platform === "win32";

function toPosixPath(value) {
  return String(value).split("\\").join("/");
}

function forCompare(posixPath) {
  const trimmed = posixPath.replace(/\/+$/, "");
  return PATH_CASE_INSENSITIVE ? trimmed.toLowerCase() : trimmed;
}

// The complete set of roots a rules file can legitimately load from. An env var
// that is unset drops out of the list entirely — resolving an empty base would
// collapse to the process CWD and produce a root that matches almost anything.
function rulesRoots(env) {
  const source = env || process.env;
  const out = [];
  const add = (base, ...rest) => {
    if (typeof base !== "string" || base.trim() === "") return;
    try {
      out.push(toPosixPath(path.resolve(base, ...rest)));
    } catch (_) {
      // an unresolvable base is simply not a root
    }
  };
  add(source.CLAUDE_PROJECT_DIR, "rules");
  add(source.CLAUDE_PROJECT_DIR, ".claude", "rules");
  add(source.AGENTS_CONFIG_DIR, "rules");
  add(source.CLAUDE_CONFIG_DIR, "rules");
  // HOME and os.homedir() disagree on win32 (USERPROFILE wins there, and a
  // Git Bash HOME can differ), so both spellings of the home root are honoured.
  add(source.HOME, ".claude", "rules");
  try {
    add(os.homedir(), ".claude", "rules");
  } catch (_) {
    // no home directory resolvable
  }
  return out;
}

// Segment-aware containment: `<root>foo/x.md` must not count as being under
// `<root>`, so the separator is part of the required prefix.
function relativeUnder(absPosix, rootPosix) {
  const root = forCompare(rootPosix);
  const target = forCompare(absPosix);
  if (root === "" || !target.startsWith(root + "/")) return "";
  return absPosix.slice(rootPosix.replace(/\/+$/, "").length + 1);
}

// Normalized `rules/<subpath>.md` key for a loaded file, or "" when the path is
// not a rules file under a known rules root. Pure: the path is inspected as
// text and resolved, never stat()ed.
function toRulesKey(filePath, env) {
  if (typeof filePath !== "string" || filePath === "") return "";
  const source = env || process.env;
  let abs;
  try {
    const base = source.CLAUDE_PROJECT_DIR;
    abs = toPosixPath(
      path.isAbsolute(filePath) || /^[A-Za-z]:[\\/]/.test(filePath) || !base
        ? path.resolve(filePath)
        : path.resolve(base, filePath)
    );
  } catch (_) {
    return "";
  }
  for (const root of rulesRoots(source)) {
    const rest = relativeUnder(abs, root);
    // Nested subpaths (rules/test/fixture-isolation.md) keep their full tail.
    if (rest && rest.endsWith(".md")) return "rules/" + rest;
  }
  return "";
}

// --- receipt directory -----------------------------------------------------

// session_id arrives from the host and flows straight into a directory name.
// Everything outside [A-Za-z0-9_-] is folded away so no traversal, separator,
// or control byte can reach the filesystem.
function sanitizeSessionSegment(sessionId) {
  const raw = typeof sessionId === "string" ? sessionId.trim() : "";
  const safe = raw.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, MAX_SESSION_SEGMENT);
  return safe.replace(/^_+$/, "") === "" ? UNKNOWN_SESSION : safe;
}

function getWorkflowDirSafe() {
  const { getWorkflowDir } = require("../workflow-state");
  return getWorkflowDir();
}

// Absolute path of the receipt directory for a session. Throws only if the
// workflow directory itself cannot be resolved.
function receiptDirFor(sessionId, workflowDir) {
  const base = workflowDir || getWorkflowDirSafe();
  return path.join(base, sanitizeSessionSegment(sessionId) + RECEIPT_DIR_SUFFIX);
}

// The receipt directory is a NAME the hook derives, not a handle it owns.
// Anything already sitting there as a link would redirect every write outside
// the pinned workflow directory, so refuse quietly instead of following it.
function ensureReceiptDir(dir) {
  try {
    const st = fs.lstatSync(dir);
    if (st.isSymbolicLink()) return false;
    if (!st.isDirectory()) return false;
    return true;
  } catch (_) {
    // does not exist yet
  }
  fs.mkdirSync(dir, { recursive: true });
  try {
    if (fs.lstatSync(dir).isSymbolicLink()) return false;
  } catch (_) {
    return false;
  }
  return true;
}

// --- publish / read --------------------------------------------------------

// Atomic publish: write under a temp name in the same directory, then rename
// onto the key. Concurrent writers race on the rename only; the loser retries
// and, if it still cannot settle, removes its temp file so no non-.json debris
// survives.
function writeReceipt(dir, key, entry) {
  const dest = path.join(dir, key + ".json");
  const tmp = path.join(dir, ".pub-" + process.pid + "-" + crypto.randomBytes(6).toString("hex"));
  fs.writeFileSync(tmp, JSON.stringify(entry));
  for (let attempt = 0; attempt < 5; attempt += 1) {
    try {
      fs.renameSync(tmp, dest);
      return true;
    } catch (_) {
      // Windows can refuse the replace while another process holds the target
      // open; the content is identical-by-construction, so a retry is safe.
    }
  }
  try {
    fs.unlinkSync(tmp);
  } catch (_) {
    // best effort
  }
  return false;
}

function readReceipt(dir, key) {
  try {
    const parsed = JSON.parse(fs.readFileSync(path.join(dir, key + ".json"), "utf8"));
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : null;
  } catch (_) {
    return null;
  }
}

// Every settled, parseable entry in a receipt directory. Temp names, corrupt
// bytes, and unreadable paths are skipped: a half-published entry is not an
// observation, and treating it as one would let Q1 pass on a file that never
// actually settled.
function readEntries(dir) {
  let names;
  try {
    names = fs.readdirSync(dir);
  } catch (_) {
    return [];
  }
  const out = [];
  for (const name of names) {
    if (!name.endsWith(".json")) continue;
    try {
      const parsed = JSON.parse(fs.readFileSync(path.join(dir, name), "utf8"));
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) out.push(parsed);
    } catch (_) {
      // skip this entry only
    }
  }
  return out;
}

// --- quiescence ------------------------------------------------------------

function defaultSleep(ms) {
  const sab = new SharedArrayBuffer(4);
  Atomics.wait(new Int32Array(sab), 0, 0, Math.max(0, ms));
}

function numOr(value, fallback) {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

// Stability is judged over the PAIR (entry set, newest fired_at). Watching the
// set alone would see a re-fired event that republishes an existing key as a
// motionless directory and settle while the session is still loading.
function signatureOf(entries) {
  const paths = [];
  let newest = 0;
  for (const e of entries) {
    if (e && typeof e.file_path === "string") paths.push(e.file_path);
    const t = e && e.fired_at ? Date.parse(e.fired_at) : NaN;
    if (!Number.isNaN(t) && t > newest) newest = t;
  }
  return [...new Set(paths)].sort().join("\u0000") + "|" + newest;
}

function isCovered(entries, expected) {
  const seen = new Set(entries.map((e) => e && e.file_path));
  return expected.every((fp) => seen.has(fp));
}

/**
 * Block until the receipt directory is both COMPLETE and STABLE. Q1 (completeness barrier): every path in `expected`
 * has a settled entry. Q2 (stability window): the (entry set, newest fired_at) pair has not changed for `windowSec`.
 * Both are bounded — Q1 by `q1DeadlineSec`, the whole run by `totalDeadlineSec`. An empty `expected` is INCOMPLETE,
 * never a vacuous OK: concluding from an absence that was never given a chance to appear is the false green this
 * protocol exists to prevent.
 *
 * @returns {{status: "OK"|"INCOMPLETE", entries: object[]}}
 */
function waitForQuiescence(dir, opts = {}) {
  const expected = [...new Set((Array.isArray(opts.expected) ? opts.expected : []).filter(Boolean))];
  if (expected.length === 0) return { status: "INCOMPLETE", entries: readEntries(dir) };

  const windowMs = Math.max(0, numOr(opts.windowSec, 5)) * 1000;
  const q1Ms = Math.max(0, numOr(opts.q1DeadlineSec, 60)) * 1000;
  const totalMs = numOr(opts.totalDeadlineSec, 90) * 1000;
  const rawPoll = numOr(opts.pollMs, 1000);
  const pollMs = rawPoll > 0 ? rawPoll : 1000;
  const now = typeof opts.now === "function" ? opts.now : Date.now;
  const sleep = typeof opts.sleep === "function" ? opts.sleep : defaultSleep;

  const t0 = now();
  let entries = readEntries(dir);
  let signature = signatureOf(entries);
  let lastChange = t0;

  for (;;) {
    const complete = isCovered(entries, expected);
    const t = now();
    if (complete && t - lastChange >= windowMs) return { status: "OK", entries };
    if (!complete && t - t0 >= q1Ms) return { status: "INCOMPLETE", entries };
    if (t - t0 >= totalMs) return { status: "INCOMPLETE", entries };

    sleep(pollMs);
    const next = readEntries(dir);
    const nextSignature = signatureOf(next);
    if (nextSignature !== signature) {
      signature = nextSignature;
      lastChange = now();
    }
    entries = next;
  }
}

module.exports = {
  RECEIPT_DIR_SUFFIX,
  redact,
  entryKey,
  toRepoRelative,
  toRulesKey,
  sanitizeSessionSegment,
  receiptDirFor,
  ensureReceiptDir,
  writeReceipt,
  readReceipt,
  readEntries,
  waitForQuiescence,
};
