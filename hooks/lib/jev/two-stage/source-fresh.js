"use strict";
// hooks/lib/jev/two-stage/source-fresh.js — whether a ticket's stage sources are still the
// bytes its judgment was made from (#2460). A judgment is about the sources as queried; one
// consumed after an edit describes a plan that no longer exists, so every consumer settles on
// the conservative side instead (the stage runs; complexity takes its fail-safe level).

const path = require("path");

const { sha256 } = require("./paths");
const { MAX_ARTIFACT_READ_BYTES, artifactPathsFor, readCappedBytes } = require(
  path.join(__dirname, "..", "..", "..", "..", "bin", "workflow", "lib", "jev-request-common.js"));

// The sha256 of one whole artifact; null when it is over the read cap (never a prefix hash).
function artifactSha(read) {
  return read.over_cap ? null : sha256(read.bytes);
}

// sourcesChanged(sid, stage, recorded {section: sha256|null}) -> true unless every source
// artifact of the stage exists now exactly as recorded at query time. Anything that cannot be
// verified — no record, an unhashed (over-cap) or unreadable artifact, a source that appeared
// or vanished — reads as changed.
function sourcesChanged(sid, stage, recorded) {
  if (!recorded || typeof recorded !== "object" || Array.isArray(recorded)) return true;
  const now = {};
  try {
    for (const art of artifactPathsFor(sid, stage)) {
      const sha = artifactSha(readCappedBytes(art.file, MAX_ARTIFACT_READ_BYTES));
      if (sha === null) return true;
      now[art.section] = sha;
    }
  } catch (_e) {
    return true;
  }
  const was = Object.keys(recorded);
  return was.length !== Object.keys(now).length || was.some((s) => typeof recorded[s] !== "string" || recorded[s] !== now[s]);
}

module.exports = { artifactSha, sourcesChanged };
