"use strict";
// The SendMessage destination branch of find-peer (#2668; docs/architecture/cross-session-messaging.md).
// Verification (b) result, observed 2026-11-09 on Claude Code 2.1.319:
//   - ListAgents rows read "<name> [<ref6hex>]"; no session id is listed.
//   - SendMessage `to` takes the bare name; sending "<name> [<ref>]" for one's own session was refused
//     as "also addresses this session" (the [ref] is appended only to disambiguate).
//   => branch 3 (name). The name is the session title, so it must carry the " [xxxxxxxx]" suffix.
// A reply addressed to an incoming message's `from` attribute is NOT yet verified end to end.
//   DESTINATION_KIND     "session-id" | "ref" | "name" — what SendMessage accepts as `to`.
//   FROM_REPLY_VERIFIED  true only when verification (b) showed a reply addressed to `from` arrives.
module.exports = { DESTINATION_KIND: "name", FROM_REPLY_VERIFIED: false };
