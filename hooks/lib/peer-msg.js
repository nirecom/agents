"use strict";
// The [peer-msg v1] header and [peer-ack v1] ack of cross-session messages (#2668). The one
// definition of both formats; bin/peer-msg uses it. Design: docs/architecture/cross-session-messaging.md.
//   header: [peer-msg v1] from-session=<id> msg-id=<uuid> reply-to=<dest> reply-kind=<kind>[ role=pm pm-issues=#A,#B]
//   ack:    [peer-ack v1] ack-of=<msg-id> session=<id>

const REPLY_KINDS = ["session-id", "ref", "name", "from"];
const SID = "[A-Za-z0-9_-]+";
const UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const PM_ISSUES_RE = /^[A-Za-z0-9_./-]*#[1-9][0-9]*(?:,[A-Za-z0-9_./-]*#[1-9][0-9]*)*$/;
const HEADER_RE = new RegExp(`^\\[peer-msg v1\\] from-session=(${SID}) msg-id=(${UUID}) reply-to=(.+?) reply-kind=(${REPLY_KINDS.join("|")})(?: role=(pm) pm-issues=(\\S+))?\\r?$`);
const ACK_RE = new RegExp(`^\\[peer-ack v1\\] ack-of=(${UUID}) session=(${SID})\\r?$`);
// eslint-disable-next-line no-control-regex
const CONTROL_RE = /[\u0000-\u001f\u007f]/;

// formatHeader({fromSession, msgId, replyTo, replyKind, role?, pmIssues?}) -> the header line;
// throws on a field that would not parse back.
function formatHeader(h) {
  const base = `[peer-msg v1] from-session=${h.fromSession} msg-id=${h.msgId} reply-to=${h.replyTo} reply-kind=${h.replyKind}`;
  const text = h.role ? `${base} role=${h.role} pm-issues=${h.pmIssues}` : base;
  if (CONTROL_RE.test(text) || !parseHeader(text)) throw new Error("peer-msg: a header field is malformed");
  return text;
}

// parseHeader(text) -> {fromSession, msgId, replyTo, replyKind[, role, pmIssues]} of the first line, or null.
function parseHeader(text) {
  const m = HEADER_RE.exec(String(text).split("\n")[0]);
  if (!m) return null;
  if (m[5] && !PM_ISSUES_RE.test(m[6])) return null;
  const h = { fromSession: m[1], msgId: m[2], replyTo: m[3], replyKind: m[4] };
  if (m[5]) Object.assign(h, { role: m[5], pmIssues: m[6] });
  return h;
}

function formatAck(a) {
  const text = `[peer-ack v1] ack-of=${a.ackOf} session=${a.session}`;
  if (!parseAck(text)) throw new Error("peer-msg: an ack field is malformed");
  return text;
}

// parseAck(text) -> {ackOf, session} when text is exactly one ack line, else null.
function parseAck(text) {
  const m = ACK_RE.exec(String(text));
  return m ? { ackOf: m[1], session: m[2] } : null;
}

module.exports = { REPLY_KINDS, PM_ISSUES_RE, formatHeader, parseHeader, formatAck, parseAck };
