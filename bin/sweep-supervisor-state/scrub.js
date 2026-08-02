#!/usr/bin/env node
"use strict";

// Pure scrubber for supervisor state files.
//
// Scope is layer1.findings ONLY. alert.findings and audit.findings carry
// position-dependent `idx` references and derived scalars this tool does not
// own — they are copied through untouched.

const { matchesSignature } = require("./signatures");

// scrub(state, allRecords?) → { cleaned, removed }
// `state` is a parsed supervisor-state object. `allRecords` overrides the
// sibling set used for co-occurrence conditions (defaults to layer1.findings).
function scrub(state, allRecords) {
  const removed = [];
  if (!state || typeof state !== "object" || Array.isArray(state)) {
    return { cleaned: state, removed };
  }
  const layer1 = state.layer1;
  if (!layer1 || typeof layer1 !== "object" || !Array.isArray(layer1.findings)) {
    return { cleaned: state, removed };
  }

  const siblings = Array.isArray(allRecords) ? allRecords : layer1.findings;
  const kept = [];
  for (const record of layer1.findings) {
    if (matchesSignature(record, siblings)) {
      removed.push(record);
    } else {
      kept.push(record);
    }
  }

  if (removed.length === 0) {
    return { cleaned: state, removed };
  }

  const cleaned = Object.assign({}, state, {
    layer1: Object.assign({}, layer1, { findings: kept }),
  });
  return { cleaned, removed };
}

module.exports = { scrub };
