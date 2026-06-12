// Drift detection: compares agents/settings.json (base) + settings-extension.json (ext)
// against ~/.claude/settings.json (assembled). Consumed by hooks/session-start.js.
//
// agentsRoot resolution: this module is loaded from the globally-set core.hooksPath
// (agents/hooks/lib/), so __dirname always resolves to the agents MAIN worktree's
// hooks/lib/ dir regardless of which repo or linked worktree triggered the hook.
// Linked worktrees (feature branches) are intentionally NOT used as source — only
// the main worktree's settings.json is the canonical base for the active configuration.
'use strict';

const fs = require('fs');
const path = require('path');

// agentsRoot: agents repo root (two levels up from hooks/lib/)
const agentsRoot = path.resolve(__dirname, '..', '..');

function readJson(p) {
  const raw = fs.readFileSync(p, 'utf8');
  return JSON.parse(raw);
}

function permKeyMissing(expectedArr, assembledArr) {
  const assembledSet = new Set(Array.isArray(assembledArr) ? assembledArr : []);
  const missing = [];
  for (const entry of expectedArr) {
    if (!assembledSet.has(entry)) {
      missing.push(entry);
    }
  }
  return missing;
}

function hookMatchersMissing(expectedHookEntries, assembledHookEntries) {
  // Use multiset counting: same matcher can appear multiple times for different hook commands.
  const assembledCounts = new Map();
  if (Array.isArray(assembledHookEntries)) {
    for (const entry of assembledHookEntries) {
      if (entry && typeof entry.matcher === 'string') {
        assembledCounts.set(entry.matcher, (assembledCounts.get(entry.matcher) || 0) + 1);
      }
    }
  }
  const expectedCounts = new Map();
  for (const entry of expectedHookEntries) {
    if (entry && typeof entry.matcher === 'string') {
      expectedCounts.set(entry.matcher, (expectedCounts.get(entry.matcher) || 0) + 1);
    }
  }
  const missing = [];
  for (const [matcher, expectedCount] of expectedCounts) {
    const deficit = expectedCount - (assembledCounts.get(matcher) || 0);
    for (let i = 0; i < deficit; i++) {
      missing.push(matcher);
    }
  }
  return missing;
}

function detectDrift({ homeDir }) {
  const basePath = path.join(agentsRoot, 'settings.json');
  const extPath = path.join(agentsRoot, 'settings-extension.json');
  const assembledPath = path.join(homeDir, '.claude', 'settings.json');

  // (1) assembled file missing
  if (!fs.existsSync(assembledPath)) {
    return { drifted: true, missing: true, reason: 'assembled file missing' };
  }

  // (2) assembled parse error
  let assembled;
  try {
    assembled = readJson(assembledPath);
  } catch (err) {
    return { drifted: true, broken: true, reason: err.message };
  }

  // (3) base/ext read/parse error (fail-open)
  let base;
  let ext;
  try {
    base = readJson(basePath);
  } catch (err) {
    return { drifted: false, sourceUnreadable: true, reason: 'base: ' + err.message };
  }
  try {
    ext = fs.existsSync(extPath) ? readJson(extPath) : {};
  } catch (err) {
    return { drifted: false, sourceUnreadable: true, reason: 'ext: ' + err.message };
  }

  // (4) compute expected entries using concat semantics
  const permKeys = ['allow', 'deny', 'ask', 'additionalDirectories'];
  const basePerm = (base && base.permissions) || {};
  const extPerm = (ext && ext.permissions) || {};
  const assembledPerm = (assembled && assembled.permissions) || {};

  const missingPermissions = { allow: [], deny: [], ask: [] };
  for (const pk of permKeys) {
    const expected = (Array.isArray(basePerm[pk]) ? basePerm[pk] : [])
      .concat(Array.isArray(extPerm[pk]) ? extPerm[pk] : []);
    missingPermissions[pk] = permKeyMissing(expected, assembledPerm[pk]);
  }

  const baseHooks = (base && base.hooks) || {};
  const extHooks = (ext && ext.hooks) || {};
  const assembledHooks = (assembled && assembled.hooks) || {};
  const eventSet = new Set([...Object.keys(baseHooks), ...Object.keys(extHooks)]);

  const missingHooks = {};
  for (const event of eventSet) {
    const expected = (Array.isArray(baseHooks[event]) ? baseHooks[event] : [])
      .concat(Array.isArray(extHooks[event]) ? extHooks[event] : []);
    const missMatchers = hookMatchersMissing(expected, assembledHooks[event]);
    if (missMatchers.length > 0) {
      missingHooks[event] = missMatchers;
    }
  }

  const anyPermMissing = permKeys.some((pk) => missingPermissions[pk].length > 0);
  const anyHookMissing = Object.keys(missingHooks).length > 0;

  if (anyPermMissing || anyHookMissing) {
    return { drifted: true, missingPermissions, missingHooks };
  }
  return { drifted: false };
}

module.exports = { detectDrift };
