"use strict";
// SSOT for the session-id announce line that SessionStart / PostCompact inject
// into the transcript, and that the lineage reader later parses back out.
//
// WHY a module: the literal was generated in hooks/session-start.js and
// hooks/post-compact.js and re-parsed by two independent copies of the same
// regex. The string is a BACKWARD-COMPATIBILITY contract — transcripts written
// by older builds must stay readable — so it must never drift between the
// writer and the reader (CPR-SSOT).
//
// Do not change the text.

const SESSION_ID_ANNOUNCE_PREFIX = "Current workflow session_id: ";

// The transcript embeds the announce line inside a JSON-encoded hook stdout, so
// the id is followed by whatever JSON punctuation closed the string (`"}` etc.).
// Matching the session-id CHARSET rather than a terminator set is what keeps
// that punctuation out of the capture — see SESSION_ID_VALID_RE in state-io.
const SESSION_ID_ANNOUNCE_RE = /Current workflow session_id:\s*([A-Za-z0-9_-]+)/;

module.exports = { SESSION_ID_ANNOUNCE_PREFIX, SESSION_ID_ANNOUNCE_RE };
