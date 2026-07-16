"use strict";

/**
 * Emit a directive to stdout. All fields are KEY=VALUE on separate lines.
 * QUESTION and OPTIONS_DISPLAY must be percent-encoded (no raw spaces,
 * pipes, or newlines — third-party issue titles flow into both).
 */

function encode(str) {
  // percent-encode: encode everything that isn't unreserved in application/x-www-form-urlencoded
  // Use encodeURIComponent which covers spaces, quotes, pipes, etc.
  return encodeURIComponent(str);
}

function emitDone(ckptPath, pathDecision) {
  const lines = [
    `ACTION=done`,
    `CHECKPOINT=${ckptPath}`,
    `PATH_DECISION=${pathDecision}`,
  ];
  process.stdout.write(lines.join("\n") + "\n");
}

function emitAskUser(ckptPath, askId, question, optionsDisplay) {
  const lines = [
    `ACTION=ask_user`,
    `CHECKPOINT=${ckptPath}`,
    `QUESTION=${encode(question)}`,
    `ASK_ID=${askId}`,
    `OPTIONS_DISPLAY=${encode(optionsDisplay)}`,
  ];
  process.stdout.write(lines.join("\n") + "\n");
}

function emitBlocked(ckptPath, reason) {
  const lines = [
    `ACTION=blocked`,
    `CHECKPOINT=${ckptPath}`,
    `REASON=${reason}`,
  ];
  process.stdout.write(lines.join("\n") + "\n");
}

module.exports = { emitDone, emitAskUser, emitBlocked };
