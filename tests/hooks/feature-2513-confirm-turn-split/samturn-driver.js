"use strict";
// #2650 mode "samturn <stage>" of ../feature-2513-confirm-turn-split.sh: confirm-checkpoint's
// same-turn continuation path (C1-C13). Marks are written with the Stop hook's own functions
// (writeContinuationMark, approvalArtifactPath, linkKey, computeArtifactSha), never a hand-built
// payload. Prints PASS|name / FAIL|name|detail lines.
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const X = require("../feature-2650-confirm-continuation/fixture");

const { U, A, T, W, BASH, TR, STOPFB, ECHO, show, check: ok } = X;
const STAGE = process.argv[2];
const STEP = X.STEP[STAGE];
const PL = require(path.join(X.ROOT, "hooks/lib/plan-link"));
const { computeArtifactSha } = require(path.join(X.ROOT, "hooks/workflow-state/completion-approval"));
const CC = X.tryRequire("hooks/lib/confirm-continuation.js");
const TM = require(path.join(X.ROOT, "hooks/lib/turn-marker"));
const ready = !CC.__missing && typeof TM.writeContinuationMark === "function";
const FB = "[confirm-plan] continue: as your next message, emit only the CONFIRM echo";

// mark(sid, stage, over) -> true when written. Fields come from the implementation's helpers.
function mark(sid, stage, over) {
  if (!ready) return false;
  const absPath = CC.approvalArtifactPath(sid, stage);
  const link = CC.linkKey(PL.linkForFile(absPath, { plansDir: X.F.PLANS_DIR }));
  const f = Object.assign({ anchorUuid: "a-anchor", absPath, link, artifactSha: computeArtifactSha(sid, X.STEP[stage]) }, over || {});
  try { return TM.writeContinuationMark(sid, stage, f) === true; } catch (_) { return false; }
}
const hasMark = (sid, stage) => fs.existsSync(X.markPath(sid, stage));

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
const passes = (r) => !r.deny && r.rc === 0 && r.json.decision !== "block" && r.msg.includes("Click Allow");
function expectDeny(label, r, s) {
  ok(label + " — deny", r.deny, show(r.json));
  if (!r.deny) return;
  const reason = String(r.json.hookSpecificOutput.permissionDecisionReason || "") + "\n" + String(r.json.reason || "");
  ok(label + " — reason names the stage and bin/plan-link", reason.includes(STAGE) && reason.includes("bin/plan-link"), reason);
  ok(label + " — reason carries no URL, plan path or sid", !/https?:\/\//.test(reason) && !reason.includes(s.fwd) && !reason.includes(s.plan) && !reason.includes(s.sid), reason);
  ok(label + " — reason says not to echo again in this turn", reason.includes("Do not echo it again in this turn"), reason);
  ok(label + " — reason never invites a same-turn retry", !/retry|try again/i.test(reason), reason);
}

// The presentation turn: Write, the anchor text with the link, the Stop feedback, then extras and the echo.
const sameTurn = (s, extra) => [U("write the plan", "u-prompt"), A("a-write", W(s.plan)), TR("w1", "u-tr"),
  A("a-anchor", T("Here is the plan.\n\n" + s.line)), STOPFB(FB, "u-fb"), ...(extra || []), A("a-echo", ECHO(STAGE, "e1"))];
const fresh = () => X.sessionAt(STAGE);

ok(`${STAGE} precondition — confirm-continuation.js and writeContinuationMark exist`, ready, CC.__missing || "writeContinuationMark missing");

// C1 accept, C7 one-shot.
{
  const s = fresh();
  const w = mark(s.sid, STAGE);
  const entries = sameTurn(s);
  const r = runHook(s, entries);
  ok(`${STAGE} C1 same-turn continuation — passes to the dialog`, w && passes(r), show({ w, json: r.json }));
  ok(`${STAGE} C1 the mark is consumed`, w && !hasMark(s.sid, STAGE), "mark left");
  const again = runHook(s, entries);
  ok(`${STAGE} C7 the same echo again — mark gone, two-turn path denies`, w && passes(r) && again.deny, show(again.json));
}
// C2 no mark.
{ const s = fresh(); expectDeny(`${STAGE} C2 plan and echo in one turn without a mark`, runHook(s, sameTurn(s)), s); }
// C3 a redo after the anchor: Write or Bash.
for (const [label, redo] of [["Write", (s) => A("a-w2", W(s.plan, "w2"))], ["Bash", () => A("a-b2", BASH("ls", "b2"))]]) {
  const s = fresh();
  const w = mark(s.sid, STAGE);
  expectDeny(`${STAGE} C3 a ${label} tool_use between the anchor and the echo`, runHook(s, sameTurn(s, [redo(s)])), s);
  ok(`${STAGE} C3 (${label}) the mark is consumed`, w && !hasMark(s.sid, STAGE), show({ w }));
}
// C4 no mark, two-turn path: the previous turn ended on the link and the user replied.
{
  const s = fresh();
  ok(`${STAGE} C4 two-turn fallback passes`, passes(runHook(s, [U("write the plan"), A(null, T(s.line)), U("looks good, go ahead"), A("a-echo", ECHO(STAGE, "e1"))])), "denied");
}
// C5 a stale mark: its anchor sits in the previous turn.
for (const [label, prev, want] of [["previous turn ends on the link", (s) => [A("a-anchor", T(s.line))], "pass"],
  ["previous turn does not end on the link", (s) => [A("a-anchor", T(s.line)), A("a-more", T("Done."))], "deny"]]) {
  const s = fresh();
  const w = mark(s.sid, STAGE);
  const r = runHook(s, [U("write the plan", "u-1"), ...prev(s), U("looks good, go ahead", "u-2"), A("a-echo", ECHO(STAGE, "e1"))]);
  if (want === "pass") ok(`${STAGE} C5 stale mark, ${label} — passes`, passes(r), show(r.json));
  else expectDeny(`${STAGE} C5 stale mark, ${label}`, r, s);
  ok(`${STAGE} C5 stale mark, ${label} — the mark is consumed`, w && !hasMark(s.sid, STAGE), show({ w }));
}
// C6 a broken mark: the two-turn path runs; no prior prompt in this turn -> deny; the file is removed.
for (const [label, body] of [["not JSON", "{not json"], ["anchorUuid missing", JSON.stringify({ absPath: "x", link: "x", artifactSha: "x" })],
  ["artifactSha missing", JSON.stringify({ anchorUuid: "a-anchor", absPath: "x", link: "x" })]]) {
  const s = fresh();
  fs.mkdirSync(path.dirname(X.markPath(s.sid, STAGE)), { recursive: true });
  fs.writeFileSync(X.markPath(s.sid, STAGE), body);
  const r = runHook(s, [U("write the plan", "u-prompt"), A("a-anchor", T(s.line)), STOPFB(FB, "u-fb"), A("a-echo", ECHO(STAGE, "e1"))]);
  expectDeny(`${STAGE} C6 broken mark (${label})`, r, s);
  ok(`${STAGE} C6 broken mark (${label}) — the file is removed`, !hasMark(s.sid, STAGE), "mark left");
}
// C8 transcript unreadable: fail-open pass, mark removed.
{
  const s = fresh();
  const w = mark(s.sid, STAGE);
  const r = runHook(s, null, { transcriptPath: path.join(X.TDIR, "missing.jsonl") });
  ok(`${STAGE} C8 transcript unreadable — fail-open pass`, passes(r), show(r.json));
  ok(`${STAGE} C8 the mark is consumed`, w && !hasMark(s.sid, STAGE), show({ w }));
}
// C10 another stage's mark does not open this stage's same-turn path.
{
  const s = fresh();
  const other = STAGE === "intent" ? "outline" : "intent";
  X.F.writePlan(s.sid, other);
  const w = mark(s.sid, other);
  expectDeny(`${STAGE} C10 only the ${other} mark exists`, runHook(s, sameTurn(s)), s);
  ok(`${STAGE} C10 precondition — the ${other} mark was written`, w, "not written");
}
// C11 the mark names another session's file; C12 the plan changed after the Stop; C13 another link.
{
  const s = fresh();
  const o = X.sessionAt(STAGE);
  const oPath = ready ? CC.approvalArtifactPath(o.sid, STAGE) : null;
  const w = ready && mark(s.sid, STAGE, { absPath: oPath, link: CC.linkKey(PL.linkForFile(oPath, { plansDir: X.F.PLANS_DIR })), artifactSha: computeArtifactSha(o.sid, STEP) });
  expectDeny(`${STAGE} C11 the mark binds another session's ${STAGE} file`, runHook(s, sameTurn(s)), s);
  ok(`${STAGE} C11 the mark is consumed`, w && !hasMark(s.sid, STAGE), show({ w }));
}
{
  const s = fresh();
  const w = mark(s.sid, STAGE);
  fs.appendFileSync(s.plan, "\nChanged after the Stop.\n");
  expectDeny(`${STAGE} C12 the plan changed after the mark was written`, runHook(s, sameTurn(s)), s);
  ok(`${STAGE} C12 precondition — mark written`, w, "not written");
}
{
  const s = fresh();
  const w = mark(s.sid, STAGE, { link: "https://example.invalid/test-owner/test-repo/blob/main/other.md" });
  expectDeny(`${STAGE} C13 the mark's link differs from today's link`, runHook(s, sameTurn(s)), s);
  ok(`${STAGE} C13 precondition — mark written`, w, "not written");
}
