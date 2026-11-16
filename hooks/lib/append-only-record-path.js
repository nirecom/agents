// The append-only records (repo-relative): their past wording is never rewritten, so the
// glossary drift check and the residue checks leave them out. Case-sensitive, root-anchored.
// Directory entries end in "/" and match a file below them; the others match by equality.
"use strict";

const APPEND_ONLY_RECORD_PATHS = Object.freeze([
  "docs/changelog/",
  "docs/history/",
  "docs/history.md",
  "CHANGELOG.md",
]);

function normalize(rel) {
  let p = rel.replace(/\\/g, "/");
  while (p.startsWith("./")) p = p.slice(2);
  return p;
}

function isAppendOnlyRecordPath(rel) {
  if (typeof rel !== "string" || rel === "") return false;
  const p = normalize(rel);
  return APPEND_ONLY_RECORD_PATHS.some((entry) =>
    entry.endsWith("/") ? p.startsWith(entry) && p.length > entry.length : p === entry,
  );
}

module.exports = { APPEND_ONLY_RECORD_PATHS, isAppendOnlyRecordPath };
