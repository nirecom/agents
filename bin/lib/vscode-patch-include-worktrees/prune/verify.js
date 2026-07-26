// I3, the superset proof: a stub may only be deleted once ANOTHER file has been shown
// to already carry every one of its (sessionId, customTitle) pairs AND to hold a real
// transcript record for that session. Nothing here deletes, and nothing here decides —
// it only reports what could be observed, so that the caller can refuse on anything
// short of a clean `ok`.
//
// The record vocabulary lives here rather than in prune.js because both the classifier
// and the verifier must read a line the exact same way; a drift between the two would
// mean a stub was judged by one grammar and its counterpart by another.
'use strict';

const fs = require('fs');
const { StringDecoder } = require('string_decoder');

// `custom-title` ALONE. `ai-title` is a deliberate scope exclusion: it is generated
// rather than authored, so it is neither prunable evidence nor prunable content.
const TITLE_RECORD_TYPE = 'custom-title';
const CONTENT_RECORD_TYPES = new Set(['user', 'assistant', 'summary']);
// A title record carrying anything outside this set holds information whose presence in
// a counterpart cannot be proven, so it must block the `stub` verdict.
const KNOWN_TITLE_FIELDS = new Set(['type', 'sessionId', 'customTitle']);

// Verification must read to EOF (a title can legitimately be the last record written),
// so its budget is far larger than the classifier's. It is still bounded: an unbounded
// read on a session store measured in gigabytes is a denial of service on the user.
const VERIFY_MAX_SCAN = 64 * 1024 * 1024;
const CHUNK = 64 * 1024;

// Streams `file` line by line, reading at most `maxScan` bytes. onLine may return false
// to stop early. Returns { read, size, truncated, stopped }: `truncated` is the
// load-bearing field — true means the file was NOT observed in full, which every caller
// must treat as an observation failure rather than as evidence.
//
// Chunked + StringDecoder rather than readFileSync: the cap has to be a read budget, not
// a post-hoc slice, and a chunk boundary must never split a multi-byte character.
function scanLines(file, maxScan, onLine) {
  const fd = fs.openSync(file, 'r');
  try {
    const size = fs.fstatSync(fd).size;
    const decoder = new StringDecoder('utf8');
    const buf = Buffer.allocUnsafe(CHUNK);
    let read = 0;
    let carry = '';
    let stopped = false;
    while (read < maxScan) {
      const want = Math.min(CHUNK, maxScan - read);
      const got = fs.readSync(fd, buf, 0, want, null);
      if (got === 0) break;
      read += got;
      carry += decoder.write(buf.subarray(0, got));
      for (;;) {
        const at = carry.indexOf('\n');
        if (at < 0) break;
        const line = carry.slice(0, at);
        carry = carry.slice(at + 1);
        if (onLine(line) === false) { stopped = true; break; }
      }
      if (stopped) break;
    }
    if (!stopped) {
      carry += decoder.end();
      // A trailing fragment is a real record only when the read actually reached EOF;
      // at the cap it is the truncated head of a line that was never observed.
      if (carry.length > 0 && read >= size && onLine(carry) === false) stopped = true;
    }
    return { read, size, truncated: !stopped && read < size, stopped };
  } finally {
    fs.closeSync(fd);
  }
}

// One JSONL line -> a plain object, or null when the line is blank, malformed, or not an
// object. Never throws: a corrupt line is data, not an error.
function parseLine(line) {
  const text = String(line).trim();
  if (text === '') return null;
  let value;
  try {
    value = JSON.parse(text);
  } catch { return null; }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return null;
  return value;
}

// The identity of a title, normalized so that the stub side and the counterpart side
// produce byte-identical keys. Both fields participate: the same title text under a
// different sessionId is a different title and must not be covered by accident.
function titleKey(record) {
  return JSON.stringify([String(record.sessionId), String(record.customTitle)]);
}

// True when the record is a well-formed custom-title carrying only known fields.
function isKnownTitleRecord(record) {
  if (record.type !== TITLE_RECORD_TYPE) return false;
  if (typeof record.sessionId !== 'string' || typeof record.customTitle !== 'string') return false;
  for (const field of Object.keys(record)) {
    if (!KNOWN_TITLE_FIELDS.has(field)) return false;
  }
  return true;
}

function isMatchingContentRecord(record, sessionId) {
  return CONTENT_RECORD_TYPES.has(record.type) && record.sessionId === sessionId;
}

// Can `counterpartFile` stand in for a stub whose title keys are `stubTitleKeys`?
// Returns { ok: true } only when BOTH halves hold: the counterpart carries a content
// record for this session (I2 — titles alone are not a transcript) and every one of the
// stub's title keys (I3 — superset). Every other outcome names why, so the caller can
// tell a decision reached (`title-not-covered`, `no-content`) from an observation that
// failed (`unreadable`, `verify-truncated`).
function verifyCounterpart(counterpartFile, stubTitleKeys, sessionId) {
  const wanted = new Set(stubTitleKeys || []);
  const sid = String(sessionId);
  let hasContent = false;
  let scan;
  try {
    scan = scanLines(counterpartFile, VERIFY_MAX_SCAN, (line) => {
      const record = parseLine(line);
      if (record === null) return true;
      if (record.type === TITLE_RECORD_TYPE) {
        wanted.delete(titleKey(record));
      } else if (isMatchingContentRecord(record, sid)) {
        hasContent = true;
      }
      // Never stops early: a title may be the very last line of the file.
      return true;
    });
  } catch (error) {
    return { ok: false, reason: 'unreadable', code: error.code || 'EIO' };
  }

  // Checked first and unconditionally: a file that was not read in full cannot support
  // a claim about what it does or does not contain, however much was seen.
  if (scan.truncated) return { ok: false, reason: 'verify-truncated' };
  if (!hasContent) return { ok: false, reason: 'no-content' };
  if (wanted.size > 0) return { ok: false, reason: 'title-not-covered' };
  return { ok: true };
}

module.exports = {
  TITLE_RECORD_TYPE,
  CONTENT_RECORD_TYPES,
  KNOWN_TITLE_FIELDS,
  VERIFY_MAX_SCAN,
  CHUNK,
  scanLines,
  parseLine,
  titleKey,
  isKnownTitleRecord,
  isMatchingContentRecord,
  verifyCounterpart,
};
