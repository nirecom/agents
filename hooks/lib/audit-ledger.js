"use strict";

// #2256 S2-d/S2-f — the audit ledger: append-only run records plus the four
// queries every consumer asks of them.
// Dedup granularity is <sub_check_id>@<input_key>. `trigger_input_keys` is
// TR-keyed metadata for humans and is never consulted here (round-2 C2).

const LEDGER_CAP = 40;
const CONSUMED_TRANSITIONS_CAP = 200;
const BLOCK_OVERRIDES_CAP = 20;
const DECLARED_FILES_CAP = 500;

const RUN_ID_RE = /^run-[0-9]{4}$/;
const TR_ID_RE = /^TR[0-9]+$/;

const TERMINAL_OUTCOME = "terminal";
const OUTCOME_VALUES = ["armed", "terminal", "discarded-stale", "superseded"];

function formatRunId(seq) {
  return `run-${String(seq).padStart(4, "0")}`;
}

function ledgerOf(audit) {
  return audit && Array.isArray(audit.ledger) ? audit.ledger : [];
}

// The newest terminal entry — the run whose verdict currently stands.
function lastTerminalRun(audit) {
  if (!audit || typeof audit !== "object") return null;
  const entries = ledgerOf(audit);
  if (audit.last_terminal_run_id) {
    const named = entries.filter((e) => e && e.id === audit.last_terminal_run_id);
    if (named.length > 0) return named[named.length - 1];
  }
  for (let i = entries.length - 1; i >= 0; i--) {
    if (entries[i] && entries[i].outcome === TERMINAL_OUTCOME) return entries[i];
  }
  return null;
}

function isTransitionConsumed(audit, transitionKey) {
  if (!audit || typeof transitionKey !== "string" || transitionKey === "") return false;
  return Array.isArray(audit.consumed_transitions) && audit.consumed_transitions.includes(transitionKey);
}

// Settled only when a terminal run covered this exact sub-check at this exact
// input key. A TR-shaped id is never a sub-check id.
function isSubCheckSettled(audit, subCheckId, inputKey) {
  if (!audit || typeof subCheckId !== "string" || subCheckId === "") return false;
  if (TR_ID_RE.test(subCheckId)) return false;
  if (typeof inputKey !== "string" || inputKey === "") return false;
  for (const entry of ledgerOf(audit)) {
    if (!entry || entry.outcome !== TERMINAL_OUTCOME) continue;
    if (!Array.isArray(entry.sub_checks) || !entry.sub_checks.includes(subCheckId)) continue;
    const keys = entry.input_key;
    if (!keys || typeof keys !== "object" || Array.isArray(keys)) continue;
    if (keys[subCheckId] === inputKey) return true;
  }
  return false;
}

// Exact 64-hex comparison on both sides; a null on either side is never fresh.
function isRunFresh(entry, freshnessKey) {
  if (!entry || typeof entry !== "object") return false;
  const stored = entry.freshness_key;
  if (typeof stored !== "string" || stored === "") return false;
  if (typeof freshnessKey !== "string" || freshnessKey === "") return false;
  return stored === freshnessKey;
}

// FIFO to LEDGER_CAP, but the entry the current verdict points at is immortal.
function pruneLedger(audit) {
  if (!audit || !Array.isArray(audit.ledger)) return;
  if (audit.ledger.length <= LEDGER_CAP) return;
  const pinnedId = audit.last_terminal_run_id;
  const pinnedIdx = audit.ledger.findIndex((e) => e && e.id === pinnedId);
  let toDrop = audit.ledger.length - LEDGER_CAP;
  const kept = [];
  for (let i = 0; i < audit.ledger.length; i++) {
    if (toDrop > 0 && i !== pinnedIdx) {
      toDrop -= 1;
      continue;
    }
    kept.push(audit.ledger[i]);
  }
  audit.ledger = kept;
}

function appendLedgerEntry(audit, entry) {
  if (!Array.isArray(audit.ledger)) audit.ledger = [];
  audit.ledger.push(entry);
  pruneLedger(audit);
  return entry;
}

function extendConsumedTransitions(audit, transitions) {
  if (!Array.isArray(audit.consumed_transitions)) audit.consumed_transitions = [];
  for (const t of Array.isArray(transitions) ? transitions : []) {
    if (typeof t !== "string" || t === "") continue;
    if (!audit.consumed_transitions.includes(t)) audit.consumed_transitions.push(t);
  }
  if (audit.consumed_transitions.length > CONSUMED_TRANSITIONS_CAP) {
    audit.consumed_transitions = audit.consumed_transitions.slice(-CONSUMED_TRANSITIONS_CAP);
  }
}

function appendBlockOverride(audit, override) {
  if (!Array.isArray(audit.block_overrides)) audit.block_overrides = [];
  audit.block_overrides.push(override);
  if (audit.block_overrides.length > BLOCK_OVERRIDES_CAP) {
    audit.block_overrides = audit.block_overrides.slice(-BLOCK_OVERRIDES_CAP);
  }
}

// Cap the declared-files snapshot and say so, rather than silently dropping tail paths.
function capDeclaredFiles(declaredFiles) {
  if (!declaredFiles || typeof declaredFiles !== "object" || Array.isArray(declaredFiles)) return declaredFiles;
  const files = Array.isArray(declaredFiles.files) ? declaredFiles.files : [];
  if (files.length <= DECLARED_FILES_CAP) {
    return { ...declaredFiles, files, truncated: declaredFiles.truncated === true };
  }
  return { ...declaredFiles, files: files.slice(0, DECLARED_FILES_CAP), truncated: true };
}

module.exports = {
  LEDGER_CAP,
  CONSUMED_TRANSITIONS_CAP,
  BLOCK_OVERRIDES_CAP,
  DECLARED_FILES_CAP,
  RUN_ID_RE,
  TR_ID_RE,
  OUTCOME_VALUES,
  TERMINAL_OUTCOME,
  formatRunId,
  lastTerminalRun,
  isTransitionConsumed,
  isSubCheckSettled,
  isRunFresh,
  pruneLedger,
  appendLedgerEntry,
  extendConsumedTransitions,
  appendBlockOverride,
  capDeclaredFiles,
};
