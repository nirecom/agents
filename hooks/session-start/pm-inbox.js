"use strict";
// SessionStart (#2942): a PM session's inbox (bin/pm-notify inbox) for additionalContext. Only a session
// whose state carries the `pm` mark runs it; budgetMs is the hook's remaining slice (min(2000, remaining)).
// Fail-open: with no time left, or on any error, one line says it runs at the next PM command.

const path = require("path");
const io = require("../workflow-state/state-io");
const S = require("../pm-session/schema");

const LATER = "[pm-inbox] skipped at session start; it runs at the next PM command";

// pmInboxLines(sid, budgetMs) -> the lines to add (a leading blank line included), or [].
function pmInboxLines(sid, budgetMs) {
  try {
    if (!sid || !io.SESSION_ID_VALID_RE.test(sid) || !S.hasPmMark(io.readRawState(sid))) return [];
  } catch (_) {
    return [];
  }
  if (!(budgetMs > 0)) return ["", LATER];
  try {
    const { runInbox } = require(path.join(__dirname, "..", "..", "bin", "lib", "pm-notify", "inbox"));
    const text = runInbox(sid, { budgetMs, drift: true });
    return text ? [""].concat(text.split("\n")) : [];
  } catch (_) {
    return ["", LATER];
  }
}

module.exports = { pmInboxLines };
