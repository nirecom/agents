"use strict";
// Hard secrets: provider API keys and tokens (Gitleaks-derived). The single source of truth read
// by the outbound scanner (scan-line.js) and by complexity-routing/secret-shape.js.
// Entry: { label, group, ere } — ere is valid in both POSIX ERE and JS RegExp. Entries sharing a
// group (not "-") test one work line in order, each match removed before the next: Anthropic is
// checked before OpenAI because both start sk- and Anthropic is more specific.
// Values are assembled from parts so this file never matches its own patterns.

const DASHES = "-".repeat(5);

const HARD_SECRET_PATTERNS = [
  { label: "anthropic-key", group: "sk", ere: ["sk", "ant", "(api|sid)[0-9]{2}", "[A-Za-z0-9_-]{20,}"].join("-") },
  { label: "openai-key", group: "sk", ere: ["sk", "(proj-|svcacct-)?[A-Za-z0-9_-]{20,}"].join("-") },
  { label: "aws-key", group: "-", ere: ["AK", "IA", "[0-9A-Z]{16}"].join("") },
  { label: "private-key", group: "-", ere: `${DASHES}BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY${DASHES}` },
  { label: "github-token", group: "-", ere: ["gh", "[pousr]_", "[A-Za-z0-9]{36,}"].join("") },
  { label: "slack-token", group: "-", ere: ["xo", "x[baprs]-", "[0-9]+-[0-9]+-[A-Za-z0-9]+"].join("") },
  { label: "google-key", group: "-", ere: ["AI", "za", "[0-9A-Za-z_-]{35}"].join("") },
  { label: "huggingface-token", group: "-", ere: ["h", "f_", "[A-Za-z0-9]{34,}"].join("") },
  { label: "groq-key", group: "-", ere: ["gs", "k_", "[A-Za-z0-9]{20,}"].join("") },
  { label: "replicate-token", group: "-", ere: ["r", "8_", "[A-Za-z0-9]{37}"].join("") },
  { label: "cohere-key", group: "-", ere: ["c", "o_", "[A-Za-z0-9]{40}"].join("") },
];

module.exports = { HARD_SECRET_PATTERNS };
