"use strict";
// The time budget of one UserPromptSubmit hook run (#3152). HOOK_TIMEOUT_MS equals the settings.json timeout of
// user-prompt-submit-issue-title.js; every stage limit of the PM writer derives from it, so the sum always fits.
//   createHookBudget({startedAt?, now?}) -> {hookDeadlineAt, checkDeadline({write?}), ensureWindow(), writeWindow(),
//     inboxMs(), left()}; createUnlimitedBudget() -> the same shape with no limit (direct calls, tests, CLI).
// The PM lock wait (pm-lock.js PM_LOCK_WAIT_MS) and the origin limit (forge-kind.js ORIGIN_TIMEOUT_MS) are owned
// by their modules and only capped here through left().

const HOOK_TIMEOUT_MS = 10000;
const SAFETY_MARGIN_MS = 1000;
const WRITE_MUTATION_MS = 1500;
const WRITE_REREAD_MS = 1200;
const INBOX_MS = 1200;
const ENSURE_CARD_MIN_MS = 3000;
const ENSURE_REREAD_MS = 1100;
const CHECK_MIN_MS = 2200;
const GH_MIN_CALL_MS = 400;

const WRITE_MS = WRITE_MUTATION_MS + WRITE_REREAD_MS;

function createHookBudget(opts) {
  const o = opts || {};
  const now = typeof o.now === "function" ? o.now : Date.now;
  const startedAt = Number.isFinite(o.startedAt) ? o.startedAt : Math.round(performance.timeOrigin);
  const hd = startedAt + HOOK_TIMEOUT_MS - SAFETY_MARGIN_MS;
  const inboxEnd = hd - INBOX_MS;
  return {
    hookDeadlineAt: hd,
    limited: true,
    checkDeadline: ({ write = true } = {}) => inboxEnd - (write ? WRITE_MS : 0),
    ensureWindow: () => {
      const t = now();
      const r = inboxEnd - WRITE_MS - t;
      return r >= ENSURE_CARD_MIN_MS ? { spawnMs: r - ENSURE_REREAD_MS, rereadDeadlineAt: t + r } : null;
    },
    writeWindow: () => {
      const t = now();
      const end = Math.min(t + WRITE_MS, inboxEnd);
      return { mutate: Math.min(t + WRITE_MUTATION_MS, end), reread: end };
    },
    inboxMs: () => Math.min(INBOX_MS, Math.max(0, hd - now())),
    left: () => Math.max(0, hd - now()),
  };
}

function createUnlimitedBudget() {
  return {
    hookDeadlineAt: Infinity,
    limited: false,
    checkDeadline: () => Infinity,
    ensureWindow: () => ({ spawnMs: Infinity, rereadDeadlineAt: Infinity }),
    writeWindow: () => ({ mutate: Infinity, reread: Infinity }),
    inboxMs: () => INBOX_MS,
    left: () => Infinity,
  };
}

const budgetOf = (deps) => (deps && deps.budget) || createUnlimitedBudget();

module.exports = {
  HOOK_TIMEOUT_MS, SAFETY_MARGIN_MS, WRITE_MUTATION_MS, WRITE_REREAD_MS, INBOX_MS, ENSURE_CARD_MIN_MS, ENSURE_REREAD_MS,
  CHECK_MIN_MS, GH_MIN_CALL_MS, createHookBudget, createUnlimitedBudget, budgetOf,
};
