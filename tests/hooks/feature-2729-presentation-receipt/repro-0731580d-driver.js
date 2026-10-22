"use strict";
// #2729 Gap 4 repro (session 0731580d, R1): a presentation turn closed on the outline link line,
// a continuation, an Agent call, a denied echo, a task-notification user entry, then a turn that
// closes on the outline AND intent link lines (intent edited after its approval). The last echo
// must reach the dialog: the presentation receipt, not the previous turn's shape, decides.
// Prints PASS|name / FAIL|name|detail lines.
const fs = require("fs");
const R = require("./fixture");
const { A, T, TR, STOPFB, BASH, check, show } = R;

const s = R.sessionAt("outline", { tag: 731 });
const intent = R.linesFor(s.sid, "intent");

// 1-2: the presentation turn closes on the outline link line (published); Stop continues.
const tp1 = R.presentTurn(s, ["outline"], "Here is the outline.\n\n" + s.urlLine);
const st1 = R.stop(s.sid, tp1);
check("R1 first presentation: Stop continues for the CONFIRM echo", st1.continued, show({ rc: st1.rc, out: st1.out }));

// 3-4: the continuation turn runs an Agent call, then echoes. Under the old turn-shape judge this echo
// was denied (the Agent call broke the "previous turn" shape) and every later turn lost the dialog; the
// presentation receipt written by the first Stop must carry it to the dialog instead (Gap 4).
const base = JSON.parse("[" + fs.readFileSync(tp1, "utf8").trim().split("\n").join(",") + "]");
const agent = { type: "tool_use", id: "ag1", name: "Agent", input: { description: "survey", prompt: "survey" } };
const turn2 = base.concat([STOPFB(st1.reason || "[confirm-plan] continue: outline", "u-fb1"), A("a-agent", agent), TR("ag1", "u-ag1"), A("a-echo1", BASH(R.echoOf("outline"), "e1"))]);
const tp2 = R.writeTranscript(s.sid, turn2);
check("R1 first presentation: an outline receipt is written by the first Stop", R.receiptExists(s.sid, "outline"), show(R.readReceiptRaw(s.sid, "outline")));
const e1 = R.echo(s.sid, "outline", { transcriptPath: tp2 });
check("R1 the echo after an Agent call reaches the dialog (not denied; Gap 4 precondition removed)", e1.dialog, show({ rc: e1.rc, denied: e1.denied, json: e1.json }));
check("R1 the first echo consumes the outline receipt", !R.receiptExists(s.sid, "outline"), show(R.readReceiptRaw(s.sid, "outline")));

// 5: a task-notification user entry (isRealUserPrompt counts it as a prompt).
const notif = { type: "user", origin: { kind: "task-notification" }, message: { role: "user", content: "<task-notification>agent done</task-notification>" }, uuid: "u-notif" };

// 6: the next turn rewrites intent (after its approval) and outline; it closes on both link lines.
fs.writeFileSync(intent.plan, R.EDITED_INTENT);
R.turnMarker(s.sid, "intent", intent.plan);
R.turnMarker(s.sid, "outline", s.plan);
const turn3 = turn2.concat([
  { type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "e1", content: "approved", is_error: false }] }, uuid: "u-e1" },
  notif,
  A("a-w2", R.W(intent.plan, "w2")), TR("w2", "u-w2"),
  A("a-w3", R.W(s.plan, "w3")), TR("w3", "u-w3"),
  A("a-anchor2", T("Both plans are updated.\n\n" + s.urlLine + "\n" + intent.urlLine)),
]);
const tp3 = R.writeTranscript(s.sid, turn3);
const st3 = R.stop(s.sid, tp3);
check("R1 second presentation: Stop does not block on a plan-link reason", !st3.blocked || st3.continued, show({ rc: st3.rc, out: st3.out }));
check("R1 second presentation: an outline receipt is written", R.receiptExists(s.sid, "outline"), show(R.readReceiptRaw(s.sid, "outline")));
check("R1 second presentation: an intent receipt is written (intent edited after approval is unapproved)", R.receiptExists(s.sid, "intent"), show(R.readReceiptRaw(s.sid, "intent")));

// 7: the echo reaches the dialog.
const e = R.echo(s.sid, "outline", { transcriptPath: tp3 });
check("R1 the last outline echo reaches the dialog (Gap 4)", e.dialog, show({ rc: e.rc, json: e.json }));

// R1b: the denied path of the same shape. No receipt exists, so the echo after an Agent call is
// denied; a task-notification user entry follows; the plan is presented again (Stop writes the
// receipt), and only then does the echo reach the dialog, spending the receipt.
const b = R.sessionAt("outline", { tag: 732 });
const bAgent = { type: "tool_use", id: "ag2", name: "Agent", input: { description: "survey", prompt: "survey" } };
const bTurn1 = [R.U("continue the outline", "u-b-prompt"), A("a-b-agent", bAgent), TR("ag2", "u-b-ag2"), A("a-b-echo1", BASH(R.echoOf("outline"), "eb1"))];
const bTp1 = R.writeTranscript(b.sid, bTurn1);
check("R1b precondition: no outline receipt before any presentation", !R.receiptExists(b.sid, "outline"), show(R.readReceiptRaw(b.sid, "outline")));
const be1 = R.echo(b.sid, "outline", { transcriptPath: bTp1 });
check("R1b the echo after an Agent call with no receipt is denied", be1.denied && !be1.dialog, show({ rc: be1.rc, json: be1.json }));
check("R1b the denied echo writes no receipt", !R.receiptExists(b.sid, "outline"), show(R.readReceiptRaw(b.sid, "outline")));
const bNotif = { type: "user", origin: { kind: "task-notification" }, message: { role: "user", content: "<task-notification>agent done</task-notification>" }, uuid: "u-b-notif" };
const bBefore = bTurn1.concat([
  { type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "eb1", content: be1.reason || "denied", is_error: true }] }, uuid: "u-b-eb1" },
  bNotif,
]);
const bTp2 = R.presentTurn(b, ["outline"], "Here is the outline again.\n\n" + b.urlLine, { before: bBefore, anchorUuid: "a-b-anchor" });
const bst = R.stop(b.sid, bTp2);
check("R1b re-presentation: Stop continues for the CONFIRM echo", bst.continued, show({ rc: bst.rc, out: bst.out }));
check("R1b re-presentation: Stop writes the outline receipt", R.receiptExists(b.sid, "outline"), show(R.readReceiptRaw(b.sid, "outline")));
const be2 = R.echo(b.sid, "outline", { transcriptPath: bTp2 });
check("R1b the echo after the re-presentation reaches the dialog", be2.dialog, show({ rc: be2.rc, json: be2.json }));
check("R1b the passing echo spends the outline receipt", !R.receiptExists(b.sid, "outline"), show(R.readReceiptRaw(b.sid, "outline")));
