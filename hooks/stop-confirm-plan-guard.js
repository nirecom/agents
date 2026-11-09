#!/usr/bin/env node
// Stop hook: structurally enforce the confirm-plan protocol. Dispatch only (#2936): the judgment of a
// presentation turn is hooks/lib/presentation-turn.js (block reasons ranked in
// hooks/lib/presentation-turn/block-reasons.js); how a turn that is not blocked ends — receipts, the
// undecidable record (#2771), the notice and the one continue (#2729) — is
// hooks/stop-confirm-plan-guard/settle.js; the time budget, which runs from the process start, is
// hooks/stop-confirm-plan-guard/deadline.js. The tail is read within that budget
// (hooks/lib/transcript-reader.js readTurnTail); a tail the budget cuts short is undecidable.
// Reason prefixes and the marker contract: docs/architecture/claude-code/settings.md.
"use strict";

const fs = require("fs");
const { readHookInput, readFailOpenDiagnostic } = require("./lib/read-stdin");
const { stopDeadlineAt, tailReadUntil } = require("./stop-confirm-plan-guard/deadline");
const S = require("./stop-confirm-plan-guard/settle");

// readTail(input, deadline) -> {kind: "ok"|"undecidable", tail} | {kind: "none", tail?}: "none" is a
// tail the hook cannot read or whose last assistant entry is malformed, so no receipt is inferred
// from it. The reader is looked up at call time, so a test may wrap its export.
function readTail(input, deadline) {
  try {
    const tail = require("./lib/transcript-reader").readTurnTail({ input, deadlineAt: tailReadUntil(deadline) });
    const content = tail.lastAssistantEntry && tail.lastAssistantEntry.message && tail.lastAssistantEntry.message.content;
    if (tail.lastAssistantEntry && !Array.isArray(content)) return { kind: "none", tail };
    return { kind: tail.undecidable ? "undecidable" : "ok", tail };
  } catch (_) {
    return { kind: "none" };
  }
}

function main() {
  const deadline = stopDeadlineAt();
  const r = readHookInput();
  if (r.kind !== "ok") {
    try {
      fs.writeSync(2, readFailOpenDiagnostic("stop-confirm-plan-guard", r, "confirm-plan check skipped") + "\n");
    } catch (_) {}
    process.exit(0);
  }
  const input = r.input;
  const active = input.stop_hook_active === true;

  const { resolveSessionId } = require("./workflow-state");
  const sid = resolveSessionId({ sessionIdFromInput: input.session_id, transcriptPath: input.transcript_path });
  if (!sid) process.exit(0);

  const TM = require("./lib/turn-marker");
  let markers = [];
  try { markers = TM.peekTurnMarkers(sid); } catch (_) { /* judged as a turn that wrote no plan */ }
  const { kind, tail } = readTail(input, deadline);
  if (kind !== "ok") {
    let settled;
    try {
      settled = kind === "undecidable"
        ? S.recordUndecidable({ sid, input, tail, markers, deadline, active })
        : { unrecorded: S.mayHavePresented(sid, markers, input), written: [] };
    } catch (_) {
      settled = { unrecorded: S.mayHavePresented(sid, markers, input), written: [] };
    }
    S.settleStop(sid, active, settled, TM, kind === "undecidable" ? { input, tail } : null, deadline);
  }

  let verdict;
  try {
    const PT = require("./lib/presentation-turn");
    verdict = PT.judgePresentationTurn(Object.assign({ sid, markers, tail }, PT.probesFor(deadline)));
  } catch (_) {
    // An exception says only that the turn could not be judged: earlier receipts stay.
    S.settleStop(sid, active, { unrecorded: S.mayHavePresented(sid, markers, input), written: [] }, TM, null, deadline);
  }

  if (verdict.block) {
    if (active) {
      S.recordUnblocked(sid, verdict.block);
      process.exit(0);
    }
    TM.readAndDeleteTurnMarkers(sid);
    S.emitBlock(verdict.block.reason);
  }
  // A block leaves every receipt as it is; only a turn let through records its presentations.
  const { written, failed } = S.recordReceipts(sid, verdict.presented, verdict.anchorUuid, active);
  S.settleStop(sid, active, { unrecorded: failed, written }, TM, null, deadline);
}

if (require.main === module) main();

module.exports = { recordUndecidable: S.recordUndecidable };
