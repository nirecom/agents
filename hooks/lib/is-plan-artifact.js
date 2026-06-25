"use strict";

const TIMESTAMP_RE = /^[0-9]{8}-[0-9]{6}-(intent|outline|detail)\.md$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-(intent|outline|detail)\.md$/i;

function isPlanArtifact(basename) {
  return TIMESTAMP_RE.test(basename) || UUID_RE.test(basename);
}

module.exports = { isPlanArtifact };
