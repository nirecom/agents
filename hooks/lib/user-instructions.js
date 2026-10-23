"use strict";
// Provider for the user-local instruction channel (#2240 Change 4): user-instructions.local.md at
// the agents checkout root (beside .env and CLAUDE.local.md, gitignored). Injected at SessionStart
// and PostCompact only. Design: docs/architecture/claude-code/lang-directives.md.

const fs = require("fs");
const path = require("path");

const USER_INSTRUCTIONS_FILE = path.join(__dirname, "..", "..", "user-instructions.local.md");
const MAX_BYTES = 4096;
const HEADER = "[user-instructions]";
const TRUNCATED_MARK = `[user-instructions truncated at ${MAX_BYTES} bytes]`;

// Cut at MAX_BYTES, backing off over UTF-8 continuation bytes so no character is split.
function cutUtf8(buf) {
  let end = MAX_BYTES;
  while (end > 0 && (buf[end] & 0xc0) === 0x80) end -= 1;
  return buf.subarray(0, end).toString("utf8");
}

// The header line plus the file content, or null when the file is missing, unreadable or blank.
function getUserInstructionsInjection() {
  let buf;
  try {
    buf = fs.readFileSync(USER_INSTRUCTIONS_FILE);
  } catch (_) {
    return null;
  }
  const truncated = buf.length > MAX_BYTES;
  const body = (truncated ? cutUtf8(buf) : buf.toString("utf8")).trimEnd();
  if (body.trim().length === 0) return null;
  return [HEADER, body].concat(truncated ? [TRUNCATED_MARK] : []).join("\n");
}

module.exports = { USER_INSTRUCTIONS_FILE, getUserInstructionsInjection };
