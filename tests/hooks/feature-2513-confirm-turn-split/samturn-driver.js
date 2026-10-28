"use strict";
// #2650 mode "samturn <stage>" of ../feature-2513-confirm-turn-split.sh, rebased on the #2729
// presentation receipt: the echo in the plan's own turn (after the Stop continuation) reaches the
// dialog only through the receipt, which the pass consumes; the transcript shape decides nothing.
// Receipt-format and judge-cause coverage: tests/hooks/feature-2729-presentation-receipt.sh.
// Prints PASS|name / FAIL|name|detail lines.
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const X = require("../feature-2650-confirm-continuation/fixture");

const { U, A, T, W, BASH, TR, STOPFB, ECHO, show, check: ok } = X;
const STAGE = process.argv[2];
const FB = "[confirm-plan] continue: as your next message, emit only the CONFIRM echo";
const seed = (sid, stage, over) => !!X.seedReceipt(sid, stage || STAGE, over ? { link: over } : undefined);
const has = (sid, stage) => X.receiptExists(sid, stage || STAGE);
// writeRaw(sid, body) -> a hand-written receipt file (broken or foreign-bound).
const writeRaw = (sid, body) => {
  const p = X.receiptPath(sid, STAGE);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, typeof body === "string" ? body : JSON.stringify(body));
};

// runHook(s, entries, opts) -> {json, rc, deny, msg}. The echo's tool_use_id rides on the input.
function runHook(s, entries, opts) {
  const o = opts || {};
  const tp = o.transcriptPath || X.writeTranscript(s.sid, entries);
  const input = { session_id: s.sid, transcript_path: tp, hook_event_name: "PreToolUse", tool_name: "Bash",
    tool_use_id: o.toolUseId || "e1", tool_input: { command: X.echoOf(o.stage || STAGE) } };
  const env = Object.assign({}, process.env, X.gateEnv());
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, [path.join(X.ROOT, "hooks/confirm-checkpoint.js")], { input: JSON.stringify(input), env, encoding: "utf8", timeout: 30000, cwd: X.TDIR });
  let json = {};
  try { json = r.stdout ? JSON.parse(r.stdout) : {}; } catch (_) { json = { unparsed: r.stdout }; }
  const hso = json.hookSpecificOutput || {};
  return { json, rc: r.status, deny: hso.permissionDecision === "deny", msg: json.systemMessage || "" };
}
// #2731: the dialog systemMessage is the stage fact line (`[<stage>] ...`), no "Click Allow" wording.
const passes = (r) => !r.deny && r.rc === 0 && r.json.decision !== "block" && /^\[(intent|outline|detail)\] /.test(r.msg);
function expectDeny(label, r, s) {
  ok(label + " — deny", r.deny, show(r.json));
  if (!r.deny) return;
  const reason = String(r.json.hookSpecificOutput.permissionDecisionReason || "") + "\n" + String(r.json.reason || "");
  ok(label + " — reason names bin/plan-link --stage " + STAGE, reason.includes("bin/plan-link") && reason.includes("--stage " + STAGE), reason);
  ok(label + " — reason carries no URL, plan path or sid", !/https?:\/\//.test(reason) && !reason.includes(s.fwd) && !reason.includes(s.plan) && !reason.includes(s.sid), reason);
  ok(label + " — reason never invites a same-turn retry", !/retry|try again/i.test(reason), reason);
}

// The presentation turn: Write, the anchor text with the link, the Stop feedback, then extras and the echo.
const sameTurn = (s, extra) => [U("write the plan", "u-prompt"), A("a-write", W(s.plan)), TR("w1", "u-tr"),
  A("a-anchor", T("Here is the plan.\n\n" + s.line)), STOPFB(FB, "u-fb"), ...(extra || []), A("a-echo", ECHO(STAGE, "e1"))];
const fresh = () => X.sessionAt(STAGE);

// C1 accept, C7 one-shot: the pass consumes the receipt.
{
  const s = fresh();
  const w = seed(s.sid);
  const entries = sameTurn(s);
  const r = runHook(s, entries);
  ok(`${STAGE} C1 same-turn continuation with the receipt — passes to the dialog`, w && passes(r), show({ w, json: r.json }));
  ok(`${STAGE} C1 the receipt is consumed`, w && !has(s.sid), "receipt left");
  const again = runHook(s, entries);
  ok(`${STAGE} C7 the same echo again — receipt gone, denied`, w && again.deny, show(again.json));
}
// C2 no receipt.
{ const s = fresh(); expectDeny(`${STAGE} C2 plan and echo in one turn without a receipt`, runHook(s, sameTurn(s)), s); }
// C3 entries between the anchor and the echo: only a real change to the plan denies.
{
  const s = fresh();
  const w = seed(s.sid);
  ok(`${STAGE} C3 a Bash tool_use between the anchor and the echo, with the receipt — the shape decides nothing`,
    w && passes(runHook(s, sameTurn(s, [A("a-b2", BASH("ls", "b2"))]))), "denied");
}
{
  const s = fresh();
  seed(s.sid);
  fs.writeFileSync(s.plan, "# redone plan\n");
  expectDeny(`${STAGE} C3 a Write between the anchor and the echo changed the plan after the receipt`, runHook(s, sameTurn(s, [A("a-w2", W(s.plan, "w2"))])), s);
}
// C4 two turns: the previous turn ended on the link and the user replied.
{
  const s = fresh();
  const twoTurn = [U("write the plan"), A(null, T(s.line)), U("looks good, go ahead"), A("a-echo", ECHO(STAGE, "e1"))];
  expectDeny(`${STAGE} C4 two-turn shape without a receipt — the shape alone does not pass`, runHook(s, twoTurn), s);
  ok(`${STAGE} C4 two-turn shape with the receipt — passes`, seed(s.sid) && passes(runHook(s, twoTurn)), "denied");
}
// C5 a receipt from the previous turn: the previous turn's shape decides nothing.
for (const [label, prev] of [["previous turn ends on the link", (s) => [A("a-anchor", T(s.line))]],
  ["previous turn does not end on the link", (s) => [A("a-anchor", T(s.line)), A("a-more", T("Done."))]]]) {
  const s = fresh();
  const w = seed(s.sid);
  const r = runHook(s, [U("write the plan", "u-1"), ...prev(s), U("looks good, go ahead", "u-2"), A("a-echo", ECHO(STAGE, "e1"))]);
  ok(`${STAGE} C5 receipt, ${label} — passes`, w && passes(r), show(r.json));
  ok(`${STAGE} C5 receipt, ${label} — the receipt is consumed`, w && !has(s.sid), "receipt left");
}
// C6 a broken receipt: deny, and the file is removed so a re-presentation can write it again.
for (const [label, body] of [["not JSON", "{not json"], ["contentSha missing", { absPath: "x", link: { kind: "path", value: "x" }, anchorUuid: "a" }],
  ["link not url/path", { absPath: "x", link: { kind: "other", value: "x" }, contentSha: "x", anchorUuid: "a" }]]) {
  const s = fresh();
  writeRaw(s.sid, body);
  expectDeny(`${STAGE} C6 broken receipt (${label})`, runHook(s, sameTurn(s)), s);
  ok(`${STAGE} C6 broken receipt (${label}) — the file is removed`, !has(s.sid), "receipt left");
}
// C8 transcript unreadable: fail-closed without a receipt; with one, the transcript is not read.
{
  const s = fresh();
  expectDeny(`${STAGE} C8 transcript unreadable, no receipt`, runHook(s, null, { transcriptPath: path.join(X.TDIR, "missing.jsonl") }), s);
  const w = seed(s.sid);
  ok(`${STAGE} C8 transcript unreadable, with the receipt — passes`, w && passes(runHook(s, null, { transcriptPath: path.join(X.TDIR, "missing.jsonl") })), "denied");
}
// C10 another stage's receipt does not open this stage.
{
  const s = fresh();
  const other = STAGE === "intent" ? "outline" : "intent";
  X.F.writePlan(s.sid, other);
  const w = seed(s.sid, other);
  ok(`${STAGE} C10 precondition — the ${other} receipt was written`, w, "not written");
  expectDeny(`${STAGE} C10 only the ${other} receipt exists`, runHook(s, sameTurn(s)), s);
}
// C11 the receipt binds another session's file; C12 the plan changed after the receipt; C13 another link.
{
  const s = fresh();
  const o = X.sessionAt(STAGE);
  const w = seed(o.sid);
  if (w) writeRaw(s.sid, fs.readFileSync(X.receiptPath(o.sid, STAGE), "utf8"));
  ok(`${STAGE} C11 precondition — the foreign receipt was written`, w && has(s.sid), "not written");
  expectDeny(`${STAGE} C11 the receipt binds another session's ${STAGE} file`, runHook(s, sameTurn(s)), s);
}
{
  const s = fresh();
  const w = seed(s.sid);
  fs.appendFileSync(s.plan, "\nChanged after the Stop.\n");
  ok(`${STAGE} C12 precondition — receipt written`, w, "not written");
  expectDeny(`${STAGE} C12 the plan changed after the receipt was written`, runHook(s, sameTurn(s)), s);
}
{
  const s = fresh();
  const w = seed(s.sid, STAGE, { kind: "url", value: "https://example.invalid/test-owner/test-repo/blob/main/other.md" });
  ok(`${STAGE} C13 precondition — receipt written`, w, "not written");
  expectDeny(`${STAGE} C13 the receipt's link differs from today's link`, runHook(s, sameTurn(s)), s);
}
