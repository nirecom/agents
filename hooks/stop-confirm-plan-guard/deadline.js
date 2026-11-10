"use strict";
// hooks/stop-confirm-plan-guard/deadline.js — the Stop guard's time budget (#2936). It runs from the
// process start (hooks/lib/hook-deadline.js), so node start-up and the transcript read count against
// the Stop timeout; the tail read stops early enough to leave a gate probe, the receipt write and
// the output inside it.

const { createDeadline } = require("../lib/hook-deadline");

// The guard's Stop timeout in settings.json (seconds x 1000); a test keeps the two equal.
const STOP_HOOK_TIMEOUT_MS = 5000;
const TAIL_RESERVE_MS = 1500;

// stopDeadlineAt({env}) -> epoch ms; STOP_CONFIRM_CONTINUE_T0_OFFSET_MS lets a test move the start back.
function stopDeadlineAt({ env = process.env } = {}) {
  return createDeadline({ hookTimeoutMs: STOP_HOOK_TIMEOUT_MS }).deadlineAt - (Number(env.STOP_CONFIRM_CONTINUE_T0_OFFSET_MS) || 0);
}

function tailReadUntil(deadline) {
  return deadline - TAIL_RESERVE_MS;
}

module.exports = { STOP_HOOK_TIMEOUT_MS, TAIL_RESERVE_MS, stopDeadlineAt, tailReadUntil };
