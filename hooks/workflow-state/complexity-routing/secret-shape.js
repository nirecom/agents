"use strict";
// isSecretShaped(token) -> boolean. Detects tokens matching known provider
// hard-secret shapes, mirroring the Gitleaks-derived patterns already
// canonical in bin/scan-outbound.sh (Anthropic/OpenAI/AWS/PEM/GitHub/Slack/
// Google/HuggingFace). Reused in-process (not shelled out to the bash
// scanner) because this runs on the hot per-invocation CLI path shared by
// every workflow session (#2099 Finding A) — keep both pattern sets in sync
// if scan-outbound.sh's hard-secret list changes.
const SECRET_SHAPE_PATTERNS = [
  /sk-ant-(api|sid)\d{2}-[A-Za-z0-9_-]{20,}/,
  /sk-(proj-|svcacct-)?[A-Za-z0-9_-]{20,}/,
  /AKIA[0-9A-Z]{16}/,
  /-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----/,
  /gh[pousr]_[A-Za-z0-9]{36,}/,
  /xox[baprs]-\d+-\d+-[A-Za-z0-9]+/,
  /AIza[0-9A-Za-z_-]{35}/,
  /hf_[A-Za-z0-9]{34,}/,
];

function isSecretShaped(token) {
  return SECRET_SHAPE_PATTERNS.some((re) => re.test(token));
}

module.exports = { isSecretShaped };
