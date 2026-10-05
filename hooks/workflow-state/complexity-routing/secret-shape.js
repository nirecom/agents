"use strict";
// isSecretShaped(token) -> boolean. Detects tokens matching a known provider
// hard-secret shape. redactSecretShaped(text) -> string. Replaces every match of
// the same shapes with REDACTED_PLACEHOLDER — wherever it sits, exactly as the
// scanner reports it — and a PEM private key as a whole block.
// The shapes are HARD_SECRET_PATTERNS in bin/scan-outbound.sh (the SSOT), read
// in-process on first use rather than shelling out, because this runs on the hot
// per-invocation CLI path (#2099 Finding A). An unreadable or empty pattern set
// throws: a caller must never mistake "no patterns" for "nothing secret".
const fs = require("fs");
const path = require("path");

const SCANNER_PATH = path.resolve(__dirname, "..", "..", "..", "bin", "scan-outbound.sh");
const BEGIN_MARKER = "# BEGIN hard-secret-patterns";
const END_MARKER = "# END hard-secret-patterns";
const ENTRY_RE = /^\s*'(\S+) (\S+) ([^']+)'\s*$/;
const PEM_LABEL = "private-key";
const REDACTED_PLACEHOLDER = "[REDACTED]";

function parsePatterns(source) {
  const lines = source.split(/\r?\n/);
  const begin = lines.indexOf(BEGIN_MARKER);
  const end = lines.indexOf(END_MARKER);
  if (begin === -1 || end <= begin) throw new Error(`hard-secret pattern block not found in ${SCANNER_PATH}`);
  const patterns = [];
  for (const line of lines.slice(begin + 1, end)) {
    if (!line.trim().startsWith("'")) continue;
    const m = ENTRY_RE.exec(line);
    if (!m) throw new Error(`malformed hard-secret pattern entry in ${SCANNER_PATH}`);
    patterns.push({ label: m[1], re: new RegExp(m[3]) });
  }
  if (patterns.length === 0) throw new Error(`no hard-secret patterns in ${SCANNER_PATH}`);
  return patterns;
}

// The header through the matching END line, or to the end of the text when END is absent.
function redactRegex({ label, re }) {
  if (label !== PEM_LABEL) return new RegExp(re.source, "g");
  return new RegExp(`${re.source}[\\s\\S]*?(?:${re.source.replace("BEGIN", "END")}|$)`, "g");
}

let cache = null;
function loaded() {
  if (cache === null) {
    const patterns = parsePatterns(fs.readFileSync(SCANNER_PATH, "utf8"));
    cache = { detect: patterns.map((p) => p.re), redact: patterns.map(redactRegex) };
  }
  return cache;
}

function isSecretShaped(token) {
  return loaded().detect.some((re) => re.test(token));
}

// File order is the scanner's order, so an Anthropic key is gone before the OpenAI sk- pass.
function redactSecretShaped(text) {
  const { redact } = loaded();
  if (typeof text !== "string") return "";
  return redact.reduce((t, re) => t.replace(re, REDACTED_PLACEHOLDER), text);
}

module.exports = { isSecretShaped, redactSecretShaped, REDACTED_PLACEHOLDER };
