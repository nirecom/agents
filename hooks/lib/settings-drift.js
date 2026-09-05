// Drift detection: compares the expectation built by install/lib/settings-assembly.js
// (base + extension + generated allow rules) against ~/.claude/settings.json (assembled).
// Consumed by hooks/session-start.js.
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

// Two passes, because a command dropped from a matcher group that still exists
// leaves the matcher count untouched. The command pass reports "<matcher> :: <command>".
function hookEntriesMissing(expectedHookEntries, assembledHookEntries) {
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
  // Commands are compared as a subset, not a multiset: an extra deployed command is
  // not drift, and the union per matcher is what the runtime actually executes.
  const deployedCommands = new Map();
  if (Array.isArray(assembledHookEntries)) {
    for (const entry of assembledHookEntries) {
      if (!entry || typeof entry.matcher !== 'string' || !Array.isArray(entry.hooks)) continue;
      let set = deployedCommands.get(entry.matcher);
      if (!set) {
        set = new Set();
        deployedCommands.set(entry.matcher, set);
      }
      for (const hook of entry.hooks) {
        if (hook && typeof hook.command === 'string') set.add(hook.command);
      }
    }
  }
  for (const entry of expectedHookEntries) {
    if (!entry || typeof entry.matcher !== 'string' || !Array.isArray(entry.hooks)) continue;
    const set = deployedCommands.get(entry.matcher);
    for (const hook of entry.hooks) {
      if (!hook || typeof hook.command !== 'string') continue;
      if (!set || !set.has(hook.command)) missing.push(entry.matcher + ' :: ' + hook.command);
    }
  }
  return missing;
}

function detectDrift({ homeDir }) {
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

  // (3) expectation: the SAME builder the installer deploys from, so a drift report can never
  // disagree with what a redeploy would actually write. The require() sits INSIDE the try
  // because a hook may run from a tree that has no install layer at all — that is a reason to
  // stay silent, not to crash the session.
  let expected;
  let generatorError = '';
  try {
    const assembly = require(path.join(agentsRoot, 'install', 'lib', 'settings-assembly.js'));
    const built = assembly.buildAssembledSettings({ agentsRoot });
    expected = built.settings;
    generatorError = built.generatorError;
  } catch (err) {
    return { drifted: false, sourceUnreadable: true, reason: 'settings source: ' + err.message };
  }

  // (4) every expected entry must be present in the assembled document
  const permKeys = ['allow', 'deny', 'ask', 'additionalDirectories'];
  const expectedPerm = (expected && expected.permissions) || {};
  const assembledPerm = (assembled && assembled.permissions) || {};

  const missingPermissions = { allow: [], deny: [], ask: [] };
  for (const pk of permKeys) {
    const want = Array.isArray(expectedPerm[pk]) ? expectedPerm[pk] : [];
    missingPermissions[pk] = permKeyMissing(want, assembledPerm[pk]);
  }

  const expectedHooks = (expected && expected.hooks) || {};
  const assembledHooks = (assembled && assembled.hooks) || {};

  const missingHooks = {};
  for (const event of Object.keys(expectedHooks)) {
    const want = Array.isArray(expectedHooks[event]) ? expectedHooks[event] : [];
    const missMatchers = hookEntriesMissing(want, assembledHooks[event]);
    if (missMatchers.length > 0) {
      missingHooks[event] = missMatchers;
    }
  }

  const anyPermMissing = permKeys.some((pk) => missingPermissions[pk].length > 0);
  const anyHookMissing = Object.keys(missingHooks).length > 0;

  // generatorUnavailable carries the REASON, not a flag: the session-start warning has to tell
  // the user what to fix, and an empty string is how "the generator was fine" is spelled.
  const result = (anyPermMissing || anyHookMissing)
    ? { drifted: true, missingPermissions, missingHooks }
    : { drifted: false };
  if (generatorError) {
    result.generatorUnavailable = generatorError;
  }
  return result;
}

module.exports = { detectDrift };
