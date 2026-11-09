"use strict";
// The SendMessage destination branch of find-peer (#2668). Observed on Claude Code 2.1.319, 2026-11-09:
// a bare "<title> [xxxxxxxx]" was unreachable, "<title> [xxxxxxxx] [<ref6>]" arrived, and a reply
// addressed to an incoming message's `from` arrived. Evidence: docs/architecture/cross-session-messaging.md §8.
//   DESTINATION_KIND     "session-id" | "ref" | "name" — what SendMessage accepts as `to`.
//   FROM_REPLY_VERIFIED  true: a reply addressed to `from` arrives.
module.exports = { DESTINATION_KIND: "name", FROM_REPLY_VERIFIED: true };
