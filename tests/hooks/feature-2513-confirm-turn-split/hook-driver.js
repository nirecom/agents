"use strict";
// Driver for ../feature-2513-confirm-turn-split.sh. Mode "sentinel" checks the parseSentinel table;
// the other modes run hooks/confirm-checkpoint.js (CC_HOOK) and print one PASS|name /
// FAIL|name|detail line per assertion. #2729: the echo reaches the dialog only through the
// presentation receipt the Stop hook wrote (seeded here); the transcript shape decides nothing,
// nothing unreadable fails open, and there is no deny cap. Every plan lives under
// WORKFLOW_PLANS_DIR; plan-sync is off except in the publish modes (publish-stub.js).
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const CE = require("../../lib/confirm-env-fixture");
const RS = require("../../lib/presentation-receipt-seed");
const SMC = require("../../lib/system-message-contract");

const out = [];
const ok = (n, c, d) => out.push(c ? "PASS|" + n : "FAIL|" + n + "|" + String(d).replace(/\n/g, "\\n").slice(0, 240));
const show = (x) => { try { return JSON.stringify(x); } catch (_) { return String(x); } };
const [mode, STAGE] = process.argv.slice(2);
const PLANS = process.env.WORKFLOW_PLANS_DIR;
const STATE = process.env.WORKFLOW_STATE_DIR;
const TDIR = process.env.CTS_TDIR;
const CFG = path.join(TDIR, "cfg");
let seq = 0;

const U = (text) => ({ type: "user", message: { role: "user", content: text } });
const UMETA = (text) => ({ type: "user", isMeta: true, message: { role: "user", content: text } });
const UCOMPACT = (text) => ({ type: "user", isCompactSummary: true, message: { role: "user", content: text } });
const A = (...content) => ({ type: "assistant", message: { role: "assistant", content } });
const T = (text) => ({ type: "text", text });
const W = (file_path) => ({ type: "tool_use", id: "w1", name: "Write", input: { file_path, content: "rewritten" } });
const ED = (file_path) => ({ type: "tool_use", id: "w1", name: "Edit", input: { file_path, old_string: "Synthetic", new_string: "Edited" } });
const ME = (file_path) => ({ type: "tool_use", id: "w1", name: "MultiEdit", input: { file_path, edits: [{ old_string: "Synthetic", new_string: "Edited" }] } });
const TR = { type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "w1", content: "ok" }] } };
const echoOf = (stage) => `echo "<<WORKFLOW_CONFIRM_${stage.toUpperCase()}: approve the ${stage} plan>>"`;

// newSession(stage) -> {sid, plan, fwd, line}: a fresh session with its plan file on disk.
function newSession(stage) {
  const sid = `2513cccc-${String(++seq).padStart(4, "0")}-4aaa-8bbb-${String(process.pid % 1e12).padStart(12, "0")}`;
  const plan = path.resolve(path.join(PLANS, `${sid}-${stage}.md`));
  fs.writeFileSync(plan, `# ${stage} plan\n\nSynthetic plan body for the turn-split tests.\n`);
  const fwd = plan.replace(/\\/g, "/");
  return { sid, plan, fwd, line: `${stage}: \`${fwd}\` (no URL: plan-sync-off)` };
}
// seed(s, stage, link) -> the receipt the Stop hook writes for a completed presentation.
const seed = (s, stage, link) => !!RS.seedReceipt(s.sid, stage || STAGE, link ? { link } : undefined);

// runHook(s, entries, opts) -> {json, raw, deny, msg}. The CONFIRM_* flags are file-only (#2726):
// opts.env's plan keys go into a per-call .env under AGENTS_MAIN_ROOT, the rest into the env.
function runHook(s, entries, opts) {
  const o = opts || {};
  let tp = o.transcriptPath;
  if (!tp) {
    tp = path.join(TDIR, `t-${s.sid}-${++seq}.jsonl`);
    fs.writeFileSync(tp, entries.map((e) => JSON.stringify(e)).join("\n") + "\n");
  }
  const input = { session_id: s.sid, transcript_path: tp, hook_event_name: "PreToolUse", cwd: TDIR,
    tool_name: "Bash", tool_input: { command: echoOf(o.stage || STAGE) } };
  const flags = { CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "on", CONFIRM_DETAIL: "on", PLAN_LANG: "english", PLAN_SYNC_REMOTE_URL: "" };
  const rest = {};
  for (const [k, v] of Object.entries(o.env || {})) (CE.PLAN_KEYS.includes(k) ? flags : rest)[k] = v;
  const env = CE.childEnvWith(CE.confirmEnvRoot(CFG, flags), Object.assign({}, process.env, rest));
  const r = spawnSync(process.execPath, [process.env.CC_HOOK], { input: JSON.stringify(input), env, encoding: "utf8", timeout: 30000 });
  const raw = r.stdout || "";
  let json = {};
  try { json = raw ? JSON.parse(raw) : {}; } catch (_) { json = { unparsed: raw }; }
  const hso = json.hookSpecificOutput || {};
  allOutputs.push(raw);
  return { json, raw, rc: r.status, deny: hso.permissionDecision === "deny", msg: json.systemMessage || "" };
}
const allOutputs = [];

// Transcripts: the previous turn presents the plan, then the user replies, then this turn's echo.
const scenes = (s) => ({
  good: [U("write the plan"), A(T("Here is the plan summary.")), A(T(s.line))],
  midOnly: [U("write the plan"), A(T(s.line), T("Done. Ready when you are."))],
  noPrompt: [U("write the plan"), A(T(s.line))],
  rewrite: [U("write the plan"), A(T("Here is the plan summary.")), A(T(s.line)), U("looks good, go ahead"), A(W(s.plan)), TR],
  rewriteEdit: [U("write the plan"), A(T("Here is the plan summary.")), A(T(s.line)), U("looks good, go ahead"), A(ED(s.plan)), TR],
  rewriteMultiEdit: [U("write the plan"), A(T("Here is the plan summary.")), A(T(s.line)), U("looks good, go ahead"), A(ME(s.plan)), TR],
  rewriteControl: [U("write the plan"), A(T("Here is the plan summary.")), A(T(s.line)), U("looks good, go ahead"), A(T("Recording the approval."))],
  metaOnly: [U("write the plan"), A(T(s.line)), UMETA("<local-command-caveat>meta</local-command-caveat>"), UCOMPACT("This session is being continued...")],
});
const withReply = (entries) => [...entries, U("looks good, go ahead")];
// findingsOf(sid) -> the confirm-checkpoint findings recorded for the session.
const findingsOf = (sid) => {
  try {
    const st = JSON.parse(fs.readFileSync(path.join(STATE, `${sid}.control`, "supervisor-state.json"), "utf8"));
    const all = (st.layer1 && Array.isArray(st.layer1.findings)) ? st.layer1.findings : [];
    return all.filter((f) => f && f.reporter === "confirm-checkpoint").length;
  } catch (_) { return 0; }
};
// separate(sid): the supervisor writer collapses a finding identical to the last one (#885), so a
// run of identical denies stores one entry. A distinct finding between two denies keeps each
// deny's own appendFinding call visible in the count.
let sepSeq = 0;
const separate = (sid) => {
  require(path.join(path.dirname(process.env.CC_HOOK), "lib", "supervisor-state-writer")).appendFinding(sid, {
    categories: ["workflow"], severity: "notice", detail: `test separator ${++sepSeq}`, reporter: "feature-2513-test",
  });
};

function expectDeny(label, r, s, stage) {
  ok(label + " — deny", r.deny, show(r.json));
  if (!r.deny) return;
  const reason = String(r.json.hookSpecificOutput.permissionDecisionReason || "") + "\n" + String(r.json.reason || "");
  ok(label + " — decision:block mirrors the deny", r.json.decision === "block", show(r.json));
  ok(label + " — reason names bin/plan-link --stage " + stage, reason.includes("bin/plan-link") && reason.includes("--stage " + stage), reason);
  ok(label + " — reason carries no URL and no plan path",
    !/https?:\/\//.test(reason) && !reason.includes(s.fwd) && !reason.includes(s.plan) && !reason.includes(s.sid), reason);
  ok(label + " — reason never invites a same-turn retry", !/retry|try again/i.test(reason), reason);
}
// A passing output is empty stdout or parseable JSON with no top-level decision:block and no deny.
function expectNoBlock(label, r) {
  const hso = r.json.hookSpecificOutput || {};
  ok(label + " — stdout parses and carries no decision:block / permissionDecision:deny",
    r.json.unparsed === undefined && r.json.decision !== "block" && hso.permissionDecision !== "deny", show([r.rc, r.raw]));
}
function expectPass(label, r) {
  // #2731: the dialog systemMessage is the stage fact line (`[<stage>] ...`), no "Click Allow" wording.
  ok(label + " — no deny, the dialog systemMessage", !r.deny && r.rc === 0 && /^\[(intent|outline|detail)\] /.test(r.msg)
    && SMC.systemMessageProblems(r.msg).length === 0, show(r.json));
  expectNoBlock(label, r);
}
// passWithReceipt(label, s, entries, opts, link): seed the receipt, then the echo reaches the dialog.
function passWithReceipt(label, s, entries, opts, link) {
  ok(label + " — precondition: the receipt was seeded", seed(s, (opts && opts.stage) || STAGE, link), "not seeded");
  expectPass(label, runHook(s, entries, opts));
}

// planFor(s, stage) -> the same session's plan for another stage, on disk.
function planFor(s, stage) {
  const plan = path.resolve(path.join(PLANS, `${s.sid}-${stage}.md`));
  fs.writeFileSync(plan, `# ${stage} plan\n\nSynthetic plan body for the turn-split tests.\n`);
  const fwd = plan.replace(/\\/g, "/");
  return { sid: s.sid, plan, fwd, line: `${stage}: \`${fwd}\` (no URL: plan-sync-off)` };
}

if (mode === "sentinel") {
  const cases = [
    { name: "bare intent sentinel", cmd: 'echo "<<WORKFLOW_CONFIRM_INTENT>>"', want: "intent" },
    { name: "intent sentinel with a reason", cmd: 'echo "<<WORKFLOW_CONFIRM_INTENT: approve intent>>"', want: "intent" },
    { name: "outline sentinel with a reason", cmd: 'echo "<<WORKFLOW_CONFIRM_OUTLINE: approve outline>>"', want: "outline" },
    { name: "detail sentinel with a reason", cmd: 'echo "<<WORKFLOW_CONFIRM_DETAIL: approve detail>>"', want: "detail" },
    { name: "detail sentinel inside a compound command", cmd: 'cd /tmp && echo "<<WORKFLOW_CONFIRM_DETAIL: in a compound>>"', want: "detail" },
    { name: "misspelled stage name", cmd: 'echo "<<WORKFLOW_CONFIRM_INTENTS: wrong name>>"', want: null },
    { name: "non-CONFIRM workflow sentinel", cmd: 'echo "<<WORKFLOW_COMPLETE_CLARIFY_INTENT>>"', want: null },
    { name: "empty command", cmd: "", want: null },
    { name: "undefined command", cmd: undefined, want: null },
  ];
  const libPath = process.env.CS_LIB;
  let lib = null;
  try { lib = require(libPath); } catch (e) { ok("hooks/lib/confirm-sentinel.js loads", false, "not implemented: " + (e.code || e.message)); }
  const cc = require(process.env.CC_HOOK);
  const sources = [["confirm-checkpoint re-export", cc]];
  if (lib) {
    ok("confirm-sentinel exports CONFIRM_STAGE_PATTERNS for the 3 stages",
      Array.isArray(lib.CONFIRM_STAGE_PATTERNS) && show(lib.CONFIRM_STAGE_PATTERNS.map((p) => p.stage)) === show(["intent", "outline", "detail"]),
      show(lib.CONFIRM_STAGE_PATTERNS));
    ok("confirm-checkpoint re-exports the lib's parseSentinel", cc.parseSentinel === lib.parseSentinel, "different functions");
    sources.push(["confirm-sentinel", lib]);
  }
  for (const [name, mod] of sources) {
    for (const { name: caseName, cmd, want } of cases) {
      let got;
      try { got = mod.parseSentinel(cmd); } catch (e) { got = { threw: e.message }; }
      const g = got && got.stage ? got.stage : got;
      ok(`${name}: ${caseName} — parseSentinel(${show(cmd)}) -> ${show(want)}`, g === want, show(got));
    }
  }
} else if (mode === "split") {
  // Each case gets its own session and its own receipt.
  const fresh = (kind, reply) => { const s = newSession(STAGE); const e = scenes(s)[kind]; return { s, e: reply ? withReply(e) : e }; };
  {
    const { s, e } = fresh("good", true);
    expectDeny(`${STAGE} P1 plan-link line ends the previous turn, no receipt — the shape alone does not pass`, runHook(s, e), s, STAGE);
    passWithReceipt(`${STAGE} P1 with the presentation receipt`, s, e);
  }
  for (const [label, kind, reply] of [
    ["D1 plan-link only in a mid text block, no receipt", "midOnly", true],
    ["D2 no user prompt between presentation and echo, no receipt", "noPrompt", false],
    ["D4 only isMeta / compact-summary entries in between, no receipt", "metaOnly", false],
  ]) {
    const { s, e } = fresh(kind, reply);
    expectDeny(`${STAGE} ${label}`, runHook(s, e), s, STAGE);
  }
  // D3: the plan changes after the receipt (content mismatch); the control keeps the plan as presented.
  const ctl = fresh("rewriteControl", false);
  const ctlSeeded = seed(ctl.s);
  const ctlR = runHook(ctl.s, ctl.e);
  ok(`${STAGE} D3 control — precondition: the receipt was seeded`, ctlSeeded, "not seeded");
  expectPass(`${STAGE} D3 control — same sequence, the plan unchanged since the receipt`, ctlR);
  for (const [tool, kind] of [["Write", "rewrite"], ["Edit", "rewriteEdit"], ["MultiEdit", "rewriteMultiEdit"]]) {
    const { s, e } = fresh(kind, false);
    seed(s);
    fs.writeFileSync(s.plan, `# ${STAGE} plan\n\nEdited by ${tool} after the presentation.\n`);
    const r = runHook(s, e);
    expectDeny(`${STAGE} D3 plan rewritten by ${tool} after the receipt`, r, s, STAGE);
    if (tool === "Write") ok(`${STAGE} D3 deny is caused by the rewrite alone`, r.deny && !ctlR.deny, show([r.deny, ctlR.deny]));
  }
  // #2729 fail-closed: nothing unreadable reaches the dialog.
  const s4 = newSession(STAGE);
  expectDeny(`${STAGE} F1 transcript unreadable, no receipt`, runHook(s4, null, { transcriptPath: path.join(TDIR, "missing.jsonl") }), s4, STAGE);
  const s4b = newSession(STAGE);
  passWithReceipt(`${STAGE} F1 transcript unreadable, with the receipt — the transcript is not read`, s4b, null, { transcriptPath: path.join(TDIR, "missing.jsonl") });
  const s5 = newSession(STAGE);
  seed(s5);
  fs.unlinkSync(s5.plan);
  expectDeny(`${STAGE} F2 plan file gone after the receipt`, runHook(s5, withReply(scenes(s5).good)), s5, STAGE);
  const s6 = newSession(STAGE);
  fs.mkdirSync(RS.receiptPath(s6.sid, STAGE), { recursive: true });
  expectDeny(`${STAGE} F3 receipt unreadable (a directory)`, runHook(s6, withReply(scenes(s6).good)), s6, STAGE);
  const s7 = newSession(STAGE);
  fs.mkdirSync(path.dirname(RS.receiptPath(s7.sid, STAGE)), { recursive: true });
  fs.writeFileSync(RS.receiptPath(s7.sid, STAGE), "{not json");
  expectDeny(`${STAGE} F3b receipt holds malformed JSON`, runHook(s7, withReply(scenes(s7).good)), s7, STAGE);
  ok(`${STAGE} F3b the broken receipt is discarded`, !RS.receiptExists(s7.sid, STAGE), "receipt left");
} else if (mode === "span") {
  // Which turn carried the link decides nothing; only the receipt does.
  const run = (lastHasLink, withSeed) => {
    const s = newSession(STAGE);
    if (withSeed) seed(s);
    const entries = [U("start"), A(T(s.line)), U("continue"), A(T(lastHasLink ? s.line : "Status update without the plan link.")), U("approve")];
    return { s, r: runHook(s, entries) };
  };
  const bad = run(false, false);
  expectDeny(`${STAGE} S1 older turn had the link, no receipt`, bad.r, bad.s, STAGE);
  const shape = run(true, false);
  expectDeny(`${STAGE} S1 the immediately preceding turn has the link, no receipt — the shape alone does not pass`, shape.r, shape.s, STAGE);
  expectPass(`${STAGE} S1 older turn had the link, with the receipt`, run(false, true).r);
} else if (mode === "multi") {
  // One session across all three stages, no receipt: every echo denies, with no cap on any stage.
  const s = newSession(STAGE);
  const per = {};
  for (const st of ["intent", "outline", "detail"]) per[st] = st === STAGE ? s : planFor(s, st);
  const echo = (st) => { const r = runHook(s, [U("write the plan"), A(T(per[st].line))], { stage: st }); separate(s.sid); return r; };
  const others = ["intent", "outline", "detail"].filter((st) => st !== STAGE);
  expectDeny(`${STAGE} M1 1st echo without a receipt`, echo(STAGE), per[STAGE], STAGE);
  expectDeny(`${STAGE} M1 2nd echo without a receipt`, echo(STAGE), per[STAGE], STAGE);
  for (const st of others) expectDeny(`${STAGE} M2 first echo on ${st} after two ${STAGE} denies`, echo(st), per[st], st);
  expectDeny(`${STAGE} M3 3rd echo without a receipt — still denied (no cap)`, echo(STAGE), per[STAGE], STAGE);
  expectDeny(`${STAGE} M4 4th echo without a receipt`, echo(STAGE), per[STAGE], STAGE);
  for (const st of others) expectDeny(`${STAGE} M5 2nd echo on ${st}`, echo(st), per[st], st);
  ok(`${STAGE} M6 a supervisor finding per deny (8 denies)`, findingsOf(s.sid) === 8,"findings=" + findingsOf(s.sid));
} else if (mode === "cap") {
  const s = newSession(STAGE);
  const bad = scenes(s).noPrompt;
  const denyOnce = () => { const r = runHook(s, bad); separate(s.sid); return r; };
  const r1 = denyOnce();
  const r2 = denyOnce();
  const r3 = denyOnce();
  const r4 = denyOnce();
  ok(`${STAGE} C1 1st echo without a receipt — deny`, r1.deny, show(r1.json));
  ok(`${STAGE} C2 2nd echo without a receipt — deny`, r2.deny, show(r2.json));
  ok(`${STAGE} C3 3rd echo without a receipt — still denied (no cap)`, r3.deny, show(r3.json));
  ok(`${STAGE} C4 4th echo without a receipt — still denied`, r4.deny, show(r4.json));
  ok(`${STAGE} C3 a supervisor finding per deny`, findingsOf(s.sid) === 4,"findings=" + findingsOf(s.sid));
  // wrong, right (receipt), wrong, wrong: the pass consumes the receipt, so the later echoes deny.
  const t = newSession(STAGE);
  const tsc = scenes(t);
  const q1 = runHook(t, tsc.noPrompt);
  const seeded = seed(t);
  const q2 = runHook(t, withReply(tsc.good));
  const q3 = runHook(t, tsc.noPrompt);
  const q4 = runHook(t, withReply(tsc.good));
  ok(`${STAGE} C5 deny, receipt pass, then deny — the pass consumed the receipt`, seeded && q1.deny && !q2.deny && q3.deny && q4.deny,
    show([seeded, q1.deny, q2.deny, q3.deny, q4.deny]));
} else if (mode === "publish") {
  // Publish on (stubbed, no network): the receipt binds the synthetic blob URL.
  const pub = { env: { NODE_OPTIONS: `--require "${process.env.CTS_PUBLISH_STUB}"`, PLAN_SYNC_REMOTE_URL: "https://example.invalid/test-owner/test-repo.git" } };
  const urlOf = (s) => "https://example.invalid/test-owner/test-repo/blob/main/" + path.basename(s.plan);
  const urlLink = (s) => ({ kind: "url", value: urlOf(s) });
  const turnWith = (text) => [U("write the plan"), A(T("Here is the plan summary.")), A(T(text)), U("looks good, go ahead")];
  const s = newSession(STAGE);
  const urlLine = `${STAGE}: ${urlOf(s)} (\`${s.fwd}\`)`;
  expectDeny(`${STAGE} B1 publish on — URL line ends the previous turn, no receipt`, runHook(s, turnWith(urlLine), pub), s, STAGE);
  ok(`${STAGE} B1 precondition — the URL receipt was seeded`, seed(s, STAGE, urlLink(s)), "not seeded");
  const rp = runHook(s, turnWith(urlLine), pub);
  ok(`${STAGE} B0 the stub publishes (systemMessage shows the example.invalid URL)`, rp.msg.includes(urlOf(s)), rp.msg);
  expectPass(`${STAGE} B1 publish on — with the URL receipt`, rp);
  const d = newSession(STAGE);
  seed(d, STAGE, { kind: "path", value: d.plan });
  const localLine = `${STAGE}: \`${d.fwd}\` (no URL: not-published)`;
  expectDeny(`${STAGE} B2 publish on — only a path receipt (unpublished presentation)`, runHook(d, turnWith(localLine), pub), d, STAGE);
  const inSpan = newSession(STAGE);
  expectDeny(`${STAGE} B3 publish on — URL only inside an inline code span, no receipt`, runHook(inSpan, turnWith("Plan: `See " + urlOf(inSpan) + "`"), pub), inSpan, STAGE);
  const bare = newSession(STAGE);
  passWithReceipt(`${STAGE} B4 publish on — bare URL with the URL receipt`, bare, turnWith("Plan: See " + urlOf(bare)), pub, urlLink(bare));
} else if (mode === "fence") {
  // Whether the link sat in a fence is the Stop hook's call (it writes no receipt); here only the receipt decides.
  const mk = (lines) => { const s = newSession(STAGE); return { s, e: withReply([U("write the plan"), A(T("Here is the plan summary.")), A(T(lines(s)))]) }; };
  for (const [label, lines] of [
    ["F1 link only inside a ``` fence", (s) => "Plan:\n```\n" + s.line + "\n```"],
    ["F2 link only inside a ~~~ fence", (s) => "Plan:\n~~~\n" + s.line + "\n~~~"],
    ["F3 link inside an unclosed fence", (s) => "Plan:\n```\n" + s.line],
  ]) {
    const { s, e } = mk(lines);
    expectDeny(`${STAGE} ${label}, no receipt`, runHook(s, e), s, STAGE);
  }
  const f4 = mk((s) => s.line + "\n```\n" + s.line + "\n```");
  expectDeny(`${STAGE} F4 link outside a fence plus a fenced copy, no receipt — the shape alone does not pass`, runHook(f4.s, f4.e), f4.s, STAGE);
  passWithReceipt(`${STAGE} F4 the same, with the receipt`, f4.s, f4.e);
  const f5 = mk((s) => "Plan: `" + s.fwd + "` (no URL: plan-sync-off)");
  passWithReceipt(`${STAGE} F5 inline-code path, with the receipt`, f5.s, f5.e);
  const pub = { env: { NODE_OPTIONS: `--require "${process.env.CTS_PUBLISH_STUB}"`, PLAN_SYNC_REMOTE_URL: "https://example.invalid/test-owner/test-repo.git" } };
  const urlOf = (s) => `https://example.invalid/test-owner/test-repo/blob/main/${path.basename(s.plan)}`;
  const urlLineOf = (s) => `${STAGE}: ${urlOf(s)} (\`${s.fwd}\`)`;
  for (const [label, lines] of [
    ["FP1 publish on — URL line only inside a ``` fence", (s) => "Plan:\n```\n" + urlLineOf(s) + "\n```"],
    ["FP2 publish on — URL line only inside a ~~~ fence", (s) => "Plan:\n~~~\n" + urlLineOf(s) + "\n~~~"],
  ]) {
    const { s, e } = mk(lines);
    expectDeny(`${STAGE} ${label}, no receipt`, runHook(s, e, pub), s, STAGE);
  }
  const fp3 = mk((s) => urlLineOf(s) + "\n```\n" + urlLineOf(s) + "\n```");
  passWithReceipt(`${STAGE} FP3 publish on — URL line outside a fence plus a fenced copy, with the URL receipt`, fp3.s, fp3.e, pub, { kind: "url", value: urlOf(fp3.s) });
} else if (mode === "write") {
  const mk = (tool) => {
    const s = newSession(STAGE);
    const base = path.basename(s.plan);
    return { s, e: [U("write the plan"), A(T("Here is the plan summary.")), A(T(s.line)), U("looks good, go ahead"), A(tool(s, base)), TR] };
  };
  const bash = (command) => ({ type: "tool_use", id: "w1", name: "Bash", input: { command } });
  const other = STAGE === "intent" ? "outline" : "intent";
  const denies = (label, tool) => { const { s, e } = mk(tool); expectDeny(`${STAGE} ${label}, no receipt`, runHook(s, e), s, STAGE); };
  denies("W1 Bash writes the artifact basename", (s, b) => bash(`printf x > "${PLANS}/${b}"`));
  denies("W2 mixed-case basename", (s, b) => bash(`printf x > "${PLANS}/${b.toUpperCase()}"`));
  denies("W3 Windows backslash path", (s, b) => bash(`copy nul "${PLANS.replace(/\//g, "\\")}\\${b}"`));
  const w4 = mk((s) => ({ type: "tool_use", id: "w1", name: "Read", input: { file_path: s.plan } }));
  passWithReceipt(`${STAGE} W4 Read tool_use on the artifact, with the receipt`, w4.s, w4.e);
  const w5 = mk((s) => bash(`printf x > "${PLANS}/${s.sid}-${other}.md"`));
  passWithReceipt(`${STAGE} W5 Bash touching a different stage's artifact, with the receipt`, w5.s, w5.e);
  const w6 = mk(() => bash(echoOf(STAGE)));
  expectDeny(`${STAGE} W6 the CONFIRM echo itself, no receipt — the shape alone does not pass`, runHook(w6.s, w6.e), w6.s, STAGE);
  passWithReceipt(`${STAGE} W6 the CONFIRM echo itself, with the receipt`, w6.s, w6.e);
} else if (mode === "env") {
  const s = newSession("intent");
  const r = runHook(s, scenes(s).noPrompt, { stage: "intent", env: { CONFIRM_INTENT: "off" } });
  ok("E1 CONFIRM_INTENT=off — intent is still judged (deny without a receipt)", r.deny, show(r.json));
  ok("E1 CONFIRM_INTENT=off — no confirm-skipped message", !String(r.msg).includes("[confirm-skipped"), r.msg);
  for (const st of ["outline", "detail"]) {
    const so = newSession(st);
    const flag = "CONFIRM_" + st.toUpperCase();
    const ro = runHook(so, scenes(so).noPrompt, { stage: st, env: { [flag]: "off" } });
    ok(`E2 ${flag}=off — still skipped, no deny`, !ro.deny && ro.msg === `[confirm-skipped: ${flag}=off]`, show(ro.json));
  }
}
if (mode !== "sentinel") {
  ok(`${mode} ${STAGE || ""} — no output carries permissionDecision allow`.replace(/\s+—/, " —"),
    allOutputs.every((raw) => !/"permissionDecision"\s*:\s*"allow"/.test(raw)), allOutputs.join(" / "));
}
process.stdout.write(out.join("\n") + "\n");
