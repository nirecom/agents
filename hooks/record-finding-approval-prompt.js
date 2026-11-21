#!/usr/bin/env node
// UserPromptSubmit hook — writer 1 of the finding-filing approval record (#2019 S1-2).
// The model cannot fire UserPromptSubmit, so a typed-command record written here proves a human
// typed /issue-create. Every prompt resets the file: one typed-command record when the prompt
// invokes /issue-create, otherwise the file is removed, so an approval lives until the next prompt.
// The prompt text is never recorded. Fail-open: every error path exits 0.
// Contract: lib/finding-approval.js.
"use strict";

const fs = require("fs");
const { readHookInput } = require("./lib/read-stdin");
const { promptInvokesFilingSkill, writeTypedCommand, removeApprovalFile } = require("./lib/finding-approval");

const SID_RE = /^[A-Za-z0-9_-]+$/;

if (require.main === module) {
  try {
    const r = readHookInput();
    const input = r.kind === "ok" ? r.input : null;
    const sid = input && typeof input.session_id === "string" ? input.session_id : null;
    if (sid && SID_RE.test(sid)) {
      const prompt = typeof input.prompt === "string" ? input.prompt : "";
      if (promptInvokesFilingSkill(prompt)) writeTypedCommand(sid);
      else removeApprovalFile(sid);
    }
  } catch (_e) { /* fail-open */ }
  try { fs.writeSync(1, JSON.stringify({}) + "\n"); } catch (_e) { /* fail-open */ }
}
