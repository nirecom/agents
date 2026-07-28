// I2, the content-record proof: a stub may only be deleted once ANOTHER file has been
// shown to hold a real transcript record tagged with the same sessionId. Deletion needs
// that positive evidence and nothing less. Nothing here deletes, and nothing here
// decides — it only reports what could be observed, so that the caller can refuse on
// anything short of a clean `ok`.
//
// Title TEXT is deliberately not a matching key. Titles are renamed by hand, and a
// rename is appended only to the copy in whichever project directory the extension held
// to be current at that moment; once work moves into a linked worktree the stub and the
// real transcript accumulate title records independently, so neither side is ever a
// superset of the other. Requiring one would refuse nearly every genuine pair.
//
// The counterpart is never written to. After the stub is deleted the counterpart's own
// title stands — its latest `custom-title` if it has one, otherwise the system-assigned
// default — and titles that existed only on the stub are discarded, not migrated.
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

// Every content type names the FIELD that carries its payload, and what that field has
// to look like. A record of a content type without that field is a shell, not a
// transcript: `{"type":"user","sessionId":"<uuid>"}` is 60 bytes anyone can write, and
// treating it as evidence would let it authorise an unrecoverable delete. A Map rather
// than an object literal so that a record whose `type` is `constructor` or `__proto__`
// cannot inherit a match from Object.prototype.
const CONTENT_PAYLOAD = new Map([
  ['user', (record) => isPayloadObject(record.message)],
  ['assistant', (record) => isPayloadObject(record.message)],
  ['summary', (record) => typeof record.summary === 'string' && record.summary !== ''],
]);
// A title record carrying anything outside this set holds information whose presence in
// a counterpart cannot be proven, so it must block the `stub` verdict.
const KNOWN_TITLE_FIELDS = new Set(['type', 'sessionId', 'customTitle']);

// A successful verification usually stops at the first matching content record, so this
// budget bounds the WORST case instead: a large file that is read to EOF because no
// matching content record is ever found. It is still bounded — an unbounded read on a
// session store measured in gigabytes is a denial of service on the user.
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

// A message payload: an object, and neither null nor an array. Shape only — an empty
// object is still a message, because the rule is that the field is a payload slot, not
// that its contents are interesting.
function isPayloadObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

// True when the record is a well-formed custom-title carrying only known fields AND
// naming `sessionId` as its own session. Ownership is folded into the predicate rather
// than left to the call site: a title for ANOTHER session is information this tool
// cannot account for, and a signature that could be called without the session id is a
// signature a call site can forget to check.
function isOwnTitleRecord(record, sessionId) {
  if (record.type !== TITLE_RECORD_TYPE) return false;
  if (typeof record.sessionId !== 'string' || typeof record.customTitle !== 'string') return false;
  if (record.sessionId !== sessionId) return false;
  for (const field of Object.keys(record)) {
    if (!KNOWN_TITLE_FIELDS.has(field)) return false;
  }
  return true;
}

// True only when the record is a transcript record for THIS session: the right type, the
// right session id, and the payload its type promises.
function isMatchingContentRecord(record, sessionId) {
  const carriesPayload = CONTENT_PAYLOAD.get(record.type);
  if (carriesPayload === undefined) return false;
  if (record.sessionId !== sessionId) return false;
  return carriesPayload(record);
}

// Can `counterpartFile` stand in for a stub of this session? Returns { ok: true } on the
// single remaining condition: the counterpart carries a content record for this session
// (I2 — titles alone are not a transcript). Every other outcome names why, so the caller
// can tell a decision reached (`no-content`) from an observation that failed
// (`unreadable`, `verify-truncated`).
function verifyCounterpart(counterpartFile, sessionId) {
  const sid = String(sessionId);
  let hasContent = false;
  let scan;
  try {
    scan = scanLines(counterpartFile, VERIFY_MAX_SCAN, (line) => {
      const record = parseLine(line);
      if (record === null) return true;
      if (isMatchingContentRecord(record, sid)) {
        hasContent = true;
        // The evidence sought is existential, so it is complete the moment it is seen:
        // no later line in the file could retract a record already observed.
        return false;
      }
      return true;
    });
  } catch (error) {
    return { ok: false, reason: 'unreadable', code: error.code || 'EIO' };
  }

  // Checked first and unconditionally: a file that was not read in full cannot support
  // a claim about what it does or does not contain, however much was seen.
  if (scan.truncated) return { ok: false, reason: 'verify-truncated' };
  if (!hasContent) return { ok: false, reason: 'no-content' };
  return { ok: true };
}

module.exports = {
  TITLE_RECORD_TYPE,
  CONTENT_PAYLOAD,
  KNOWN_TITLE_FIELDS,
  VERIFY_MAX_SCAN,
  CHUNK,
  scanLines,
  parseLine,
  titleKey,
  isPayloadObject,
  isOwnTitleRecord,
  isMatchingContentRecord,
  verifyCounterpart,
};
