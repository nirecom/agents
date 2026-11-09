"use strict";
// Child driver of tests/hooks/feature-2936-receipt-recovery.js, run in the confirm-checkpoint child
// env (config root, publish-mode preload) so gates and links resolve as in the hooks.
//   judge <sid> <transcript> <artifact> [active] -> judgePresentationTurn on the transcript's current
//     turn; `active` also passes stop_hook_active / active / input, which the judgment must ignore.
//   recover <sid> <transcript> <step> <artifact> <msLeft> -> recoverReceipt with deadlineAt now+msLeft.
// Prints one JSON line; {missing} when a module under test does not load.
const path = require("path");
const ROOT = path.resolve(__dirname, "..", "..", "..");
const req = (rel) => require(path.join(ROOT, rel));
const [mode, sid, tp, a3, a4, a5] = process.argv.slice(2);
const print = (o) => process.stdout.write(JSON.stringify(o) + "\n");

let mods;
try {
  mods = {
    TR: req("hooks/lib/transcript-reader"), PT: req("hooks/lib/presentation-turn"),
    TM: req("hooks/lib/turn-marker"), RR: req("hooks/confirm-checkpoint/receipt-recovery"),
    plansDir: req("hooks/lib/workflow-plans-dir").getWorkflowPlansDir(),
  };
} catch (e) {
  print({ missing: String((e && (e.code || e.message)) || e) });
  process.exit(0);
}

if (mode === "judge") {
  const tail = mods.TR.readTurnTail({ input: { transcript_path: tp } });
  const args = Object.assign({ sid, tail, markers: mods.TM.peekTurnMarkers(sid) }, mods.PT.probesFor(Date.now() + 10000));
  if (a4 === "active") Object.assign(args, { stop_hook_active: true, active: true, input: { stop_hook_active: true } });
  const v = mods.PT.judgePresentationTurn(args);
  const presented = (v.presented || []).map((p) => [p.stage, !!p.receiptLink]);
  const writes = !v.block && (v.presented || []).some((p) => p.stage === a3 && p.receiptLink);
  print({ block: v.block ? v.block.kind : null, presented, anchorUuid: v.anchorUuid, writes });
} else if (mode === "recover") {
  const r = mods.RR.recoverReceipt({
    sid, step: a3, artifact: a4, input: { transcript_path: tp }, plansDir: mods.plansDir, gate: "ON",
    deadlineAt: Date.now() + Number(a5),
  });
  print({ written: !!(r && r.written), why: r && r.why });
} else {
  print({ missing: `unknown mode ${mode}` });
}
