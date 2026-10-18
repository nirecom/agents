"use strict";
// Driver for ../feature-2513-confirm-turn-split.sh. Mode "sentinel" checks the parseSentinel table;
// mode "split <stage>" and "cap <stage>" run hooks/confirm-checkpoint.js (CC_HOOK) on hand-built
// transcripts and print one PASS|name / FAIL|name|detail line per assertion. Every plan lives
// under WORKFLOW_PLANS_DIR and every session id is synthetic; plan-sync is off, so the plan-link
// line is the backticked local path — except mode "publish", where publish-stub.js fakes a blob URL.
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const out = [];
const ok = (n, c, d) => out.push(c ? "PASS|" + n : "FAIL|" + n + "|" + String(d).replace(/\n/g, "\\n").slice(0, 240));
const show = (x) => { try { return JSON.stringify(x); } catch (_) { return String(x); } };
const [mode, STAGE] = process.argv.slice(2);
const PLANS = process.env.WORKFLOW_PLANS_DIR;
const STATE = process.env.WORKFLOW_STATE_DIR;
const TDIR = process.env.CTS_TDIR;
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

// runHook(s, entries, opts) -> {json, raw, deny, msg}. opts.env overrides the pinned CONFIRM_* values.
function runHook(s, entries, opts) {
  const o = opts || {};
  let tp = o.transcriptPath;
  if (!tp) {
    tp = path.join(TDIR, `t-${s.sid}-${++seq}.jsonl`);
    fs.writeFileSync(tp, entries.map((e) => JSON.stringify(e)).join("\n") + "\n");
  }
  const input = { session_id: s.sid, transcript_path: tp, hook_event_name: "PreToolUse", cwd: TDIR,
    tool_name: "Bash", tool_input: { command: echoOf(o.stage || STAGE) } };
  const env = { ...process.env, CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "on", CONFIRM_DETAIL: "on", ...(o.env || {}) };
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
const scenes = (s, stage) => ({
  good: [U("write the plan"), A(T("Here is the plan summary.")), A(T(s.line))],
  midOnly: [U("write the plan"), A(T(s.line), T("Done. Ready when you are."))],
  noPrompt: [U("write the plan"), A(T(s.line))],
  // A correct presentation turn and a real reply; the ONLY defect is this turn's Write to the plan.
  rewrite: [U("write the plan"), A(T("Here is the plan summary.")), A(T(s.line)), U("looks good, go ahead"), A(W(s.plan)), TR],
  rewriteEdit: [U("write the plan"), A(T("Here is the plan summary.")), A(T(s.line)), U("looks good, go ahead"), A(ED(s.plan)), TR],
  rewriteMultiEdit: [U("write the plan"), A(T("Here is the plan summary.")), A(T(s.line)), U("looks good, go ahead"), A(ME(s.plan)), TR],
  rewriteControl: [U("write the plan"), A(T("Here is the plan summary.")), A(T(s.line)), U("looks good, go ahead"), A(T("Recording the approval."))],
  metaOnly: [U("write the plan"), A(T(s.line)), UMETA("<local-command-caveat>meta</local-command-caveat>"), UCOMPACT("This session is being continued...")],
});
const withReply = (entries) => [...entries, U("looks good, go ahead")];
const findingsOf = (sid) => {
  try {
    const st = JSON.parse(fs.readFileSync(path.join(STATE, `${sid}.control`, "supervisor-state.json"), "utf8"));
    return (st.layer1 && Array.isArray(st.layer1.findings)) ? st.layer1.findings.length : 0;
  } catch (_) { return 0; }
};

function expectDeny(label, r, s, stage) {
  ok(label + " — deny", r.deny, show(r.json));
  if (!r.deny) return;
  const reason = String(r.json.hookSpecificOutput.permissionDecisionReason || "") + "\n" + String(r.json.reason || "");
  ok(label + " — decision:block mirrors the deny", r.json.decision === "block", show(r.json));
  ok(label + " — reason names the stage and bin/plan-link", reason.includes(stage) && reason.includes("bin/plan-link"), reason);
  ok(label + " — reason carries no URL and no plan path",
    !/https?:\/\//.test(reason) && !reason.includes(s.fwd) && !reason.includes(s.plan) && !reason.includes(s.sid), reason);
  // #2650: the deny ends the turn; it never invites a same-turn retry.
  ok(label + " — reason says not to echo again in this turn", reason.includes("Do not echo it again in this turn"), reason);
  ok(label + " — reason never invites a same-turn retry", !/retry|try again/i.test(reason), reason);
}
// A passing output is empty stdout or parseable JSON with no top-level decision:block and no deny.
function expectNoBlock(label, r) {
  const hso = r.json.hookSpecificOutput || {};
  ok(label + " — stdout parses and carries no decision:block / permissionDecision:deny",
    r.json.unparsed === undefined && r.json.decision !== "block" && hso.permissionDecision !== "deny", show([r.rc, r.raw]));
}
function expectPass(label, r) {
  ok(label + " — no deny, today's systemMessage", !r.deny && r.rc === 0 && r.msg.includes("Click Allow"), show(r.json));
  expectNoBlock(label, r);
}

// A fail-open pass: exit 0, today's dialog message, and no deny/block JSON at all.
function expectFailOpen(label, r) {
  const hso = r.json.hookSpecificOutput || {};
  ok(label + " — fail-open: exit 0, dialog systemMessage, no deny/decision fields",
    r.rc === 0 && !r.deny && r.json.decision === undefined && hso.permissionDecision === undefined && r.msg.includes("Click Allow"), show([r.rc, r.raw]));
  expectNoBlock(label, r);
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
  // Each case gets its own session, so no case inherits another's deny count.
  const fresh = (kind, reply) => {
    const s = newSession(STAGE);
    const entries = scenes(s, STAGE)[kind];
    return { s, r: runHook(s, reply ? withReply(entries) : entries) };
  };
  expectPass(`${STAGE} P1 plan-link line ends the previous turn`, fresh("good", true).r);
  for (const [label, kind, reply] of [
    ["D1 plan-link only in a mid text block", "midOnly", true],
    ["D2 no user prompt between presentation and echo", "noPrompt", false],
    ["D4 only isMeta / compact-summary entries in between", "metaOnly", false],
  ]) {
    const { s, r } = fresh(kind, reply);
    expectDeny(`${STAGE} ${label}`, r, s, STAGE);
  }
  // D3 isolates the rewrite: the control is the same transcript minus the Write and must pass,
  // so a D3 deny can only come from the rewrite rule.
  const ctl = fresh("rewriteControl", false);
  expectPass(`${STAGE} D3 control — same sequence without the rewrite`, ctl.r);
  const rw = fresh("rewrite", false);
  expectDeny(`${STAGE} D3 plan rewritten in this turn after a correct presentation and reply`, rw.r, rw.s, STAGE);
  ok(`${STAGE} D3 deny is caused by the rewrite alone`, rw.r.deny && !ctl.r.deny, show([rw.r.deny, ctl.r.deny]));
  // The rewrite rule covers every file-write tool of the class, not only Write.
  for (const [tool, kind] of [["Edit", "rewriteEdit"], ["MultiEdit", "rewriteMultiEdit"]]) {
    const re = fresh(kind, false);
    expectDeny(`${STAGE} D3 plan rewritten by ${tool} in this turn`, re.r, re.s, STAGE);
  }
  // Fail-open: an unreadable transcript, an unresolvable plan link, an unreadable deny counter.
  const s4 = newSession(STAGE);
  expectFailOpen(`${STAGE} F1 transcript unreadable`, runHook(s4, null, { transcriptPath: path.join(TDIR, "missing.jsonl") }));
  const s5 = newSession(STAGE);
  fs.unlinkSync(s5.plan);
  expectFailOpen(`${STAGE} F2 plan link unresolvable`, runHook(s5, scenes(s5, STAGE).noPrompt));
  const s6 = newSession(STAGE);
  fs.mkdirSync(path.join(STATE, `${s6.sid}.control`, `confirm-link-deny-${STAGE}.json`), { recursive: true });
  expectFailOpen(`${STAGE} F3 deny counter unreadable`, runHook(s6, scenes(s6, STAGE).noPrompt));
  const s7 = newSession(STAGE);
  const ctl7 = path.join(STATE, `${s7.sid}.control`);
  fs.mkdirSync(ctl7, { recursive: true });
  fs.writeFileSync(path.join(ctl7, `confirm-link-deny-${STAGE}.json`), "{not json");
  expectFailOpen(`${STAGE} F3b deny counter holds malformed JSON`, runHook(s7, scenes(s7, STAGE).noPrompt));
} else if (mode === "span") {
  // The previous turn is the one immediately before the CONFIRM turn, not an older turn that had the link.
  const run = (lastHasLink) => {
    const s = newSession(STAGE);
    const entries = [U("start"), A(T(s.line)), U("continue"), A(T(lastHasLink ? s.line : "Status update without the plan link.")), U("approve")];
    return { s, r: runHook(s, entries) };
  };
  const bad = run(false);
  expectDeny(`${STAGE} S1 older turn had the link, the immediately preceding turn lacks it`, bad.r, bad.s, STAGE);
  expectPass(`${STAGE} S1 control — the immediately preceding turn has the link`, run(true).r);
} else if (mode === "multi") {
  // One session across all three stages: the deny cap is per (session, stage).
  const s = newSession(STAGE);
  const per = {};
  for (const st of ["intent", "outline", "detail"]) per[st] = st === STAGE ? s : planFor(s, st);
  const echo = (st) => runHook(s, [U("write the plan"), A(T(per[st].line))], { stage: st });
  const others = ["intent", "outline", "detail"].filter((st) => st !== STAGE);
  expectDeny(`${STAGE} M1 1st bad echo`, echo(STAGE), per[STAGE], STAGE);
  expectDeny(`${STAGE} M1 2nd bad echo`, echo(STAGE), per[STAGE], STAGE);
  for (const st of others) expectDeny(`${STAGE} M2 first bad echo on ${st} after ${STAGE} exhausted its denies`, echo(st), per[st], st);
  const cap = echo(STAGE);
  ok(`${STAGE} M3 3rd bad echo passes fail-open at the cap`, !cap.deny && cap.rc === 0 && cap.msg.includes("deny cap"), show(cap.json));
  expectDeny(`${STAGE} M4 counter reset after the capped pass`, echo(STAGE), per[STAGE], STAGE);
  for (const st of others) expectDeny(`${STAGE} M5 ${st} counter independent of ${STAGE}'s cap (2nd bad echo)`, echo(st), per[st], st);
} else if (mode === "cap") {
  const s = newSession(STAGE);
  const bad = scenes(s, STAGE).noPrompt;
  const r1 = runHook(s, bad);
  const r2 = runHook(s, bad);
  const r3 = runHook(s, bad);
  ok(`${STAGE} C1 1st wrong echo — deny`, r1.deny, show(r1.json));
  ok(`${STAGE} C2 2nd wrong echo — deny`, r2.deny, show(r2.json));
  ok(`${STAGE} C3 3rd wrong echo — passes at the cap`, r1.deny && r2.deny && !r3.deny && r3.rc === 0, show(r3.json));
  const g = newSession(STAGE);
  const plainMsg = runHook(g, withReply(scenes(g, STAGE).good)).msg.replace(g.plan, "<plan>");
  ok(`${STAGE} C3 cap pass — systemMessage reports the cap (not the plain dialog text)`,
    r1.deny && r3.msg.length > 0 && r3.msg.replace(s.plan, "<plan>") !== plainMsg, r3.msg);
  ok(`${STAGE} C3 cap pass — a supervisor finding is appended`, findingsOf(s.sid) >= 1, "findings=" + findingsOf(s.sid));
  const r4 = runHook(s, bad);
  ok(`${STAGE} C4 counter reset after the capped pass — next wrong echo denies again`, r3.deny === false && r4.deny, show(r4.json));
  // A correct echo resets a running count: wrong, right, wrong, wrong -> the 4th is still a deny.
  const t = newSession(STAGE);
  const tsc = scenes(t, STAGE);
  const q1 = runHook(t, tsc.noPrompt);
  const q2 = runHook(t, withReply(tsc.good));
  const q3 = runHook(t, tsc.noPrompt);
  const q4 = runHook(t, tsc.noPrompt);
  ok(`${STAGE} C5 counter reset after a correct echo`, q1.deny && !q2.deny && q3.deny && q4.deny, show([q1.deny, q2.deny, q3.deny, q4.deny]));
} else if (mode === "publish") {
  // Publish on (stubbed, no network): the plan-link line must carry the synthetic blob URL.
  const pub = { env: { NODE_OPTIONS: `--require "${process.env.CTS_PUBLISH_STUB}"`, PLAN_SYNC_REMOTE_URL: "https://example.invalid/test-owner/test-repo.git" } };
  const urlOf = (s) => "https://example.invalid/test-owner/test-repo/blob/main/" + path.basename(s.plan);
  const s = newSession(STAGE);
  const urlLine = `${STAGE}: ${urlOf(s)} (\`${s.fwd}\`)`;
  const rp = runHook(s, [U("write the plan"), A(T("Here is the plan summary.")), A(T(urlLine)), U("looks good, go ahead")], pub);
  ok(`${STAGE} B0 precondition — the stub publishes (systemMessage shows the example.invalid URL)`, rp.msg.includes(urlOf(s)), rp.msg);
  expectPass(`${STAGE} B1 publish on — URL line ends the previous turn`, rp);
  const d = newSession(STAGE);
  const localLine = `${STAGE}: \`${d.fwd}\` (no URL: not-published)`;
  const rd = runHook(d, [U("write the plan"), A(T("Here is the plan summary.")), A(T(localLine)), U("looks good, go ahead")], pub);
  expectDeny(`${STAGE} B2 publish on — only the local-path line was shown`, rd, d, STAGE);
  // An inline code span opened before the URL makes it untappable; the bare twin is the control.
  const spanRun = (text) => { const s = newSession(STAGE); return { s, r: runHook(s, [U("write the plan"), A(T("Here is the plan summary.")), A(T(text(s))), U("looks good, go ahead")], pub) }; };
  const inSpan = spanRun((s) => "Plan: `See " + urlOf(s) + "`");
  expectDeny(`${STAGE} B3 publish on — URL only inside an inline code span opened earlier`, inSpan.r, inSpan.s, STAGE);
  expectPass(`${STAGE} B4 publish on — same line with the URL bare (control)`, spanRun((s) => "Plan: See " + urlOf(s)).r);
} else if (mode === "fence") {
  // C3: a plan-link line inside a fenced code block is not shown. Reply follows, so only the fence differs.
  const run = (lines) => { const s = newSession(STAGE); return { s, r: runHook(s, withReply([U("write the plan"), A(T("Here is the plan summary.")), A(T(lines(s)))])) }; };
  const cases = [
    ["F1 link only inside a ``` fence", (s) => "Plan:\n```\n" + s.line + "\n```"],
    ["F2 link only inside a ~~~ fence", (s) => "Plan:\n~~~\n" + s.line + "\n~~~"],
    ["F3 link inside an unclosed fence", (s) => "Plan:\n```\n" + s.line],
  ];
  for (const [label, lines] of cases) {
    const { s, r } = run(lines);
    expectDeny(`${STAGE} ${label}`, r, s, STAGE);
  }
  expectPass(`${STAGE} F4 link outside a fence plus a fenced copy`, run((s) => s.line + "\n```\n" + s.line + "\n```").r);
  expectPass(`${STAGE} F5 inline-code path (regression guard)`, run((s) => "Plan: `" + s.fwd + "` (no URL: plan-sync-off)").r);
  // Published state (stubbed, no network): the blob-URL line is fenced the same way.
  const pub = { env: { NODE_OPTIONS: `--require "${process.env.CTS_PUBLISH_STUB}"`, PLAN_SYNC_REMOTE_URL: "https://example.invalid/test-owner/test-repo.git" } };
  const urlLineOf = (s) => `${STAGE}: https://example.invalid/test-owner/test-repo/blob/main/${path.basename(s.plan)} (\`${s.fwd}\`)`;
  const runPub = (lines) => { const s = newSession(STAGE); return { s, r: runHook(s, withReply([U("write the plan"), A(T("Here is the plan summary.")), A(T(lines(s)))]), pub) }; };
  for (const [label, lines] of [
    ["FP1 publish on — URL line only inside a ``` fence", (s) => "Plan:\n```\n" + urlLineOf(s) + "\n```"],
    ["FP2 publish on — URL line only inside a ~~~ fence", (s) => "Plan:\n~~~\n" + urlLineOf(s) + "\n~~~"],
  ]) {
    const { s, r } = runPub(lines);
    expectDeny(`${STAGE} ${label}`, r, s, STAGE);
  }
  expectPass(`${STAGE} FP3 publish on — URL line outside a fence plus a fenced copy`, runPub((s) => urlLineOf(s) + "\n```\n" + urlLineOf(s) + "\n```").r);
} else if (mode === "write") {
  // C1: a non-read tool_use naming the stage artifact basename in the CONFIRM turn counts as a rewrite.
  const run = (tool) => {
    const s = newSession(STAGE);
    const base = path.basename(s.plan);
    const entries = [U("write the plan"), A(T("Here is the plan summary.")), A(T(s.line)), U("looks good, go ahead"), A(tool(s, base)), TR];
    return { s, r: runHook(s, entries) };
  };
  const bash = (command) => ({ type: "tool_use", id: "w1", name: "Bash", input: { command } });
  const other = STAGE === "intent" ? "outline" : "intent";
  const denies = (label, tool) => { const { s, r } = run(tool); expectDeny(`${STAGE} ${label}`, r, s, STAGE); };
  denies("W1 Bash writes the artifact basename", (s, b) => bash(`printf x > "${PLANS}/${b}"`));
  denies("W2 mixed-case basename", (s, b) => bash(`printf x > "${PLANS}/${b.toUpperCase()}"`));
  denies("W3 Windows backslash path", (s, b) => bash(`copy nul "${PLANS.replace(/\//g, "\\")}\\${b}"`));
  expectPass(`${STAGE} W4 Read tool_use on the artifact is not a write`, run((s) => ({ type: "tool_use", id: "w1", name: "Read", input: { file_path: s.plan } })).r);
  expectPass(`${STAGE} W5 Bash touching a different stage's artifact`, run((s) => bash(`printf x > "${PLANS}/${s.sid}-${other}.md"`)).r);
  expectPass(`${STAGE} W6 the CONFIRM echo itself is not a write (control)`, run((s) => bash(echoOf(STAGE))).r);
} else if (mode === "env") {
  const s = newSession("intent");
  const r = runHook(s, scenes(s, "intent").noPrompt, { stage: "intent", env: { CONFIRM_INTENT: "off" } });
  ok("E1 CONFIRM_INTENT=off — intent is still judged (deny)", r.deny, show(r.json));
  ok("E1 CONFIRM_INTENT=off — no confirm-skipped message", !String(r.msg).includes("[confirm-skipped"), r.msg);
  for (const st of ["outline", "detail"]) {
    const so = newSession(st);
    const flag = "CONFIRM_" + st.toUpperCase();
    const ro = runHook(so, scenes(so, st).noPrompt, { stage: st, env: { [flag]: "off" } });
    ok(`E2 ${flag}=off — still skipped, no deny`, !ro.deny && ro.msg === `[confirm-skipped: ${flag}=off]`, show(ro.json));
  }
}
if (mode !== "sentinel") {
  ok(`${mode} ${STAGE || ""} — no output carries permissionDecision allow`.replace(/\s+—/, " —"),
    allOutputs.every((raw) => !/"permissionDecision"\s*:\s*"allow"/.test(raw)), allOutputs.join(" / "));
}
process.stdout.write(out.join("\n") + "\n");
