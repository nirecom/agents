"use strict";

// Dispatch + re-export only. Logic lives in ./supervisor-state-writer/.
const { getStatePath, readStateOrInit, writeAtomic, validateAlertPhaseTransition } = require("./supervisor-state-writer/shared");
const { ensureAlertScheduled, appendFinding, readState } = require("./supervisor-state-writer/append");
const { writeAlertState, incrementAlertRetryCount, confirmFinding, dropFindings, promotePendingDraftsToConfirmed } = require("./supervisor-state-writer/alert");
const { writeAuditState, incrementAuditRetryCount } = require("./supervisor-state-writer/audit");

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
  incrementAuditRetryCount,
};
