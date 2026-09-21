"use strict";
// Migration dispatch for a freshly-parsed state object. Entrypoint-private to
// state-io.js; called from core.js normalizeStateVersion().
//
// Stages live in ./migrations/ — this file only orders and re-exports them.

const { applyV1FieldBackfill } = require("./migrations/v1-field-backfill");
const {
  migrateV1ToV2,
  orderedAnnotationKeys,
  convertV1AnnotationsToEvents,
} = require("./migrations/v1-to-v2");
const { migrateV2ToV3 } = require("./migrations/v2-to-v3");
const { migrateV3ToV4 } = require("./migrations/v3-to-v4");

module.exports = {
  applyV1FieldBackfill,
  migrateV1ToV2,
  migrateV2ToV3,
  migrateV3ToV4,
  orderedAnnotationKeys,
  convertV1AnnotationsToEvents,
};
