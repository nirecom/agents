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
const { recordStepTimestampsEnabled } = require("./step-timestamps");

module.exports = {
  VALID_STEPS: core.VALID_STEPS,
  SKIPPABLE_STEPS: core.SKIPPABLE_STEPS,
  VALID_STATUSES: core.VALID_STATUSES,
  getWorkflowDir: core.getWorkflowDir,
  getStatePath: core.getStatePath,
  assertValidSessionId: core.assertValidSessionId,
  SESSION_ID_VALID_RE: core.SESSION_ID_VALID_RE,
  readState: core.readState,
  readRawState: core.readRawState,
  writeState: core.writeState,
  createInitialState: core.createInitialState,
  getCurrentContext: core.getCurrentContext,
  findLatestStateForContext: contextScan.findLatestStateForContext,
  markStep: core.markStep,
  recordStepTimestampsEnabled,
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
