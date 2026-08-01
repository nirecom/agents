"use strict";
// Barrel for the workflow state file I/O layer. Dispatch + re-export only —
// all logic lives in ./state-io/*. Consumers import from here, never from a
// submodule directly.

const core = require("./state-io/core");
const contextScan = require("./state-io/context-scan");
const reviewTests = require("./state-io/review-tests");
const sessionFields = require("./state-io/session-fields");
const zombieCleanup = require("./state-io/zombie-cleanup");
const skipVerdict = require("./state-io/skip-verdict");
const events = require("./state-io/events");
const intervals = require("./state-io/intervals");
const projection = require("./state-io/projection");
const stateLock = require("./state-io/state-lock");

module.exports = {
  VALID_STEPS: core.VALID_STEPS,
  TERMINAL_STEPS: core.TERMINAL_STEPS,
  SKIPPABLE_STEPS: core.SKIPPABLE_STEPS,
  VALID_STATUSES: core.VALID_STATUSES,
  getWorkflowDir: core.getWorkflowDir,
  getStatePath: core.getStatePath,
  assertValidSessionId: core.assertValidSessionId,
  SESSION_ID_VALID_RE: core.SESSION_ID_VALID_RE,
  readState: core.readState,
  readRawState: core.readRawState,
  normalizeStateVersion: core.normalizeStateVersion,
  persistMigratedState: core.persistMigratedState,
  writeState: core.writeState,
  updateTopLevel: core.updateTopLevel,
  createInitialState: core.createInitialState,
  getCurrentContext: core.getCurrentContext,
  resolveWorktreeContext: core.resolveWorktreeContext,
  findLatestStateForContext: contextScan.findLatestStateForContext,
  markStep: core.markStep,
  appendEvents: events.appendEvents,
  validateEvent: events.validateEvent,
  EVENT_KINDS: events.EVENT_KINDS,
  PROVENANCE_VALUES: events.PROVENANCE_VALUES,
  STEP_ANNOTATION_KEYS: events.STEP_ANNOTATION_KEYS,
  computeIntervals: intervals.computeIntervals,
  projectState: projection.projectState,
  stripProjection: projection.stripProjection,
  serializeStateForPersist: projection.serializeStateForPersist,
  PROJECTION_KEYS: projection.PROJECTION_KEYS,
  PERSISTED_TOP_LEVEL_KEYS: projection.PERSISTED_TOP_LEVEL_KEYS,
  UnknownStateKeyError: projection.UnknownStateKeyError,
  ProjectionMutatedError: projection.ProjectionMutatedError,
  withStateLock: stateLock.withStateLock,
  StateLockTimeoutError: stateLock.StateLockTimeoutError,
  recordComplexityEvaluation: sessionFields.recordComplexityEvaluation,
  recordSessionModel: sessionFields.recordSessionModel,
  markReviewTestsComplete: reviewTests.markReviewTestsComplete,
  clearReviewTestsWarnings: reviewTests.clearReviewTestsWarnings,
  clearReviewTestsTerminalMarker: reviewTests.clearReviewTestsTerminalMarker,
  invalidateReviewTests: reviewTests.invalidateReviewTests,
  cleanupZombies: zombieCleanup.cleanupZombies,
  setLastPushedSha: sessionFields.setLastPushedSha,
  clearLastPushedSha: sessionFields.clearLastPushedSha,
  getSkippableSteps: sessionFields.getSkippableSteps,
  recordSkipVerdict: skipVerdict.recordSkipVerdict,
  readSkipVerdict: skipVerdict.readSkipVerdict,
  hasSpeculativeSkipPending: skipVerdict.hasSpeculativeSkipPending,
  recordSessionWorktree: sessionFields.recordSessionWorktree,
};
