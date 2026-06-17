"use strict";

// Parse Codex adversarial-review output. The Codex stdout is wrapped between
// `<!-- begin-codex-output ... -->` and `<!-- end-codex-output -->` markers
// (the begin marker may carry an attribute suffix). Content between the
// markers is JSON Lines, one verdict per line.

const VALID_VERDICTS = new Set(["AGREE", "DISAGREE"]);

function parseCodexFindings(stdout) {
  if (typeof stdout !== "string") {
    return { ok: false, items: [], warnings: ["stdout is not a string"] };
  }

  const beginMatch = stdout.match(/<!--\s*begin-codex-output[^>]*-->/);
  const endMatch = stdout.match(/<!--\s*end-codex-output\s*-->/);
  if (!beginMatch || !endMatch || endMatch.index < beginMatch.index) {
    return { ok: false, items: [], warnings: ["no codex markers found"] };
  }

  const start = beginMatch.index + beginMatch[0].length;
  const content = stdout.slice(start, endMatch.index);

  const items = [];
  const warnings = [];
  const lines = content.split(/\r?\n/);

  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i].trim();
    if (raw.length === 0) continue;
    let obj;
    try {
      obj = JSON.parse(raw);
    } catch (e) {
      return { ok: false, items: [], warnings: [`malformed JSON at line ${i + 1}: ${e.message}`] };
    }
    if (!obj || typeof obj !== "object" || Array.isArray(obj)) {
      return { ok: false, items: [], warnings: [`malformed JSON at line ${i + 1}: not an object`] };
    }
    if (!Number.isInteger(obj.idx)) {
      warnings.push(`line ${i + 1}: idx missing or not an integer; treating as AGREE`);
      continue;
    }
    let verdict = obj.verdict;
    if (typeof verdict !== "string" || !VALID_VERDICTS.has(verdict)) {
      warnings.push(`line ${i + 1}: invalid verdict ${JSON.stringify(verdict)}; treating as AGREE`);
      verdict = "AGREE";
    }
    const reason = typeof obj.reason === "string" ? obj.reason : "";
    items.push({ idx: obj.idx, verdict, reason });
  }

  return { ok: true, items, warnings };
}

module.exports = { parseCodexFindings };
