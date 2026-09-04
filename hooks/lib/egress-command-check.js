// commandIsEgressTool(line) — true when a line can move data off the machine or
// mint a credential to do so: curl/wget, scp/ssh/rsync-to-remote, nc/netcat,
// `gh auth token`, `gh secret ...`.
// Consumer: hooks/preuse-auto-approve/script-body-scan.js — scan-outbound.js
// never sees a script body, so exfiltration from inside one is answered suspect
// instead of auto-approved.
"use strict";

const EGRESS_CMD_RE =
  /(?:^|[\s;|&(])(?:curl|curl\.exe|wget|scp|sftp|ssh|telnet|nc|ncat|netcat)(?=\s|$)/;
const GH_CREDENTIAL_RE = /(?:^|[\s;|&(])gh(?:\.exe)?\s+(?:auth\s+token|secret)(?=\s|$)/;
// Local-only `rsync /a /b` stays approvable; a `user@host:` operand does not.
const RSYNC_REMOTE_RE = /(?:^|[\s;|&(])rsync(?=\s)[\s\S]*\s\S+@\S+:/;

function commandIsEgressTool(line) {
  if (typeof line !== "string" || line === "") return false;
  return EGRESS_CMD_RE.test(line) || GH_CREDENTIAL_RE.test(line) || RSYNC_REMOTE_RE.test(line);
}

module.exports = { commandIsEgressTool };
