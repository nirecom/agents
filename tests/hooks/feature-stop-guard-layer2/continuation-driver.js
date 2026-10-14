"use strict";
// #2650 Stop-hook continuation branch (N1-N21, T6), driven by ./continuation.sh. A presentation
// turn that wrote a plan, ends on its plan-link line and has no approval while the gate is ON
// gets decision:block "[confirm-plan] continue:" and a continuation mark anchored to the last
// text entry. Every "no continuation" case runs its continuing twin first, so a case can only
// pass when the branch exists and the case's own condition is what stops it.
// Prints PASS|name / FAIL|name|detail lines.
const fs = require("fs");
const path = require("path");
const X = require("../feature-2650-confirm-continuation/fixture");

const { A, T, U, W, TR, ECHO, BASH, show, check } = X;
const CONT = "[confirm-plan] continue:";
const UNREADABLE = path.join(__dirname, "..", "feature-2650-confirm-continuation", "unreadable-preload.js");

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

function continues(r, s) {
  const m = X.readMark(s.sid, s.stage);
  return r.rc === 2 && r.json.decision === "block" && r.reason.startsWith(CONT) && !!m && m.anchorUuid === "a-anchor";
}
const quiet = (r, s) => r.rc === 0 && r.out === "" && !fs.existsSync(X.markPath(s.sid, s.stage));
const noMark = (s) => !fs.existsSync(X.markPath(s.sid, s.stage));

function expectContinue(label, r, s) {
  check(`${label} — decision:block, exit 2, "${CONT}" reason, mark anchored to the last text entry`, continues(r, s),
    show({ rc: r.rc, out: r.out, mark: X.readMark(s.sid, s.stage) }));
}
// twin(stage, label) -> the continuing control for a "no continuation" case.
function twin(stage, label) {
  const s = X.sessionAt(stage);
  const r = X.runStop(s.sid, present(s));
  check(`${label} — control: the same scene without the case's condition continues`, continues(r, s), show({ rc: r.rc, out: r.out }));
  return continues(r, s);
}
function expectQuiet(label, r, s, stage) {
  const ok = twin(stage || s.stage, label);
  check(`${label} — exit 0, no output, no mark`, ok && quiet(r, s), show({ control: ok, rc: r.rc, out: r.out, mark: X.readMark(s.sid, s.stage) }));
}

// Preconditions: the two preloads take effect (else N11 / T6 / N20 could pass vacuously).
{
  const { spawnSync } = require("child_process");
  const s = X.sessionAt("outline");
  const log = path.join(X.TDIR, `pre-${s.sid}.log`);
  const env = Object.assign({}, process.env, { CC_SPAWN_LOG: log, CC_UNREADABLE: s.plan,
    NODE_OPTIONS: [X.SPAWN_PRELOAD, UNREADABLE].map((p) => `--require "${p.replace(/\\/g, "/")}"`).join(" ") });
  const code = `const p=require(${JSON.stringify(path.join(X.ROOT, "hooks/lib/confirm-gate/probe.js"))});` +
    `p.probeConfirmGateSync("CONFIRM_OUTLINE",5000);` +
    `const c=require(${JSON.stringify(path.join(X.ROOT, "hooks/workflow-state/completion-approval.js"))});` +
    `process.stdout.write(String(c.computeArtifactSha(${JSON.stringify(s.sid)},"outline")));`;
  const r = spawnSync(process.execPath, ["-e", code], { env, encoding: "utf8", timeout: 30000 });
  let n = 0;
  try { n = fs.readFileSync(log, "utf8").split("\n").filter(Boolean).length; } catch (_) { n = 0; }
  check("precondition — the spawn-count preload logs one confirm-off probe", n === 1, `n=${n} err=${r.stderr}`);
  check("precondition — the unreadable preload makes computeArtifactSha null", r.stdout === "null" && !!X.F.implSha(s.sid, "outline"), show([r.stdout, r.stderr]));
}

const reasons = [];
for (const stage of X.STAGES) {
  // N1 / N15 / N19: the continuation and the mark's binding, per stage.
  const s = X.sessionAt(stage);
  const r = X.runStop(s.sid, present(s));
  expectContinue(`N1 ${stage} wrote the plan, ends on its link, unapproved, gate ON`, r, s);
  reasons.push([stage, s, r.reason]);
  const CC = X.tryRequire("hooks/lib/confirm-continuation.js");
  const m = X.readMark(s.sid, stage);
  if (CC.__missing || !m) {
    check(`N19 ${stage} mark binds the approval target`, false, CC.__missing ? "confirm-continuation.js: " + CC.__missing : "no mark");
  } else {
    const target = CC.approvalArtifactPath(s.sid, stage);
    const same = (a, b) => path.resolve(String(a)).toLowerCase() === path.resolve(String(b)).toLowerCase();
    check(`N19 ${stage} mark.absPath is approvalArtifactPath(sid, stage)`, typeof m.absPath === "string" && same(m.absPath, target), show([m.absPath, target]));
    check(`N19 ${stage} mark.link is linkKey of the shown link (the local path)`, m.link === CC.linkKey({ path: s.plan }), show([m.link, s.plan]));
    check(`N19 ${stage} mark.artifactSha is computeArtifactSha(sid, step)`, !!m.artifactSha && m.artifactSha === X.F.implSha(s.sid, s.step), show([m.artifactSha, X.F.implSha(s.sid, s.step)]));
    check(`N19 ${stage} mark carries session_id and stage`, m.session_id === s.sid && m.stage === stage, show(m));
  }

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
  const CC = X.tryRequire("hooks/lib/confirm-continuation.js");
  const m = X.readMark(s.sid, "outline");
  check("N19 outline published — mark.link is the URL (linkKey prefers url)",
    !CC.__missing && !!m && m.link === CC.linkKey({ url: s.url, path: s.plan }) && m.link === s.url, show([m, CC.__missing]));
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

// N3: the stage's echo is in the turn: Layer 2's follow-up check runs, no continuation, no mark.
{
  const s = X.sessionAt("outline");
  X.turnMarker(s.sid, "outline", s.plan);
  const tp = X.writeTranscript(s.sid, [U("write the plan", "u-prompt"), A("a-write", W(s.plan)), TR("w1", "u-tr"),
    A("a-anchor", T("Here is the plan.\n\n" + s.line), ECHO("outline"))]);
  const r = X.runStop(s.sid, tp);
  const ok = twin("outline", "N3 echo in the turn");
  check("N3 echo in the turn — Layer 2 follow-up block, not the continuation, no mark",
    ok && r.rc === 2 && r.reason.startsWith("[confirm-plan] Layer 2/follow-up") && noMark(s), show({ rc: r.rc, out: r.out }));
}

// N5 / N10: an OFF gate (outline, and detail's present-and-stop path) ends normally.
for (const [label, stage, key] of [["N5 CONFIRM_OUTLINE=off", "outline", "CONFIRM_OUTLINE"], ["N10 CONFIRM_DETAIL=off (present-and-stop path)", "detail", "CONFIRM_DETAIL"]]) {
  const s = X.sessionAt(stage);
  expectQuiet(label, X.runStop(s.sid, present(s), { env: { [key]: "off" } }), s);
}

// N6: intent is not off-waivable, so CONFIRM_INTENT=off still continues.
{ const s = X.sessionAt("intent"); expectContinue("N6 CONFIRM_INTENT=off on intent", X.runStop(s.sid, present(s), { env: { CONFIRM_INTENT: "off" } }), s); }

// N7: stop_hook_active — nothing happens, an existing mark is left in place.
{
  const s = X.sessionAt("outline");
  const mp = X.markPath(s.sid, "outline");
  fs.mkdirSync(path.dirname(mp), { recursive: true });
  fs.writeFileSync(mp, '{"seeded":true}');
  const r = X.runStop(s.sid, present(s), { input: { stop_hook_active: true } });
  const ok = twin("outline", "N7 stop_hook_active");
  check("N7 stop_hook_active — exit 0, no output, the existing mark is untouched",
    ok && r.rc === 0 && r.out === "" && fs.existsSync(mp) && fs.readFileSync(mp, "utf8") === '{"seeded":true}', show({ rc: r.rc, out: r.out }));
}

// N8: the plan was written but the last text does not show the link — the plan-link block wins.
{
  const s = X.sessionAt("outline");
  const r = X.runStop(s.sid, present(s, { text: "The plan is ready." }));
  const ok = twin("outline", "N8 link missing");
  check("N8 link missing — [confirm-plan] plan-link: block, no mark", ok && r.rc === 2 && r.reason.startsWith("[confirm-plan] plan-link:") && noMark(s), show({ rc: r.rc, out: r.out }));
}

// N9: the plan violates PLAN_LANG=japanese (English-only body) — the plan-lang block, no mark.
{
  const s = X.sessionAt("outline", { body: "# Outline\n\n## Approach\n\nThis plan body is written entirely in English words.\n\n## Issues\n\n- #1 fixture\n" });
  const r = X.runStop(s.sid, present(s), { env: { PLAN_LANG: "japanese" } });
  check("N9 relint violation — a plan-lang block, not the continuation, no mark",
    r.rc === 2 && /plan-lang/.test(r.reason) && !r.reason.startsWith(CONT) && noMark(s), show({ rc: r.rc, out: r.out }));
}

// N11: two stages qualify at once — no continuation and the gate probe is never spawned.
{
  const s = X.sessionAt("intent");
  const o = X.linesFor(s.sid, "outline");
  fs.writeFileSync(o.plan, X.F.PLAN_BODY.outline);
  X.turnMarker(s.sid, "outline", o.plan);
  const r = X.runStop(s.sid, present(s, { text: s.line + "\n" + o.line }), { count: true });
  const ok = twin("intent", "N11 two stages");
  check("N11 two stages qualify — exit 0, no output, no mark for either stage, 0 probe spawns",
    ok && quiet(r, s) && !fs.existsSync(X.markPath(s.sid, "outline")) && r.spawns === 0, show({ rc: r.rc, out: r.out, spawns: r.spawns }));
}

// N12: a stale mark from an earlier turn is swept by a Stop that does not continue.
{
  const s = X.sessionAt("outline");
  const mp = X.markPath(s.sid, "outline");
  fs.mkdirSync(path.dirname(mp), { recursive: true });
  fs.writeFileSync(mp, '{"stale":true}');
  const r = X.runStop(s.sid, X.writeTranscript(s.sid, [U("thanks", "u-prompt"), A("a-anchor", T("You're welcome."))]));
  check("N12 stale mark swept — exit 0, mark removed", r.rc === 0 && !fs.existsSync(mp), show({ rc: r.rc, out: r.out, left: fs.existsSync(mp) }));
}

// N13: no anchor — the last text entry has no uuid, or the last assistant entry is not text.
{
  const s = X.sessionAt("outline");
  expectQuiet("N13a last text entry carries no uuid", X.runStop(s.sid, present(s, { noUuid: true })), s);
  const t = X.sessionAt("outline");
  expectQuiet("N13b last assistant entry is a tool_use", X.runStop(t.sid, present(t, { after: [A("a-tool", BASH("ls", "b9")), TR("b9", "u-tr2")] })), t);
}

// N14: the mark cannot be written (a directory occupies its path) — no block.
{
  const s = X.sessionAt("outline");
  fs.mkdirSync(X.markPath(s.sid, "outline"), { recursive: true });
  const r = X.runStop(s.sid, present(s));
  const ok = twin("outline", "N14 mark unwritable");
  check("N14 mark unwritable — exit 0, no output", ok && r.rc === 0 && r.out === "", show({ rc: r.rc, out: r.out }));
}

// N18: the turn wrote the target and another session's file of the stage; only the target's link shown.
{
  const s = X.sessionAt("outline");
  const other = X.linesFor(X.uuidSid(8), "outline");
  fs.writeFileSync(other.plan, X.F.PLAN_BODY.outline);
  const r = X.runStop(s.sid, present(s, { extraMarkers: [{ stage: "outline", plan: other.plan }] }));
  const ok = twin("outline", "N18 two marker paths");
  check("N18 two marker paths for one stage — [confirm-plan] plan-link: block (other file's link not shown), no continuation, no mark",
    ok && r.rc === 2 && r.reason.startsWith("[confirm-plan] plan-link:") && !r.reason.startsWith(CONT) && noMark(s), show({ rc: r.rc, out: r.out }));
}

// N20: the target exists but cannot be read, so computeArtifactSha is null.
{
  const s = X.sessionAt("outline");
  const r = X.runStop(s.sid, present(s), { preloads: [UNREADABLE], env: { CC_UNREADABLE: s.plan } });
  const ok = twin("outline", "N20 sha unavailable");
  check("N20 sha unavailable — exit 0, no output, no continuation, no mark",
    ok && r.rc === 0 && r.out === "" && !r.reason.startsWith(CONT) && noMark(s), show({ rc: r.rc, out: r.out }));
}

// T6: the clock origin is moved back so less than MIN_PROBE_MS remains — no probe, ends fast.
{
  const s = X.sessionAt("outline");
  const r = X.runStop(s.sid, present(s), { count: true, env: { STOP_CONFIRM_CONTINUE_T0_OFFSET_MS: "3900" } });
  const ok = twin("outline", "T6 deadline");
  check("T6 deadline near — exit 0, no output, no mark, 0 probe spawns", ok && quiet(r, s) && r.spawns === 0, show({ rc: r.rc, out: r.out, spawns: r.spawns }));
  check("T6 deadline near — the hook ends well under 5 s", ok && r.ms < 3000, `ms=${r.ms}`);
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
  const admitted = !deny && r.status === 0 && json.decision !== "block" && String(json.systemMessage || "").includes("Click Allow");
  return { rc: r.status, json, deny, admitted };
}

// N21: the plan-link text and a non-echo tool call share the anchor entry. Stop -> PreToolUse on the
// same transcript: Stop neither continues nor writes a mark, and the same-turn echo is denied.
{
  const FB = "[confirm-plan] continue: as your next message, emit only the CONFIRM echo";
  const scene = (s, anchorExtra) => {
    X.turnMarker(s.sid, s.stage, s.plan);
    return [U("write the plan", "u-prompt"), A("a-write", W(s.plan)), TR("w1", "u-tr"),
      A("a-anchor", T("Here is the plan.\n\n" + s.line), ...anchorExtra), ...(anchorExtra.length ? [TR("b9", "u-tr2")] : [])];
  };
  const echoTurn = (s, entries) => X.writeTranscript(s.sid, entries.concat([X.STOPFB(FB, "u-fb"), A("a-echo", ECHO(s.stage, "e1"))]));

  // Control: the anchor entry carries only the text — Stop continues and the same-turn echo is admitted.
  const c = X.sessionAt("outline");
  const ce = scene(c, []);
  const cs = X.runStop(c.sid, X.writeTranscript(c.sid, ce));
  const cStop = continues(cs, c);
  const cp = runPre(c, echoTurn(c, ce));
  const ctl = cStop && cp.admitted;
  check("N21 control — text-only anchor: Stop continues and the same-turn echo is admitted", ctl, show({ rc: cs.rc, out: cs.out, pre: cp.json }));

  const s = X.sessionAt("outline");
  const se = scene(s, [BASH("ls", "b9")]);
  const r = X.runStop(s.sid, X.writeTranscript(s.sid, se));
  const m = X.readMark(s.sid, "outline");
  check("N21 text + Bash in the anchor entry — Stop: exit 0, no output, no continue reason, no mark",
    ctl && r.rc === 0 && r.out === "" && !r.reason.startsWith(CONT) && !m, show({ control: ctl, rc: r.rc, out: r.out, mark: m }));
  const p = runPre(s, echoTurn(s, se));
  check("N21 text + Bash in the anchor entry — the same-turn CONFIRM echo is denied, not admitted",
    ctl && p.deny && !p.admitted, show({ control: ctl, rc: p.rc, pre: p.json }));
  check("N21 text + Bash in the anchor entry — no continuation mark is left after the PreToolUse", !fs.existsSync(X.markPath(s.sid, "outline")), "mark left");

  // N21b: a valid mark on a-anchor written directly (the Stop fix would hide this side), so only
  // sameTurnContinuation stands between the Bash-carrying anchor and the dialog. Twin: text-only anchor.
  const CC = X.tryRequire("hooks/lib/confirm-continuation.js");
  const PL = require(path.join(X.ROOT, "hooks/lib/plan-link"));
  const TM = require(path.join(X.ROOT, "hooks/lib/turn-marker"));
  const { computeArtifactSha } = require(path.join(X.ROOT, "hooks/workflow-state/completion-approval"));
  const direct = (extra) => {
    const d = X.sessionAt("outline");
    const absPath = CC.__missing ? null : CC.approvalArtifactPath(d.sid, "outline");
    const w = !!absPath && TM.writeContinuationMark(d.sid, "outline", { anchorUuid: "a-anchor", absPath,
      link: CC.linkKey(PL.linkForFile(absPath, { plansDir: X.F.PLANS_DIR })), artifactSha: computeArtifactSha(d.sid, d.step) }) === true;
    return Object.assign(runPre(d, echoTurn(d, scene(d, extra))), { w });
  };
  const dc = direct([]);
  check("N21b control — a directly written mark on a text-only anchor admits the same-turn echo", dc.w && dc.admitted, show({ w: dc.w, pre: dc.json }));
  const db = direct([BASH("ls", "b9")]);
  check("N21b a directly written valid mark on a Bash-carrying anchor — the same-turn echo is still denied",
    dc.w && dc.admitted && db.w && db.deny && !db.admitted, show({ control: dc.admitted, w: db.w, rc: db.rc, pre: db.json }));
}
