"use strict";

// Frozen SSOT for every "cannot resolve this command" verdict the guard emits
// (CPR-SSOT). The KEY is the machine-readable code that the reason text must
// contain; the VALUE is the human sentence shown in the permission prompt.
// Nothing else in the guard may invent a code — an unmodeled shape falls into
// one of these eleven buckets or it is not unresolved at all.
const REASONS = Object.freeze({
  "multi-command-body": "multi-command-body: the nested command body runs more than one command, so the forge target cannot be attributed",
  "quoted-newline-in-body": "quoted-newline-in-body: a quoted span carries a newline around a gh write, so the command list cannot be split reliably",
  "ansic-span": "ansic-span: an ANSI-C quoted ($'...') span sits in command position, so the executed text is not the literal text",
  "unmodeled-body-quoting": "unmodeled-body-quoting: the quoting around an executed body is not modeled, so its contents cannot be read",
  "body-missing": "body-missing: an interpreter was handed a program body the guard cannot see",
  "depth-cap": "depth-cap: nested command bodies exceed the scan depth cap",
  "language-interpreter-body": "language-interpreter-body: a language interpreter may emit a gh write the guard cannot read",
  "wrapper-peeled-body": "wrapper-peeled-body: the executed body sits behind a wrapper whose options are not modeled",
  "command-substitution-body": "command-substitution-body: a command substitution may run a gh write the guard cannot attribute",
  "auth-context-change": "auth-context-change: the GitHub authentication context is being changed, so the acting identity cannot be proven",
  "unrecognized-wrapper-head": "unrecognized-wrapper-head: an interpreter appears in argument position, so the executed program is not modeled",
});

const REASON_CODES = Object.freeze(Object.keys(REASONS));

function reasonText(code) {
  return REASONS[code] || code;
}

module.exports = { REASONS, REASON_CODES, reasonText };
