"use strict";
// Repo settings file (.agents.json) reader: dispatch and re-export only (Pattern A).
// Hooks call it directly; bash reaches it through bin/repo-settings and bin/lib/repo-settings.sh.
// Schema and state meanings: docs/architecture/claude-code/repo-settings-file.md.

const L = require("./repo-settings/load");
const V = require("./repo-settings/validate");
const P = require("./repo-settings/placement");

module.exports = {
  FILE_NAME: L.FILE_NAME,
  CURRENT_SETTINGS_VERSION: V.CURRENT_SETTINGS_VERSION,
  MAX_KNOWN_SETTINGS_VERSION: V.MAX_KNOWN_SETTINGS_VERSION,
  CATEGORIZATIONS: V.CATEGORIZATIONS,
  MIGRATE_KEYS: V.MIGRATE_KEYS,
  load: L.load,
  readDoc: L.readDoc,
  fileOf: L.fileOf,
  nativePath: L.nativePath,
  migrateDone: L.migrateDone,
  validateTests: V.validateTests,
  validateDoc: V.validateDoc,
  placementIn: P.placementIn,
  placementOf: P.placementOf,
  testDirsIn: P.testDirs,
  testDirs: P.testDirsOf,
};
