"use strict";

// Dispatch + re-export only. Logic lives in ./supervisor-state-writer/.
const { getStatePath, readStateOrInit, writeAtomic, validateAlertPhaseTransition } = require("./supervisor-state-writer/shared");
const { ensureAlertScheduled, appendFinding, readState } = require("./supervisor-state-writer/append");
const { writeAlertState, incrementAlertRetryCount, confirmFinding, dropFindings, promotePendingDraftsToConfirmed } = require("./supervisor-state-writer/alert");
const { writeAuditState, writeAuditStateCas, incrementAuditRetryCount, armAuditRun, markAuditLaunchShown, finalizeAuditRun, recordBlockOverride } = require("./supervisor-state-writer/audit");
const { copySupervisorState } = require("./supervisor-state-writer/copy");

module.exports = {
  getStatePath,
  readStateOrInit,
  ensureAlertScheduled,
  appendFinding,
  readState,
  writeAlertState,
  writeAtomic,
  incrementAlertRetryCount,
  confirmFinding,
  dropFindings,
  promotePendingDraftsToConfirmed,
  validateAlertPhaseTransition,
  writeAuditState,
  writeAuditStateCas,
  incrementAuditRetryCount,
  armAuditRun,
  markAuditLaunchShown,
  finalizeAuditRun,
  recordBlockOverride,
  copySupervisorState,
};
