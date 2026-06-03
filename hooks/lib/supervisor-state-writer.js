"use strict";

const fs = require("fs");
const path = require("path");
const { getWorkflowPlansDir } = require("./workflow-plans-dir");
const { createEmptyState, validate, validateFinding } = require("./supervisor-state-schema");

const SESSION_ID_RE = /^[A-Za-z0-9_-]+$/;

function getStatePath(sessionId) {
  if (!SESSION_ID_RE.test(sessionId)) throw new Error(`invalid sessionId: ${sessionId}`);
  return path.join(getWorkflowPlansDir(), `${sessionId}-supervisor-state.json`);
}

function readStateOrInit(sessionId) {
  const filePath = getStatePath(sessionId);
  try {
    const raw = fs.readFileSync(filePath, "utf8");
    return JSON.parse(raw);
  } catch (_) {
    return createEmptyState(sessionId);
  }
}

function writeAtomic(filePath, state) {
  const tmpPath = filePath + ".tmp";
  fs.writeFileSync(tmpPath, JSON.stringify(state, null, 2), "utf8");
  fs.renameSync(tmpPath, filePath);
}

function appendFinding(sessionId, finding) {
  const vr = validateFinding(finding);
  if (!vr.ok) return false;

  const plansDir = getWorkflowPlansDir();
  fs.mkdirSync(plansDir, { recursive: true });
  const filePath = getStatePath(sessionId);

  const state = readStateOrInit(sessionId);

  const findings = state.layer1.findings;
  if (findings.length > 0) {
    const last = findings[findings.length - 1];
    if (last.check === finding.check && last.status === finding.status && last.detail === finding.detail) {
      return true;
    }
  }

  findings.push({ ...finding, timestamp: new Date().toISOString() });
  state.last_updated = new Date().toISOString();

  const vr2 = validate(state);
  if (!vr2.ok) {
    console.error(`[supervisor-state-writer] validate failed: ${vr2.errors.join("; ")}`);
    return false;
  }

  writeAtomic(filePath, state);
  return true;
}

function readState(sessionId) {
  try {
    const raw = fs.readFileSync(getStatePath(sessionId), "utf8");
    return JSON.parse(raw);
  } catch (_) {
    return null;
  }
}

module.exports = { getStatePath, readStateOrInit, appendFinding, readState };
