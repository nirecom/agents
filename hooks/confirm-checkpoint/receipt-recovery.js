"use strict";
// hooks/confirm-checkpoint/receipt-recovery.js — the late backstop for a presentation whose Stop hook
// was killed before it wrote the receipt (#2936). At the CONFIRM echo of turn N+1 it re-judges turn N
// with the Stop's own judgment (hooks/lib/presentation-turn.js) and, only when that turn would have
// been recorded, writes the receipt for this one step and spends turn N's markers. Fail-closed: any
// check it cannot complete leaves written false, so the caller denies no-receipt as before.

const fs = require("fs");
const { createDeadline } = require("../lib/hook-deadline");

// confirm-checkpoint's PreToolUse timeout in settings.json (seconds x 1000); a test keeps the two equal.
const CONFIRM_HOOK_TIMEOUT_MS = 15000;
const RECOVERY_MIN_MS = 2000;
const TAIL_RESERVE_MS = 1000;

const timeOf = (e) => (e && typeof e.timestamp === "string" ? Date.parse(e.timestamp) : NaN);
const no = (why) => ({ written: false, why });

// previousTurn(entries, TR) -> {tail, opener} of turn N (everything before turn N+1's opener), or null.
function previousTurn(entries, TR) {
  let last = -1;
  let before = -1;
  entries.forEach((e, idx) => { if (TR.isRealUserPrompt(e)) { before = last; last = idx; } });
  if (last < 0 || before < 0) return null;
  const prev = entries.slice(0, last);
  return { tail: Object.assign(TR.tailOf(prev), { entries: prev }), opener: entries[last] };
}

// replayed(sid, step, anchorMs, PR) -> true when the log holds a write or consume of the step at or
// after the anchor (the Stop recorded it, or the receipt was already spent); an unparsable time counts.
function replayed(sid, step, anchorMs, PR) {
  return PR.readReceiptLog(sid).some((l) => l && l.step === step && (l.event === "write" || l.event === "consume") &&
    !(Date.parse(l.at) < anchorMs));
}

function noteRecovered(sid, step) {
  try {
    require("../lib/supervisor-state-writer").appendFinding(sid, {
      categories: ["workflow"], severity: "notice", reporter: "confirm-checkpoint",
      detail: `confirm-checkpoint: receipt for ${step} recovered from the previous turn (stop-confirm-plan-guard left none; it may have timed out)`,
    });
  } catch (_) { /* the finding is advisory */ }
}

function recover({ sid, step, artifact, input, gate, deadlineAt }) {
  const deadline = Number.isFinite(deadlineAt) ? deadlineAt : createDeadline({ hookTimeoutMs: CONFIRM_HOOK_TIMEOUT_MS }).deadlineAt;
  if (deadline - Date.now() < RECOVERY_MIN_MS) return no("deadline");
  const tp = input && typeof input.transcript_path === "string" ? input.transcript_path : "";
  if (!sid || !step || !artifact || !tp) return no("input");
  const TR = require("../lib/transcript-reader");
  const read = TR.readTurnTail({ input: { transcript_path: tp }, turns: 2, deadlineAt: deadline - TAIL_RESERVE_MS });
  if (!read.complete || !Array.isArray(read.entries)) return no("tail");
  const turn = previousTurn(read.entries, TR);
  if (!turn) return no("no-previous-turn");
  const anchor = turn.tail.lastTextEntry;
  const anchorMs = timeOf(anchor);
  const openerMs = timeOf(turn.opener);
  if (!anchor || typeof anchor.uuid !== "string" || !anchor.uuid || Number.isNaN(anchorMs) || Number.isNaN(openerMs)) return no("timestamps");
  const PR = require("../lib/presentation-receipt");
  if (replayed(sid, step, anchorMs, PR)) return no("replay");
  const planPath = PR.approvalArtifactPath(sid, artifact);
  if (!planPath || !(fs.statSync(planPath).mtimeMs <= anchorMs)) return no("edited");
  const TM = require("../lib/turn-marker");
  const PT = require("../lib/presentation-turn");
  const probes = PT.probesFor(deadline, { seedGates: { [step]: gate } });
  const v = PT.judgePresentationTurn(Object.assign({ sid, tail: turn.tail, markers: TM.peekTurnMarkers(sid) }, probes));
  if (v.block) return no(`block:${v.block.kind}`);
  const p = (v.presented || []).find((x) => x && x.stage === artifact);
  if (!p || !p.receiptLink) return no("not-presented");
  if (!PR.writeReceipt(sid, step, { absPath: p.absPath, link: p.receiptLink, contentSha: p.contentSha, anchorUuid: v.anchorUuid })) return no("write");
  try { TM.consumeTurnMarkersBefore(sid, turn.opener.timestamp); } catch (_) { /* at worst one plan-link block next Stop */ }
  noteRecovered(sid, step);
  return { written: true, why: "recovered" };
}

// recoverReceipt({sid, step, artifact, input, plansDir, gate, deadlineAt}) -> {written, why}; never throws.
function recoverReceipt(args) {
  try {
    return recover(args || {});
  } catch (e) {
    return no(`threw: ${e && e.message ? e.message : String(e)}`);
  }
}

module.exports = { CONFIRM_HOOK_TIMEOUT_MS, RECOVERY_MIN_MS, recoverReceipt };
