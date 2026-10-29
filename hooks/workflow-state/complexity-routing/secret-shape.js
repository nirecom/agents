"use strict";
// isSecretShaped(token) -> boolean. Detects tokens matching a known provider
// hard-secret shape. redactSecretShaped(text) -> string. Replaces every match of
// the same shapes with REDACTED_PLACEHOLDER — wherever it sits, exactly as the
// scanner reports it — and a PEM private key as a whole block.
// The shapes are HARD_SECRET_PATTERNS in hooks/lib/outbound-scan/hard-secret-patterns.js,
// the SSOT the outbound scanner reads too (#2507). An unreadable or empty pattern set
// throws: a caller must never mistake "no patterns" for "nothing secret".
const path = require("path");

const SSOT_PATH = path.resolve(__dirname, "..", "..", "lib", "outbound-scan", "hard-secret-patterns.js");
const PEM_LABEL = "private-key";
const REDACTED_PLACEHOLDER = "[REDACTED]";

function readPatterns() {
  const { HARD_SECRET_PATTERNS } = require(SSOT_PATH);
  if (!Array.isArray(HARD_SECRET_PATTERNS) || HARD_SECRET_PATTERNS.length === 0) {
    throw new Error(`no hard-secret patterns in ${SSOT_PATH}`);
  }
  return HARD_SECRET_PATTERNS.map((h) => {
    if (!h || typeof h.label !== "string" || typeof h.ere !== "string" || h.ere === "") {
      throw new Error(`malformed hard-secret pattern entry in ${SSOT_PATH}`);
    }
    return { label: h.label, re: new RegExp(h.ere) };
  });
}

// The header through the matching END line, or to the end of the text when END is absent.
function redactRegex({ label, re }) {
  if (label !== PEM_LABEL) return new RegExp(re.source, "g");
  return new RegExp(`${re.source}[\\s\\S]*?(?:${re.source.replace("BEGIN", "END")}|$)`, "g");
}

let cache = null;
function loaded() {
  if (cache === null) {
    const patterns = readPatterns();
    cache = { detect: patterns.map((p) => p.re), redact: patterns.map(redactRegex) };
  }
  return cache;
}

function isSecretShaped(token) {
  return loaded().detect.some((re) => re.test(token));
}

// SSOT order is the scanner's order, so an Anthropic key is gone before the OpenAI sk- pass.
function redactSecretShaped(text) {
  const { redact } = loaded();
  if (typeof text !== "string") return "";
  return redact.reduce((t, re) => t.replace(re, REDACTED_PLACEHOLDER), text);
}

module.exports = { isSecretShaped, redactSecretShaped, REDACTED_PLACEHOLDER };
