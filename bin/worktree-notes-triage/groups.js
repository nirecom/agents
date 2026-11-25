"use strict";

// `list` grouping for bin/worktree-notes-triage.js (#2019): every undisposed, unpromoted triage entry
// goes to the group its rule-table class names (bin/lib/finding-rules.js). finalList is ordered by
// loc (loc-less last) and capped at FINAL_LIST_CAP; the rest is overflow. Nothing pending → {}.

const { scanSection } = require("../../hooks/lib/worktree-notes-sections");
const { findingKey } = require("../../hooks/lib/finding-approval");
const { classify } = require("../lib/finding-rules");

// Triage sections only. `## ManualReminders` is deliberately absent: a reminder is addressed to
// the person closing the session, not to a future implementer (#530).
const SECTIONS = Object.freeze(["BugsFound", "RelatedTasks", "NextTasks"]);
const FINAL_LIST_CAP = 16;
const GROUP_OF_CLASS = Object.freeze({
  "auto-high": "autoHigh",
  "final-list": "finalList",
  discard: "discard",
  "test-failure-handoff": "testFailureHandoff",
});

// Every triage entry with its section, in document order.
function triageEntries(text) {
  const out = [];
  for (const section of SECTIONS) {
    for (const entry of scanSection(text, section).entries) out.push(Object.assign({ section }, entry));
  }
  return out;
}

function isTerminal(entry) {
  return entry.hasMarker || entry.disposed !== null;
}

function listElement(e) {
  return {
    section: e.section,
    body: e.body,
    key: findingKey(e.section, e.body),
    severity: e.severity,
    instance: e.instance,
    loc: e.loc,
    lineNumber: e.lineNumber,
  };
}

function byLoc(a, b) {
  if (a.loc === b.loc) return 0;
  if (a.loc === null) return 1;
  if (b.loc === null) return -1;
  return a.loc < b.loc ? -1 : 1;
}

function groupEntries(text, handoffAvailable) {
  const pending = triageEntries(text).filter((e) => !isTerminal(e));
  if (pending.length === 0) return {};
  const groups = { autoHigh: [], finalList: [], overflow: [], discard: [], testFailureHandoff: [] };
  for (const e of pending) groups[GROUP_OF_CLASS[classify(e, { handoffAvailable })]].push(listElement(e));
  const ordered = groups.finalList.slice().sort(byLoc);
  groups.finalList = ordered.slice(0, FINAL_LIST_CAP);
  groups.overflow = ordered.slice(FINAL_LIST_CAP);
  return groups;
}

module.exports = { SECTIONS, FINAL_LIST_CAP, triageEntries, isTerminal, groupEntries };
