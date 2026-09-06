"use strict";
// Last-resort evidence for /resume-session: when neither the state file nor the
// plan artifacts survived, the upstream transcript still holds the last turns.
//
// Two hard contracts (#2218 Step 11): the address is COMPOSED from the encoded
// cwd rather than read from CLAUDE_SESSION_JSONL_PATH — that variable points at
// the DOWNSTREAM session's own file, so following it would summarize the wrong
// session — and the raw text never enters this process's stdout. Only a path to
// a capped scratch file is returned; a subagent reads it (see
// skills/resume-session/scripts/summarize-transcript-tail.md).

const fs = require("fs");
const os = require("os");
const path = require("path");
const { _encodeCwd, _getTranscriptBase } = require("../../../hooks/lib/session-title");
const { SESSION_ID_VALID_RE } = require("../../../hooks/workflow-state/state-io");

const MAX_TAIL_BYTES = 200 * 1024;

function unavailable(sid, reason) {
  return { available: false, path: null, upstreamSid: sid || null, reason };
}

// The upstream transcript address, composed — never taken from the environment.
function locateUpstreamTranscript(sid, cwd) {
  if (typeof sid !== "string" || !SESSION_ID_VALID_RE.test(sid)) return null;
  if (typeof cwd !== "string" || cwd.length === 0) return null;
  try {
    return path.join(_getTranscriptBase(), _encodeCwd(cwd), sid + ".jsonl");
  } catch (e) {
    return null;
  }
}

// The rung exists for the case where the state file is already gone, so the
// caller has NO cwd left to encode — and `_encodeCwd` is lossy, so the encoded
// directory cannot be reversed either. Scanning the per-cwd directories for the
// session id is the only address that survives that loss.
function discoverUpstreamTranscript(sid) {
  if (typeof sid !== "string" || !SESSION_ID_VALID_RE.test(sid)) return null;
  let entries;
  try {
    entries = fs.readdirSync(_getTranscriptBase(), { withFileTypes: true });
  } catch (e) {
    return null;
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const candidate = path.join(_getTranscriptBase(), entry.name, sid + ".jsonl");
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

// Cut at the first line break inside the window so the scratch file never opens
// mid-JSON — a truncated first record would break the reader's line parse.
function tailBytes(file, cap) {
  const size = fs.statSync(file).size;
  const want = Math.min(size, cap);
  const fd = fs.openSync(file, "r");
  try {
    const buf = Buffer.alloc(want);
    fs.readSync(fd, buf, 0, want, size - want);
    if (want === size) return buf;
    const nl = buf.indexOf(0x0a);
    return nl === -1 ? buf : buf.slice(nl + 1);
  } finally {
    fs.closeSync(fd);
  }
}

// captureTranscriptTail({ upstreamSid, cwd, maxBytes })
//   → { available, path, upstreamSid, reason, bytes }
function captureTranscriptTail(input) {
  const opts = input || {};
  const sid = opts.upstreamSid;
  if (typeof sid !== "string" || !SESSION_ID_VALID_RE.test(sid)) {
    return unavailable(null, "invalid-session-id");
  }
  const src = locateUpstreamTranscript(sid, opts.cwd) || discoverUpstreamTranscript(sid);
  if (src === null) return unavailable(sid, "no-recorded-cwd");
  let data;
  try {
    if (!fs.existsSync(src)) return unavailable(sid, "transcript-not-found");
    const cap = Number.isInteger(opts.maxBytes) && opts.maxBytes > 0 ? opts.maxBytes : MAX_TAIL_BYTES;
    data = tailBytes(src, cap);
  } catch (e) {
    return unavailable(sid, "transcript-unreadable");
  }
  const out = path.join(os.tmpdir(), `resume-tail-${sid}-${process.pid}.txt`);
  try {
    fs.writeFileSync(out, data);
  } catch (e) {
    return unavailable(sid, "scratch-write-failed");
  }
  return { available: true, path: out, upstreamSid: sid, reason: null, bytes: data.length };
}

module.exports = { MAX_TAIL_BYTES, locateUpstreamTranscript, discoverUpstreamTranscript, captureTranscriptTail };
