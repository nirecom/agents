"use strict";
// #2729 R3-R12: the presentation receipt end to end (Stop writes / discards it, confirm-checkpoint
// matches and consumes it). Usage: node r-cases-driver.js <R3|R4|R5|R6|R7|R8|R9|R10|R11|R12|R14|R15>.
// Prints PASS|name / FAIL|name|detail lines.
const fs = require("fs");
const path = require("path");
const R = require("./fixture");
const { A, TR, BASH, check, show } = R;

const STAGES = ["intent", "outline", "detail"];
const presentAgain = (reason, stage) => reason !== "" && !reason.startsWith("[confirm-plan] continue:") &&
  reason.includes("plan-link") && reason.includes(`--stage ${stage}`);
const samePath = (a, b) => typeof a === "string" && path.resolve(a).toLowerCase() === path.resolve(b).toLowerCase();
const pathLine = (s, stage, reason) => `${stage}: \`${R.linesFor(s.sid, stage).fwd}\` (no URL: ${reason})`;
const urlLine = (s, stage) => R.linesFor(s.sid, stage).urlLine;
const QUESTION = "Does this look right?";

// present(s, stage, opts) -> the Stop result of a turn that wrote the stage and closed on its link line.
function present(s, stage, opts) {
  const o = opts || {};
  const line = o.line || urlLine(s, stage);
  return R.stop(s.sid, R.presentTurn(s, [stage], "Here is the plan.\n\n" + line), o);
}
// seedReceipts(s) -> raw, well-formed receipts for every stage (a prior presentation's leftovers).
function seedReceipts(s) {
  for (const st of STAGES) {
    const p = R.linesFor(s.sid, st);
    if (!fs.existsSync(p.plan)) R.F.writePlan(s.sid, st);
    R.writeReceiptRaw(s.sid, st, { absPath: p.plan, link: { kind: "url", value: p.url }, contentSha: R.sha256(p.plan), anchorUuid: "a-old", writtenAt: new Date().toISOString() });
  }
}
const allGone = (sid) => STAGES.every((st) => !R.receiptExists(sid, st));
const appendTo = (p, text) => fs.writeFileSync(p, fs.readFileSync(p, "utf8") + text);

const mode = process.argv[2];

if (mode === "R3") {
  const s = R.sessionAt("outline", { tag: 3 });
  const st = present(s, "outline", { input: { stop_hook_active: true } });
  check("R3 stop_hook_active, clean presentation: no block is emitted", st.rc === 0 && st.out.trim() === "", show({ rc: st.rc, out: st.out }));
  const rc = R.readReceiptRaw(s.sid, "outline");
  check("R3 stop_hook_active, clean presentation: the outline receipt is written", rc !== null && rc.link && rc.link.kind === "url", show(rc));
  const e = R.echo(s.sid, "outline");
  check("R3 the echo after it reaches the dialog", e.dialog, show(e.json));
} else if (mode === "R4") {
  for (const env of [{ label: "url", mode: "published" }, { label: "path", mode: "plan-sync-off" }]) {
    const lineOf = (s, st) => (env.label === "url" ? urlLine(s, st) : pathLine(s, st, "plan-sync-off"));
    {
      const s = R.sessionAt("outline", { tag: 41 });
      present(s, "outline", { mode: env.mode, line: lineOf(s, "outline") });
      appendTo(s.plan, "\nedited after the presentation\n");
      const e = R.echo(s.sid, "outline", { mode: env.mode });
      check(`R4 ${env.label}: an edit after the presentation is denied (content)`, e.denied && !e.dialog, show(e.json));
      check(`R4 ${env.label}: the deny reason asks to present again`, presentAgain(e.reason, "outline"), e.reason);
    }
    {
      const s = R.sessionAt("intent", { tag: 42 });
      present(s, "intent", { mode: env.mode, line: lineOf(s, "intent") });
      appendTo(s.plan, "- #2 added to Issues only\n");
      const e = R.echo(s.sid, "intent", { mode: env.mode });
      check(`R4 ${env.label}: intent edited only in ## Issues after the presentation is denied`, e.denied && !e.dialog, show(e.json));
    }
  }
  {
    const s = R.sessionAt("outline", { tag: 43 });
    present(s, "outline");
    const e = R.echo(s.sid, "outline", { mode: "not-published" });
    check("R4 url: the plan is no longer published at the echo: denied (unpublished)", e.denied && !e.dialog, show(e.json));
  }
  {
    const s = R.sessionAt("outline", { tag: 44 });
    present(s, "outline");
    const rc = R.readReceiptRaw(s.sid, "outline");
    const other = path.join(path.dirname(s.plan), "other-outline.md");
    fs.writeFileSync(other, fs.readFileSync(s.plan));
    if (rc) R.writeReceiptRaw(s.sid, "outline", Object.assign({}, rc, { absPath: other }));
    const e = R.echo(s.sid, "outline");
    check("R4 the receipt names another path: denied (path)", rc !== null && e.denied && !e.dialog, show({ rc, json: e.json }));
  }
  {
    const s = R.sessionAt("outline", { tag: 45 });
    present(s, "outline", { mode: "plan-sync-off", line: pathLine(s, "outline", "plan-sync-off") });
    const e = R.echo(s.sid, "outline", { mode: "published" });
    check("R4 presented by path, a URL at the echo: denied (link)", e.denied && !e.dialog, show(e.json));
  }
  {
    const s = R.sessionAt("outline", { tag: 46 });
    present(s, "outline");
    const e = R.echo(s.sid, "outline", { mode: "plan-sync-off" });
    check("R4 presented by URL, a path at the echo: denied (link)", e.denied && !e.dialog, show(e.json));
  }
} else if (mode === "R5") {
  const s = R.sessionAt("outline", { tag: 5 });
  const outs = [1, 2, 3, 4].map(() => {
    const e = R.echo(s.sid, "outline");
    return { e, n: R.findings(s.sid).length };
  });
  outs.forEach((o, i) => {
    check(`R5 echo ${i + 1} without a receipt is denied (no cap)`, o.e.denied && !o.e.dialog, show(o.e.json));
    check(`R5 echo ${i + 1}: the deny reason asks to present again`, presentAgain(o.e.reason, "outline"), o.e.reason);
    check(`R5 echo ${i + 1}: a supervisor finding is recorded`, o.n >= 1, show({ findings: o.n }));
  });
  check("R5 the deny reason no longer speaks of a cap", !/\bcap\b|third|3rd/i.test(outs[2].e.reason), outs[2].e.reason);
} else if (mode === "R6") {
  const s = R.sessionAt("outline", { tag: 6 });
  const intent = R.linesFor(s.sid, "intent");
  fs.writeFileSync(intent.plan, R.EDITED_INTENT);
  const st = R.stop(s.sid, R.presentTurn(s, ["intent", "outline"], "Both plans.\n\n" + intent.urlLine + "\n" + s.urlLine));
  check("R6 two stages presented: both receipts are written", R.receiptExists(s.sid, "intent") && R.receiptExists(s.sid, "outline"), show({ rc: st.rc, out: st.out }));
  check("R6 the continuation names only the current step's stage", st.continued && st.reason.includes("WORKFLOW_CONFIRM_OUTLINE") && !/\bintent\b|CONFIRM_INTENT/i.test(st.reason.replace(/[^\n]*plan-link[^\n]*/g, "")),st.reason || st.out);
  const eo = R.echo(s.sid, "outline");
  check("R6 the outline echo reaches the dialog", eo.dialog, show(eo.json));
  const ei = R.echo(s.sid, "intent");
  check("R6 the intent echo in a later turn also reaches the dialog", ei.dialog, show(ei.json));
} else if (mode === "R7") {
  const s = R.sessionAt("outline", { tag: 7 });
  present(s, "outline");
  const e1 = R.echo(s.sid, "outline");
  check("R7 first echo with a matching receipt reaches the dialog", e1.dialog, show(e1.json));
  check("R7 the receipt is consumed by the pass", !R.receiptExists(s.sid, "outline"), show(R.readReceiptRaw(s.sid, "outline")));
  const e2 = R.echo(s.sid, "outline");
  check("R7 a second echo on the same presentation is denied", e2.denied && !e2.dialog, show(e2.json));
} else if (mode === "R8") {
  const broken = (s) => {
    const p = R.linesFor(s.sid, "outline");
    const good = { absPath: p.plan, link: { kind: "url", value: p.url }, contentSha: R.sha256(p.plan), anchorUuid: "a-x", writtenAt: new Date().toISOString() };
    return [
      ["not JSON", "{ not json"],
      ["a missing field", Object.assign({}, good, { contentSha: undefined })],
      ["a link of neither shape", Object.assign({}, good, { link: { kind: "ftp", value: "ftp://x" } })],
      ["a path link that is not absPath", Object.assign({}, good, { link: { kind: "path", value: path.join(path.dirname(p.plan), "elsewhere.md") } })],
    ];
  };
  for (let n = 0; n < 4; n++) {
    const s = R.sessionAt("outline", { tag: 81 + n });
    const [label, body] = broken(s)[n];
    R.writeReceiptRaw(s.sid, "outline", body);
    const e = R.echo(s.sid, "outline");
    check(`R8 broken receipt (${label}): denied`, e.denied && !e.dialog, show(e.json));
    check(`R8 broken receipt (${label}): the file is removed`, !R.receiptExists(s.sid, "outline"), "still present");
  }
  {
    const s = R.sessionAt("outline", { tag: 85 });
    present(s, "outline");
    const e = R.echo(s.sid, "outline", { noSid: true });
    check("R8 no resolvable session id: denied", e.denied && !e.dialog, show(e.json));
  }
  {
    const s = R.sessionAt("outline", { tag: 86 });
    present(s, "outline");
    fs.unlinkSync(s.plan);
    const e = R.echo(s.sid, "outline");
    check("R8 the artifact is gone: denied", e.denied && !e.dialog, show(e.json));
  }
  {
    const s = R.sessionAt("outline", { tag: 87 });
    present(s, "outline");
    const e = R.echo(s.sid, "outline", { fault: "link-throws" });
    check("R8 linkForFile throws: denied", e.denied && !e.dialog, show(e.json));
  }
  {
    const s = R.sessionAt("outline", { tag: 88 });
    present(s, "outline");
    fs.unlinkSync(s.plan);
    fs.mkdirSync(s.plan);
    const e = R.echo(s.sid, "outline");
    check("R8 the plan file cannot be read: denied", e.denied && !e.dialog, show(e.json));
  }
  {
    // Handover: the donor holds the receipt and the artifact; the heir holds neither.
    const donor = R.sessionAt("outline", { tag: 89 });
    present(donor, "outline");
    const heir = R.sessionAt("outline", { tag: 90 });
    fs.unlinkSync(heir.plan);
    const e1 = R.echo(heir.sid, "outline");
    check("R8 heir without its own artifact and receipt: denied", R.receiptExists(donor.sid, "outline") && e1.denied && !e1.dialog, show(e1.json));
    R.F.writePlan(heir.sid, "outline");
    present(heir, "outline");
    const e2 = R.echo(heir.sid, "outline");
    check("R8 heir after presenting again: the echo reaches the dialog", e2.dialog, show(e2.json));
  }
} else if (mode === "R9") {
  const off = R.cfg({ CONFIRM_OUTLINE: "off" });
  for (const m of ["published", "not-published"]) {
    const s = R.sessionAt("outline", { tag: 9 });
    const line = m === "published" ? s.urlLine : pathLine(s, "outline", "not-published");
    const st = R.stop(s.sid, R.presentTurn(s, ["outline"], "Summary with the plan " + line + " and more prose after it."), { cfg: off, mode: m });
    check(`R9 gate OFF (${m}): Stop does not block (no Gap 5, no unpublished)`, st.rc === 0 && !st.blocked, show({ rc: st.rc, out: st.out }));
    check(`R9 gate OFF (${m}): no receipt is written`, !R.receiptExists(s.sid, "outline"), show(R.readReceiptRaw(s.sid, "outline")));
    const st2 = R.stop(s.sid, R.presentTurn(s, ["outline"], "Here is the plan.\n\n" + line), { cfg: off, mode: m });
    check(`R9 gate OFF (${m}): a link-line close writes no receipt either`, !st2.blocked && !R.receiptExists(s.sid, "outline"), show({ rc: st2.rc, out: st2.out }));
    const e = R.echo(s.sid, "outline", { cfg: off, mode: m });
    check(`R9 gate OFF (${m}): the echo is skipped`, e.skipped, show(e.json));
  }
} else if (mode === "R10") {
  {
    const s = R.sessionAt("outline", { tag: 101 });
    present(s, "outline");
    check("R10 setup: the outline receipt exists", R.receiptExists(s.sid, "outline"), "no receipt");
    const st = R.stop(s.sid, R.presentTurn(s, ["outline"], "I rewrote the outline; more to come."));
    check("R10 plan-link missing (presented empty): Stop blocks", st.blocked && !st.continued, show({ rc: st.rc, out: st.out }));
    check("R10 plan-link missing: the earlier outline receipt is discarded", !R.receiptExists(s.sid, "outline"), "still present");
    const e = R.echo(s.sid, "outline");
    check("R10 plan-link missing: the echo right after is denied", e.denied && !e.dialog, show(e.json));
    const ok = present(s, "outline");
    const e2 = R.echo(s.sid, "outline");
    check("R10 after closing again without a block, the echo reaches the dialog", ok.continued && e2.dialog, show({ stop: ok.out, json: e2.json }));
  }
  {
    const s = R.sessionAt("outline", { tag: 102 });
    seedReceipts(s);
    const st = R.stop(s.sid, R.presentTurn(s, ["outline"], "Here is the plan.\n\n" + s.urlLine + "\n\n" + QUESTION));
    check("R10 closeOnLink block: Stop blocks", st.blocked && presentAgain(st.reason, "outline"), show({ rc: st.rc, out: st.out }));
    check("R10 closeOnLink block: every stage's receipt is discarded", allGone(s.sid), show(STAGES.map((x) => R.receiptExists(s.sid, x))));
  }
  {
    const s = R.sessionAt("outline", { tag: 103 });
    seedReceipts(s);
    const tp = R.writeTranscript(s.sid, [R.U("go", "u-p"), A("a-echo", BASH(R.echoOf("outline"), "e1")), TR("e1", "u-e1")]);
    const st = R.stop(s.sid, tp);
    check("R10 layer2 block: Stop blocks", st.blocked && st.reason.includes("Layer 2"), show({ rc: st.rc, out: st.out }));
    check("R10 layer2 block: every stage's receipt is discarded", allGone(s.sid), show(STAGES.map((x) => R.receiptExists(s.sid, x))));
  }
  {
    const s = R.sessionAt("outline", { tag: 104 });
    seedReceipts(s);
    const st = R.stop(s.sid, R.presentTurn(s, ["outline"], "Here is the plan.\n\n" + pathLine(s, "outline", "not-published")), { mode: "not-published" });
    check("R10 unpublished block: Stop blocks", st.blocked && presentAgain(st.reason, "outline"), show({ rc: st.rc, out: st.out }));
    check("R10 unpublished block: every stage's receipt is discarded", allGone(s.sid), show(STAGES.map((x) => R.receiptExists(s.sid, x))));
  }
  {
    // Japanese prose built from code points so the file stays ASCII-only.
    const JA_BODY = String.fromCharCode(0x3053, 0x306e, 0x8a08, 0x753b, 0x306f, 0x65e5, 0x672c, 0x8a9e, 0x3067, 0x66f8, 0x304b, 0x308c, 0x305f, 0x672c, 0x6587, 0x3067, 0x3059, 0x3002, 0x82f1, 0x8a9e, 0x3067, 0x306f, 0x3042, 0x308a, 0x307e, 0x305b, 0x3093, 0x3002);
    const s = R.sessionAt("outline", { tag: 105, body: "# Outline\n\n## Approach\n\n" + JA_BODY + "\n\n## Issues\n\n- #1 fixture\n" });
    seedReceipts(s);
    const st = R.stop(s.sid, R.presentTurn(s, ["outline"], "Here is the plan.\n\n" + s.urlLine));
    check("R10 planLang block: Stop blocks", st.blocked && /plan-lang/i.test(st.reason), show({ rc: st.rc, out: st.out }));
    check("R10 planLang block: every stage's receipt is discarded", allGone(s.sid), show(STAGES.map((x) => R.receiptExists(s.sid, x))));
  }
  {
    const s = R.sessionAt("outline", { tag: 106 });
    seedReceipts(s);
    const st = R.stop(s.sid, R.presentTurn(s, ["outline"], "Here is the plan.\n\n" + s.urlLine + "\n\n" + QUESTION), { input: { stop_hook_active: true } });
    check("R10 stop_hook_active with a block condition: no block is emitted", st.rc === 0 && st.out.trim() === "", show({ rc: st.rc, out: st.out }));
    check("R10 stop_hook_active with a block condition: every stage's receipt is discarded", allGone(s.sid), show(STAGES.map((x) => R.receiptExists(s.sid, x))));
  }
} else if (mode === "R11") {
  for (const reason of ["plan-sync-off", "not-provisioned", "host-mismatch"]) {
    for (const stage of ["intent", "outline"]) {
      const s = R.sessionAt(stage, { tag: 111 });
      const st = present(s, stage, { mode: reason, line: pathLine(s, stage, reason) });
      check(`R11 ${reason} ${stage}: a path link-line close is not blocked by a plan-link reason`, !st.blocked || st.continued, show({ rc: st.rc, out: st.out }));
      const rc = R.readReceiptRaw(s.sid, stage);
      check(`R11 ${reason} ${stage}: a path receipt with the whole-file contentSha is written`,
        rc !== null && rc.link && rc.link.kind === "path" && samePath(rc.link.value, s.plan) && rc.contentSha === R.sha256(s.plan), show(rc));
      const e = R.echo(s.sid, stage, { mode: reason });
      check(`R11 ${reason} ${stage}: the echo reaches the dialog`, e.dialog, show(e.json));
      const t = R.sessionAt(stage, { tag: 112 });
      present(t, stage, { mode: reason, line: pathLine(t, stage, reason) });
      appendTo(t.plan, "- #9 an Issues edit after the presentation\n");
      const d = R.echo(t.sid, stage, { mode: reason });
      check(`R11 ${reason} ${stage}: an edit (## Issues included) after the presentation is denied`, d.denied && !d.dialog, show(d.json));
    }
  }
  {
    const s = R.sessionAt("outline", { tag: 113 });
    const st = present(s, "outline", { mode: "not-published", line: pathLine(s, "outline", "not-published") });
    check("R11 not-published: a path-only close is blocked (unpublished)", st.blocked && presentAgain(st.reason, "outline"), show({ rc: st.rc, out: st.out }));
    check("R11 not-published: no receipt is written", !R.receiptExists(s.sid, "outline"), show(R.readReceiptRaw(s.sid, "outline")));
    const e = R.echo(s.sid, "outline", { mode: "not-published" });
    check("R11 not-published: the echo is denied", e.denied && !e.dialog, show(e.json));
    const ok = present(s, "outline", { mode: "published" });
    const rc = R.readReceiptRaw(s.sid, "outline");
    check("R11 after publishing, a URL close writes a url receipt", ok.continued && rc !== null && rc.link && rc.link.kind === "url", show({ out: ok.out, rc }));
    const e2 = R.echo(s.sid, "outline");
    check("R11 after publishing, the echo reaches the dialog", e2.dialog, show(e2.json));
  }
} else if (mode === "R12") {
  const s = R.sessionAt("outline", { tag: 12 });
  present(s, "outline");
  check("R12 setup: the outline receipt exists", R.receiptExists(s.sid, "outline"), "no receipt");
  const st = present(s, "outline", { fault: "presented-throws" });
  check("R12 an exception inside the Stop evaluation exits 0", st.rc === 0, show({ rc: st.rc, out: st.out, err: st.err.slice(0, 200) }));
  check("R12 the existing receipt is discarded and none is written", allGone(s.sid), show(R.readReceiptRaw(s.sid, "outline")));
  const e = R.echo(s.sid, "outline");
  check("R12 the later echo is denied", e.denied && !e.dialog, show(e.json));
} else if (mode === "R14") {
  // Two concurrent echoes on one receipt: only the process whose consume (unlink) succeeds passes.
  (async () => {
    for (let round = 1; round <= 5; round++) {
      const s = R.sessionAt("outline", { tag: 140 + round });
      present(s, "outline");
      const setup = R.receiptExists(s.sid, "outline");
      const res = await Promise.all([R.echoAsync(s.sid, "outline"), R.echoAsync(s.sid, "outline")]);
      const winners = res.filter((e) => e.dialog);
      const losers = res.filter((e) => e.denied && !e.dialog);
      const detail = show(res.map((e) => ({ rc: e.rc, json: e.json, err: e.err.slice(0, 200) })));
      check(`R14 round ${round}: exactly one concurrent echo reaches the dialog`, setup && winners.length === 1 && losers.length === 1, detail);
      check(`R14 round ${round}: the losing echo's deny reason asks to present again`, losers.length === 1 && presentAgain(losers[0].reason, "outline"), losers.length === 1 ? losers[0].reason : detail);
      check(`R14 round ${round}: the receipt is consumed`, !R.receiptExists(s.sid, "outline"), show(R.readReceiptRaw(s.sid, "outline")));
    }
  })().catch((e) => check("R14 driver", false, String(e && e.stack || e)));
} else if (mode === "R15") {
  {
    const s = R.sessionAt("outline", { tag: 151 });
    // A repeated Stop on an identical tail is out of scope: in real use the tail changes after the echo.
    present(s, "outline");
    const e1 = R.echo(s.sid, "outline");
    check("R15 idempotency: the first echo reaches the dialog and consumes the receipt", e1.dialog && !R.receiptExists(s.sid, "outline"), show(e1.json));
    const e2 = R.echo(s.sid, "outline");
    check("R15 idempotency: a second echo with no new presentation is denied without a dialog", e2.denied && !e2.dialog, show(e2.json));
  }
  {
    const s = R.sessionAt("detail", { tag: 152 });
    present(s, "detail");
    check("R15 detail: the detail receipt is written", R.receiptExists(s.sid, "detail"), "no receipt");
    const e1 = R.echo(s.sid, "detail");
    check("R15 detail: the first echo reaches the dialog", e1.dialog, show(e1.json));
    check("R15 detail: the receipt is consumed by the pass", !R.receiptExists(s.sid, "detail"), show(R.readReceiptRaw(s.sid, "detail")));
    const e2 = R.echo(s.sid, "detail");
    check("R15 detail: a second echo on the same presentation is denied", e2.denied && !e2.dialog, show(e2.json));
  }
} else {
  check("r-cases-driver mode", false, "unknown mode: " + mode);
}
