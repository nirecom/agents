"use strict";
// Provider for the user-local instruction channel (#2240 Change 4): user-instructions.md at the
// agents checkout root (beside .env and CLAUDE.local.md, gitignored; template: user-instructions.example.md).
// Injected at SessionStart and PostCompact only. Design: docs/architecture/claude-code/lang-directives.md.

const fs = require("fs");
const path = require("path");

const USER_INSTRUCTIONS_FILE = path.join(__dirname, "..", "..", "user-instructions.md");
const MAX_BYTES = 4096;
const HEADER = "[user-instructions]";
const TRUNCATED_MARK = `[user-instructions truncated at ${MAX_BYTES} bytes]`;

// Cut at MAX_BYTES, backing off over UTF-8 continuation bytes so no character is split.
function cutUtf8(buf) {
  let end = MAX_BYTES;
  while (end > 0 && (buf[end] & 0xc0) === 0x80) end -= 1;
  return buf.subarray(0, end).toString("utf8");
}

// Comments are stripped before the cap, so a comment closing past MAX_BYTES never leaks;
// an unclosed <!-- swallows the rest of the file.
function stripComments(text) {
  return text.replace(/<!--[\s\S]*?-->/g, "").replace(/<!--[\s\S]*$/, "");
}

// The header line plus the comment-free content, or null when the file is missing, unreadable or blank.
function getUserInstructionsInjection() {
  let text;
  try {
    text = fs.readFileSync(USER_INSTRUCTIONS_FILE, "utf8");
  } catch {
    return null;
  }
  const stripped = stripComments(text);
  if (stripped.trim().length === 0) return null;
  const buf = Buffer.from(stripped, "utf8");
  const truncated = buf.length > MAX_BYTES;
  const body = (truncated ? cutUtf8(buf) : stripped).trimEnd();
  return [HEADER, body].concat(truncated ? [TRUNCATED_MARK] : []).join("\n");
}

module.exports = { USER_INSTRUCTIONS_FILE, getUserInstructionsInjection };
