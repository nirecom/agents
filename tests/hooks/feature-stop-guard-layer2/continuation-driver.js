"use strict";
// #2650 Stop-hook continuation branch (N1-N21, T6), driven by ./continuation.sh, rebased on the
// #2729 presentation receipt. A presentation turn that wrote a plan, ends on its plan-link line
// and has no approval while the gate is not OFF gets decision:block "[confirm-plan] continue:"
// and a receipt anchored to the last text entry. Every "no continuation" case runs its continuing
// twin first. Receipt lifecycle and multi-stage cases: tests/hooks/feature-2729-presentation-receipt.sh.
// Prints PASS|name / FAIL|name|detail lines.
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const X = require("../feature-2650-confirm-continuation/fixture");

const { A, T, U, W, TR, ECHO, BASH, show, check } = X;
const CONT = "[confirm-plan] continue:";
const UNREADABLE = path.join(__dirname, "..", "feature-2650-confirm-continuation", "unreadable-preload.js");
const RS = require("../../lib/presentation-receipt-seed");

// present(s, opts) -> transcript path. The turn writes the plan (unless opts.write === false),
// then closes on a text entry (uuid "a-anchor") carrying opts.text or the stage's plan-link line.
function present(s, opts) {
  const o = opts || {};
  const entries = [U("write the plan", "u-prompt")];
  if (o.write !== false) {
    entries.push(A("a-write", W(s.plan)), TR("w1", "u-tr"));
    X.turnMarker(s.sid, s.stage, s.plan);
  }
  for (const m of o.extraMarkers || []) X.turnMarker(s.sid, m.stage, m.plan);
  entries.push(A(o.noUuid ? null : "a-anchor", T("Here is the plan.\n\n" + (o.text == null ? s.line : o.text))));
  for (const e of o.after || []) entries.push(e);
  return X.writeTranscript(s.sid, entries);
}

const readReceipt = (sid, stage) => { try { return JSON.parse(fs.readFileSync(X.receiptPath(sid, stage), "utf8")); } catch (_) { return null; } };
const noReceipt = (s, stage) => !X.receiptExists(s.sid, stage || s.stage);
// blocks: the continue block alone (gates controls); continues: the block plus the anchored receipt.
const blocks = (r) => r.rc === 2 && r.json.decision === "block" && r.reason.includes(CONT);
function continues(r, s) {
  const m = readReceipt(s.sid, s.stage);
  return blocks(r) && !!m && m.anchorUuid === "a-anchor";
}
// noticeOnly: exit 0 and stdout is exactly a {systemMessage} JSON (no decision) — the #2811 unrecorded notice.
function noticeOnly(r) {
  let j = null;
  try { j = JSON.parse(r.out); } catch (_) { return false; }
  return r.rc === 0 && !!j && typeof j.systemMessage === "string" && j.systemMessage !== "" && !("decision" in j);
}
// noticeFor: the notice must be the unrecorded-presentation notice of exactly the given stages.
const noticeIs = (r, stages) => {
  try { return JSON.parse(r.out).systemMessage === require("../../../hooks/stop-confirm-plan-guard/undecidable").noticeFor(stages); } catch (_) { return false; }
};
const quiet = (r, s) => r.rc === 0 && r.out === "" && noReceipt(s);

function expectContinue(label, r, s) {
  check(`${label} — decision:block, exit 2, "${CONT}" reason, receipt anchored to the last text entry`, continues(r, s),
    show({ rc: r.rc, out: r.out, receipt: readReceipt(s.sid, s.stage) }));
}
// twin(stage, label) -> the continuing control for a "no continuation" case.
function twin(stage, label) {
  const s = X.sessionAt(stage);
  const r = X.runStop(s.sid, present(s));
  check(`${label} — control: the same scene without the case's condition continues`, blocks(r), show({ rc: r.rc, out: r.out }));
  return blocks(r);
}
function expectQuiet(label, r, s, stage) {
  const ok = twin(stage || s.stage, label);
  check(`${label} — exit 0, no output, no receipt`, ok && quiet(r, s), show({ control: ok, rc: r.rc, out: r.out, receipt: readReceipt(s.sid, s.stage) }));
}

// Preconditions: the two preloads take effect (else T6 / N20 could pass vacuously). The flag is file-only (#2726).
{
  const { spawnSync } = require("child_process");
  const s = X.sessionAt("outline");
  const log = path.join(X.TDIR, `pre-${s.sid}.log`);
  const root = X.CE.confirmEnvRoot(path.join(X.TDIR, "sg2-cfg"), { CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "off", CONFIRM_DETAIL: "on", PLAN_LANG: "english" });
  const env = X.CE.childEnvWith(root, Object.assign({}, process.env, { CC_PROBE_LOG: log, CC_UNREADABLE: s.plan,
    NODE_OPTIONS: X.nodeOptions([X.PROBE_COUNT_PRELOAD, UNREADABLE]) }));
  const code = `const p=require(${JSON.stringify(path.join(X.ROOT, "hooks/lib/confirm-gate/probe.js"))});` +
    `const v=p.probeConfirmGateSync("CONFIRM_OUTLINE",5000);` +
    `const c=require(${JSON.stringify(path.join(X.ROOT, "hooks/workflow-state/completion-approval.js"))});` +
    `process.stdout.write(v+" "+String(c.computeArtifactSha(${JSON.stringify(s.sid)},"outline")));`;
  const r = spawnSync(process.execPath, ["-e", code], { env, encoding: "utf8", timeout: 30000 });
  const n = X.countLog(log);
  const [probeValue, sha] = String(r.stdout).split(" ");
  check("precondition — the probe-count preload logs one in-process CONFIRM probe, which reads OFF", n === 1 && probeValue === "OFF", `n=${n} out=${r.stdout} err=${r.stderr}`);
  check("precondition — the unreadable preload makes computeArtifactSha null", sha === "null" && !!X.F.implSha(s.sid, "outline"), show([r.stdout, r.stderr]));
  const t = X.sessionAt("outline");
  const rc = X.runStop(t.sid, present(t), { count: true });
  check("precondition — a continuing Stop hook run logs one probe", blocks(rc) && rc.probes === 1, show({ rc: rc.rc, out: rc.out, probes: rc.probes }));
}

const same = (a, b) => path.resolve(String(a)).toLowerCase() === path.resolve(String(b)).toLowerCase();
const sha256 = (p) => crypto.createHash("sha256").update(fs.readFileSync(p)).digest("hex");
const reasons = [];
for (const stage of X.STAGES) {
  // N1 / N15 / N19: the continuation and the receipt's binding, per stage.
  const s = X.sessionAt(stage);
  const r = X.runStop(s.sid, present(s));
  expectContinue(`N1 ${stage} wrote the plan, ends on its link, unapproved, gate ON`, r, s);
  reasons.push([stage, s, r.reason]);
  const m = readReceipt(s.sid, stage);
  const target = RS.canonicalPlan(s.sid, stage);
  check(`N19 ${stage} receipt.absPath is <plans>/<sid>-${stage}.md`, !!m && typeof m.absPath === "string" && same(m.absPath, target), show([m, target]));
  check(`N19 ${stage} receipt.link is the shown local path`, !!m && !!m.link && m.link.kind === "path" && same(m.link.value, s.plan), show(m));
  check(`N19 ${stage} receipt.contentSha is the sha256 of the whole plan file`, !!m && m.contentSha === sha256(s.plan), show(m));

  // N4: approved at the current sha.
  const a = X.sessionAt(stage, { approved: true });
  expectQuiet(`N4 ${stage} approved at the current sha`, X.runStop(a.sid, present(a)), a);

  // N17: the turn wrote and showed another session's file of the stage; the target exists too.
  const o = X.sessionAt(stage);
  const other = X.linesFor(X.uuidSid(9), stage);
  fs.writeFileSync(other.plan, X.F.PLAN_BODY[stage]);
  const tp17 = (() => {
    const entries = [U("write the plan", "u-prompt"), A("a-write", W(other.plan)), TR("w1", "u-tr"), A("a-anchor", T("Plan:\n\n" + other.line))];
    X.turnMarker(o.sid, stage, other.plan);
    return X.writeTranscript(o.sid, entries);
  })();
  expectQuiet(`N17 ${stage} the turn showed another session's ${stage} file`, X.runStop(o.sid, tp17), o);
}

// N1 with a published plan: the URL line is the link the turn shows.
{
  const s = X.sessionAt("outline");
  const r = X.runStop(s.sid, present(s, { text: s.urlLine }), { publish: true });
  expectContinue("N1 outline published (URL line)", r, s);
  reasons.push(["outline", s, r.reason]);
  const m = readReceipt(s.sid, "outline");
  check("N19 outline published — receipt.link is the URL", !!m && !!m.link && m.link.kind === "url" && m.link.value === s.url, show(m));
}

// N16: the continue reason names the echo form and the stage; no URL, path, sid or failure word.
for (const [stage, s, reason] of reasons) {
  const lbl = `N16 ${stage} continue reason wording`;
  check(`${lbl} — carries echo "<<WORKFLOW_CONFIRM_${stage.toUpperCase()}`, reason.includes(`echo "<<WORKFLOW_CONFIRM_${stage.toUpperCase()}`), reason);
  check(`${lbl} — names the ${stage} stage`, reason.toLowerCase().includes(stage), reason);
  check(`${lbl} — no URL, no plan path, no sid`, !!reason && !/https?:\/\//.test(reason) && !reason.includes(s.fwd) &&
    !reason.includes(s.plan) && !reason.includes(path.basename(s.plan)) && !reason.includes(s.sid), reason);
  check(`${lbl} — no error/fail/missing words`, !!reason && !/error|fail|missing/i.test(reason), reason);
}

// N2: a re-presentation turn without a Write still continues.
{ const s = X.sessionAt("outline"); expectContinue("N2 re-presentation without a Write", X.runStop(s.sid, present(s, { write: false })), s); }

// N3: the stage's echo is in the turn: Layer 2's follow-up check runs, no continuation, no receipt.
{
  const s = X.sessionAt("outline");
  X.turnMarker(s.sid, "outline", s.plan);
  const tp = X.writeTranscript(s.sid, [U("write the plan", "u-prompt"), A("a-write", W(s.plan)), TR("w1", "u-tr"),
    A("a-anchor", T("Here is the plan.\n\n" + s.line), ECHO("outline"))]);
  const r = X.runStop(s.sid, tp);
  const ok = twin("outline", "N3 echo in the turn");
  check("N3 echo in the turn — Layer 2 follow-up block, not the continuation, no receipt",
    ok && r.rc === 2 && r.reason.startsWith("[confirm-plan] Layer 2/follow-up") && noReceipt(s), show({ rc: r.rc, out: r.out }));
}

// N5 / N10: an OFF gate (outline, and detail's present-and-stop path) ends normally.
for (const [label, stage, key] of [["N5 CONFIRM_OUTLINE=off", "outline", "CONFIRM_OUTLINE"], ["N10 CONFIRM_DETAIL=off (present-and-stop path)", "detail", "CONFIRM_DETAIL"]]) {
  const s = X.sessionAt(stage);
  expectQuiet(label, X.runStop(s.sid, present(s), { env: { [key]: "off" } }), s);
}

// N6: intent is not off-waivable, so CONFIRM_INTENT=off still continues.
{ const s = X.sessionAt("intent"); expectContinue("N6 CONFIRM_INTENT=off on intent", X.runStop(s.sid, present(s), { env: { CONFIRM_INTENT: "off" } }), s); }

// N7: stop_hook_active (#2811) — a complete presentation still continues once: the receipt is written
// and marked continuedAt; a second Stop under the same state is capped (exit 0, no continue).
{
  const s = X.sessionAt("outline");
  const tp = present(s);
  const r = X.runStop(s.sid, tp, { input: { stop_hook_active: true } });
  const m = readReceipt(s.sid, "outline");
  check("N7 stop_hook_active, complete presentation — continues once: exit 2, decision:block, continue reason, receipt written with continuedAt",
    continues(r, s) && !!m && !!m.continuedAt, show({ rc: r.rc, out: r.out, receipt: m }));
  const r2 = X.runStop(s.sid, tp, { input: { stop_hook_active: true } });
  const m2 = readReceipt(s.sid, "outline");
  check("N7 stop_hook_active, second Stop under the same state — capped: exit 0, no output, receipt kept with continuedAt",
    r2.rc === 0 && r2.out === "" && !!m2 && !!m2.continuedAt, show({ rc: r2.rc, out: r2.out, receipt: m2 }));
}

// N8: the plan was written but the last text does not show the link — the plan-link block wins.
{
  const s = X.sessionAt("outline");
  const r = X.runStop(s.sid, present(s, { text: "The plan is ready." }));
  const ok = twin("outline", "N8 link missing");
  check("N8 link missing — [confirm-plan] plan-link: block, no receipt", ok && r.rc === 2 && r.reason.startsWith("[confirm-plan] plan-link:") && noReceipt(s), show({ rc: r.rc, out: r.out }));
}

// N9: the plan violates PLAN_LANG=japanese (English-only body) — the plan-lang block, no receipt.
{
  const s = X.sessionAt("outline", { body: "# Outline\n\n## Approach\n\nThis plan body is written entirely in English words.\n\n## Issues\n\n- #1 fixture\n" });
  const r = X.runStop(s.sid, present(s), { env: { PLAN_LANG: "japanese" } });
  check("N9 relint violation — a plan-lang block, not the continuation, no receipt",
    r.rc === 2 && /plan-lang/.test(r.reason) && !r.reason.includes(CONT) && noReceipt(s), show({ rc: r.rc, out: r.out }));
}

// N11 (two stages at once) and N12 (a stale continuation mark) are gone with the mark: the
// multi-stage receipts are feature-2729-presentation-receipt.sh R6/R13, the sweep is R10.

// N13: no anchor — the last text entry has no uuid, or the last assistant entry is not text.
{
  const s = X.sessionAt("outline");
  expectQuiet("N13a last text entry carries no uuid", X.runStop(s.sid, present(s, { noUuid: true })), s);
  const t = X.sessionAt("outline");
  expectQuiet("N13b last assistant entry is a tool_use", X.runStop(t.sid, present(t, { after: [A("a-tool", BASH("ls", "b9")), TR("b9", "u-tr2")] })), t);
}

// N14: the receipt cannot be written (a directory occupies its path) — no block.
{
  const s = X.sessionAt("outline");
  fs.mkdirSync(X.receiptPath(s.sid, "outline"), { recursive: true });
  const r = X.runStop(s.sid, present(s));
  const ok = twin("outline", "N14 receipt unwritable");
  check("N14 receipt unwritable — exit 0, no continue, stdout is only the systemMessage notice",
    ok && noticeOnly(r), show({ rc: r.rc, out: r.out }));
  check("N14 receipt unwritable — the notice names the outline stage as not recorded",
    ok && noticeIs(r, ["outline"]), show({ rc: r.rc, out: r.out }));
  check("N14 receipt unwritable — no valid receipt remains for the outline stage",
    ok && readReceipt(s.sid, "outline") === null, show({ receipt: readReceipt(s.sid, "outline") }));
}

// N18: the turn wrote the target and another session's file of the stage; only the target's link shown.
{
  const s = X.sessionAt("outline");
  const other = X.linesFor(X.uuidSid(8), "outline");
  fs.writeFileSync(other.plan, X.F.PLAN_BODY.outline);
  const r = X.runStop(s.sid, present(s, { extraMarkers: [{ stage: "outline", plan: other.plan }] }));
  const ok = twin("outline", "N18 two marker paths");
  check("N18 two marker paths for one stage — [confirm-plan] plan-link: block (other file's link not shown), no continuation, no receipt",
    ok && r.rc === 2 && r.reason.startsWith("[confirm-plan] plan-link:") && !r.reason.includes(CONT) && noReceipt(s), show({ rc: r.rc, out: r.out }));
}

// N20: the target exists but cannot be read, so computeArtifactSha is null.
{
  const s = X.sessionAt("outline");
  const r = X.runStop(s.sid, present(s), { preloads: [UNREADABLE], env: { CC_UNREADABLE: s.plan } });
  const ok = twin("outline", "N20 sha unavailable");
  check("N20 sha unavailable — exit 0, no continuation, no receipt, stdout is only the systemMessage notice",
    ok && noticeOnly(r) && !r.reason.includes(CONT) && noReceipt(s), show({ rc: r.rc, out: r.out }));
  check("N20 sha unavailable — the notice names the outline stage as not recorded",
    ok && noticeIs(r, ["outline"]), show({ rc: r.rc, out: r.out }));
}

// T6: the clock origin is moved back so no probe budget remains — planGateState is ERROR without
// a probe, and ERROR is treated as ON (#2729): the presentation still continues, fast.
{
  const s = X.sessionAt("outline");
  const r = X.runStop(s.sid, present(s), { count: true, env: { STOP_CONFIRM_CONTINUE_T0_OFFSET_MS: "3900" } });
  check("T6 deadline near — 0 probes, ERROR treated as ON: continues with the receipt", continues(r, s) && r.probes === 0, show({ rc: r.rc, out: r.out, probes: r.probes }));
  check("T6 deadline near — the hook ends well under 5 s", r.ms < 3000, `ms=${r.ms}`);
}

// runPre(s, tpath) -> {rc, json, deny, admitted}: the real PreToolUse (confirm-checkpoint) on the
// same-turn CONFIRM echo, tool_use_id "e1".
function runPre(s, tpath) {
  const { spawnSync } = require("child_process");
  const input = { session_id: s.sid, transcript_path: tpath, hook_event_name: "PreToolUse", tool_name: "Bash",
    tool_use_id: "e1", tool_input: { command: X.echoOf(s.stage) } };
  const env = Object.assign({}, process.env, X.gateEnv());
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, [path.join(X.ROOT, "hooks/confirm-checkpoint.js")], { input: JSON.stringify(input), env, encoding: "utf8", timeout: 30000, cwd: X.TDIR });
  let json = {};
  try { json = r.stdout ? JSON.parse(r.stdout) : {}; } catch (_) { json = { unparsed: r.stdout }; }
  const deny = (json.hookSpecificOutput || {}).permissionDecision === "deny";
  const admitted = !deny && r.status === 0 && json.decision !== "block" && /^\[(intent|outline|detail)\] /.test(String(json.systemMessage || ""));
  return { rc: r.status, json, deny, admitted };
}

// N21: the plan-link text and a non-echo tool call share the anchor entry. Stop -> PreToolUse on the
// same transcript: Stop neither continues nor writes a receipt, and the same-turn echo is denied.
{
  const FB = "[confirm-plan] continue: as your next message, emit only the CONFIRM echo";
  const scene = (s, anchorExtra) => {
    X.turnMarker(s.sid, s.stage, s.plan);
    return [U("write the plan", "u-prompt"), A("a-write", W(s.plan)), TR("w1", "u-tr"),
      A("a-anchor", T("Here is the plan.\n\n" + s.line), ...anchorExtra), ...(anchorExtra.length ? [TR("b9", "u-tr2")] : [])];
  };
  const echoTurn = (s, entries) => X.writeTranscript(s.sid, entries.concat([X.STOPFB(FB, "u-fb"), A("a-echo", ECHO(s.stage, "e1"))]));

  const c = X.sessionAt("outline");
  const ce = scene(c, []);
  const cs = X.runStop(c.sid, X.writeTranscript(c.sid, ce));
  const cStop = blocks(cs);
  const cRec = !noReceipt(c);
  const cp = runPre(c, echoTurn(c, ce));
  const ctl = cStop && cp.admitted;
  check("N21 control — text-only anchor: Stop continues and the same-turn echo is admitted", ctl, show({ rc: cs.rc, out: cs.out, pre: cp.json }));
  check("N21 control — the continuing Stop wrote the receipt and the admitted echo consumed it", cRec && cp.admitted && noReceipt(c), show({ cRec }));

  const s = X.sessionAt("outline");
  const se = scene(s, [BASH("ls", "b9")]);
  const r = X.runStop(s.sid, X.writeTranscript(s.sid, se));
  check("N21 text + Bash in the anchor entry — Stop: exit 0, no output, no continue reason, no receipt",
    ctl && r.rc === 0 && r.out === "" && !r.reason.includes(CONT) && noReceipt(s), show({ control: ctl, rc: r.rc, out: r.out, receipt: readReceipt(s.sid, "outline") }));
  const p = runPre(s, echoTurn(s, se));
  check("N21 text + Bash in the anchor entry — the same-turn CONFIRM echo is denied, not admitted",
    ctl && p.deny && !p.admitted, show({ control: ctl, rc: p.rc, pre: p.json }));

  // N21b (#2729): with a receipt seeded directly, the Bash-carrying anchor no longer matters — the
  // transcript shape decides nothing at the PreToolUse.
  const direct = (extra) => {
    const d = X.sessionAt("outline");
    const w = !!X.seedReceipt(d.sid, "outline");
    return Object.assign(runPre(d, echoTurn(d, scene(d, extra))), { w });
  };
  const dc = direct([]);
  check("N21b control — a seeded receipt on a text-only anchor admits the same-turn echo", dc.w && dc.admitted, show({ w: dc.w, pre: dc.json }));
  const db = direct([BASH("ls", "b9")]);
  check("N21b a seeded receipt with a Bash-carrying anchor — the echo is admitted (the shape decides nothing)",
    db.w && db.admitted, show({ w: db.w, rc: db.rc, pre: db.json }));
}
