"use strict";
// hooks/lib/plan-sync/remote-state.js
// What plan-sync has learned about the destination, kept in the plans repo's local git config
// and bound to the push URL it was learned for: the remote refuses a replacement push
// (plansync.forceRejected), and an auth failure holds the network back until
// plansync.authBackoffUntil (epoch ms). Facts stored for another URL read as nothing learned.
// Every error is swallowed: a lost fact only costs one more network attempt.
const G = require("./git");

const AUTH_BACKOFF_MS = 15 * 60 * 1000;
const KEYS = Object.freeze({
  url: "plansync.remoteStateUrl",
  force: "plansync.forceRejected",
  until: "plansync.authBackoffUntil",
});
const DEFAULTS = Object.freeze({ forceRejected: false, authBackoffUntil: 0 });

function readAll(plansDir) {
  const out = {};
  try {
    const raw = G.gitOut(plansDir, ["config", "--local", "--get-regexp", "^plansync\\."]);
    for (const line of (raw || "").split(/\r?\n/)) {
      const i = line.indexOf(" ");
      if (i > 0) out[line.slice(0, i).toLowerCase()] = line.slice(i + 1);
    }
  } catch (_) { /* nothing learned */ }
  return out;
}

// readRemoteState(plansDir, pushUrl) -> {forceRejected, authBackoffUntil}
function readRemoteState(plansDir, pushUrl) {
  const all = readAll(plansDir);
  if (typeof pushUrl !== "string" || !pushUrl || all[KEYS.url.toLowerCase()] !== pushUrl) return Object.assign({}, DEFAULTS);
  const until = Number(all[KEYS.until.toLowerCase()]);
  return {
    forceRejected: all[KEYS.force.toLowerCase()] === "true",
    authBackoffUntil: Number.isFinite(until) && until > 0 ? until : 0,
  };
}

function setKey(plansDir, key, value) {
  try { G.runGit(plansDir, ["config", "--local", key, String(value)]); } catch (_) { /* fail-open */ }
}

function unsetKey(plansDir, key) {
  try { G.runGit(plansDir, ["config", "--local", "--unset-all", key]); } catch (_) { /* fail-open */ }
}

// bindUrl(plansDir, pushUrl, staleKey) — points the state at pushUrl; a fact of another URL is dropped.
function bindUrl(plansDir, pushUrl, staleKey) {
  const all = readAll(plansDir);
  if (all[KEYS.url.toLowerCase()] !== pushUrl) {
    unsetKey(plansDir, staleKey);
    setKey(plansDir, KEYS.url, pushUrl);
  }
}

function recordForceRejected(plansDir, pushUrl) {
  if (typeof pushUrl !== "string" || !pushUrl) return;
  bindUrl(plansDir, pushUrl, KEYS.until);
  setKey(plansDir, KEYS.force, "true");
}

function recordAuthBackoff(plansDir, pushUrl, until) {
  if (typeof pushUrl !== "string" || !pushUrl || !Number.isFinite(Number(until))) return;
  bindUrl(plansDir, pushUrl, KEYS.force);
  setKey(plansDir, KEYS.until, String(Math.floor(Number(until))));
}

// clearRemoteState(plansDir) — key by key: remove-section would also drop plansync.version.
function clearRemoteState(plansDir) {
  for (const k of [KEYS.url, KEYS.force, KEYS.until]) unsetKey(plansDir, k);
}

module.exports = { AUTH_BACKOFF_MS, readRemoteState, recordForceRejected, recordAuthBackoff, clearRemoteState };
