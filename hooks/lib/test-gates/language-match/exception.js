"use strict";
// The Tags: test-lang-exception declaration (#2507 D7; ports tlm_lang_exception of
// bin/lib/test-language-match.sh). langException(file, name) -> { ok, value, bad }: ok with value
// "" (none) or one listed value; not ok with bad holding the values read, comma-joined.

const R = require("../registry");
const S = require("../source");
const { readHeaders } = require("../headers");

// csvAfter(line, label) — the trimmed, non-empty comma-separated values after "<label>:".
function csvAfter(line, label) {
  if (!line) return [];
  const at = line.indexOf(`${label}:`);
  const csv = at === -1 ? line : line.slice(at + label.length + 1);
  return csv.split(",").map((t) => t.trim()).filter(Boolean);
}

function headerTokens(file, name, which) {
  let text;
  try {
    text = S.textOf(file);
  } catch {
    text = "";
  }
  const h = readHeaders(text, name);
  return which === "tags" ? csvAfter(h.tags, "Tags") : csvAfter(h.tests, "Tests");
}

function langException(file, name) {
  const vals = headerTokens(file, name, "tags")
    .filter((t) => t.startsWith("test-lang-exception:"))
    .map((t) => t.slice("test-lang-exception:".length).trim());
  if (vals.length === 0) return { ok: true, value: "", bad: "" };
  const read = vals.join(",");
  if (vals.length === 1 && read && (R.reg().testLanguageExceptions || []).includes(read)) return { ok: true, value: read, bad: "" };
  return { ok: false, value: "", bad: read };
}

module.exports = { langException, headerTokens, csvAfter };
