"use strict";
// #3144 C2 cases of ../feature-2853-pre-confirm-audit.js: the gate decides the destination before it arms (S2-1/S2-2),
// `--audit-route pm[:<tag>]` (S2-3) and the plan form of WORKFLOW_PM_REVIEW_ACCEPTED (S2-4). The gate child loads
// owner-stub-preload.js, so the stub decides the assigned PM. The caller owns the case markers.
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const D = require("./driver");
const P = require("../feature-3144-pm-review-writer/fixture");

const { X } = D;
let FX = null;
const fx = () => FX || (FX = P.make(fs.mkdtempSync(path.join(X.F.STATE_DIR, "pm3144-"))));
const pmEnv = () => Object.assign({ NODE_OPTIONS: X.nodeOptions([P.PRELOAD]) }, fx().env());
const LAUNCH_RE = /launch the supervisor-audit subagent|agents\/supervisor-audit\.md as a subagent/i;
const SENTINEL = "WORKFLOW_PM_REVIEW_ACCEPTED";

// gateAt(sid, args) -> parseGate(...) + {rc, out, err} of `next-step --gate --session sid ...args` under the stub.
function gateAt(sid, args) {
  const r = spawnSync(process.execPath, [path.join(D.ROOT, "bin/workflow/next-step"), "--gate", "--session", sid].concat(args || []), {
    env: D.childEnv({}, pmEnv()), encoding: "utf8", timeout: 60000, cwd: X.TDIR,
  });
  return Object.assign({ rc: r.status, out: r.stdout || "", err: r.stderr || "" }, D.parseGate(r.stdout));
}

// session(issues) -> an outline-stage session (audit unsettled) whose intent closes example-owner/example-repo#<n>.
function session(issues) {
  const s = X.sessionAt("outline", { audit: false });
  const refs = issues.map((n) => `- example-owner/example-repo#${n} fixture`).join("\n");
  X.F.writePlan(s.sid, "intent", `# Intent\n\n## Goal\n\nfixture goal\n\n## Issues\n\n${refs}\n\n## Constraints\n\nnone\n`);
  return s.sid;
}

const findingsOf = (sid, reporter, runId) => fx().findings(sid).filter((f) => f && f.reporter === reporter && String(f.detail || "").includes(runId));
const destNames = (sid, runId, pm) => findingsOf(sid, "route:pm-dest", runId).some((f) => JSON.stringify(f).includes(pm.session_id));
const ledgerLen = (sid) => D.ledgerOf(sid).length;
const tr2 = (sid) => D.countOf(sid, "TR2") || 0;
const runOf = (g) => g.lines.GATE_AUDIT_RUN_ID || "";

// pmHint(check, tag, g, runId, pm): a pm-route answer naming the destination, without the subagent launch.
function pmHint(check, tag, g, runId, pm) {
  check(`${tag}: GATE_ACTION stays audit-wait`, g.action === "audit-wait", g.out || g.err);
  check(`${tag}: REASON carries pm-route:pm`, g.reason.includes("pm-route:pm"), g.reason);
  check(`${tag}: the hint names the run and the destination PM`, g.hint.includes(runId) && g.hint.includes(pm.tag) && g.hint.includes(pm.session_id), g.hint);
  check(`${tag}: the hint points at the Review request`, g.hint.includes("Review request"), g.hint);
  check(`${tag}: the hint has no supervisor-audit subagent launch`, !LAUNCH_RE.test(g.hint), g.hint);
}

// routes(check): subagent / pm / ask (several candidates) / ask (undecidable, local holder) hints and side effects.
function routes(check) {
  const F = fx();
  const A = F.pm("pm-a");
  const B = F.pm("pm-b");
  const H = F.pm("pm-held");
  F.setOwners({ 3901: null });
  let sid = session([3901]);
  let g = gateAt(sid);
  check("R1 subagent: audit-wait with the launch line", g.action === "audit-wait" && LAUNCH_RE.test(g.hint) && runOf(g) !== "", g.out || g.err);
  check("R1 subagent: REASON carries pm-route:subagent", g.reason.includes("pm-route:subagent"), g.reason);
  check("R1 subagent: no destination finding", findingsOf(sid, "route:pm-dest", runOf(g)).length === 0, D.show(F.findings(sid)));

  F.setOwners({ 3901: A });
  sid = session([3901]);
  g = gateAt(sid);
  pmHint(check, "R1 pm (one candidate)", g, runOf(g), A);
  check("R1 pm: the arm wrote the destination finding naming A", runOf(g) !== "" && destNames(sid, runOf(g), A), D.show(F.findings(sid)));
  check("R1 pm: TR2 counted once", tr2(sid) === 1, D.show(D.audit(sid).audit_run_counts));

  F.setOwners({ 3901: A, 3902: B });
  sid = session([3901, 3902]);
  g = gateAt(sid);
  check("R1 ask (two candidates): GATE_ACTION stays audit-wait", g.action === "audit-wait", g.out || g.err);
  check("R1 ask: REASON carries pm-route:ask", g.reason.includes("pm-route:ask"), g.reason);
  check("R1 ask: no run armed (no GATE_AUDIT_RUN_ID, empty ledger)", runOf(g) === "" && ledgerLen(sid) === 0, D.show(D.audit(sid)));
  check("R1 ask: nothing counted", tr2(sid) === 0, D.show(D.audit(sid).audit_run_counts));
  check("R1 ask: the hint lists both candidates and the two choices", g.hint.includes(A.tag) && g.hint.includes(B.tag) &&
    g.hint.includes("--audit-route") && g.hint.includes(SENTINEL), g.hint);
  check("R1 ask: the hint has no supervisor-audit subagent launch", !LAUNCH_RE.test(g.hint), g.hint);

  for (const [name, owners] of [["field unset, local holder", { 3901: null }], ["owner lookup timeout", { 3901: "timeout" }]]) {
    F.setOwners(owners, { 3901: [H] });
    sid = session([3901]);
    g = gateAt(sid);
    check(`R1 undecidable (${name}): ask, nothing armed or counted`, g.reason.includes("pm-route:ask") && runOf(g) === "" && ledgerLen(sid) === 0 && tr2(sid) === 0,
      g.out || g.err);
    check(`R1 undecidable (${name}): no PM choice for the local holder`, !g.hint.includes(H.tag) && !g.hint.includes(H.session_id) &&
      !g.hint.includes("--audit-route pm:"), g.hint);
    check(`R1 undecidable (${name}): the fallback sentinel is offered`, g.hint.includes(SENTINEL), g.hint);
  }
}

// lookupScope(check): the owner lookup runs only in the arm branch, never on a settled stage.
function lookupScope(check) {
  const F = fx();
  const A = F.pm("pm-a");
  F.setOwners({ 3901: A });
  const sid = session([3901]);
  F.clearLog();
  const g = gateAt(sid);
  check("R2 the arm branch asks the owner", F.ownerCalls().some((c) => c.fn === "ownerOf"), D.show(F.ownerCalls()));
  try { D.S.finalize(sid, runOf(g), "CONTINUE"); } catch (e) { check("R2 fixture: settle the pm run", false, e.message); }
  F.clearLog();
  const g2 = gateAt(sid);
  check("R2 settled CONTINUE: the gate admits (ask)", g2.action === "ask", g2.out || g2.err);
  check("R2 settled CONTINUE: no owner lookup outside the arm branch", F.ownerCalls().length === 0, D.show(F.ownerCalls()));
}

// replace(check): an in-flight run without a destination, or with a stale one, is replaced; a current one is reused.
function replace(check) {
  const F = fx();
  const A = F.pm("pm-a");
  const B = F.pm("pm-b");
  const C = F.pm("pm-c");
  F.setOwners({ 3901: null });
  let sid = session([3901]);
  const r0 = runOf(gateAt(sid));
  F.setOwners({ 3901: A });
  let g = gateAt(sid);
  check("R3 no-destination in-flight run: replaced by a new run", runOf(g) !== "" && runOf(g) !== r0, D.show([r0, runOf(g)]));
  check("R3 no-destination: the new run is counted and names A", tr2(sid) === 2 && destNames(sid, runOf(g), A), D.show([D.audit(sid).audit_run_counts, F.findings(sid)]));
  pmHint(check, "R3 no-destination replaced", g, runOf(g), A);

  sid = session([3901]);
  const r1 = runOf(gateAt(sid));
  F.setOwners({ 3901: C });
  g = gateAt(sid);
  check("R3 stale destination (owner changed): replaced, counted, names C", runOf(g) !== r1 && tr2(sid) === 2 && destNames(sid, runOf(g), C),
    D.show([r1, runOf(g), D.audit(sid).audit_run_counts]));

  F.setOwners({ 3901: A });
  sid = session([3901, 3902]);
  const r2 = runOf(gateAt(sid));
  g = gateAt(sid);
  check("R3 current destination: the pm rerun reuses the run", runOf(g) === r2 && tr2(sid) === 1 && ledgerLen(sid) === 1, D.show([r2, runOf(g)]));
  F.setOwners({ 3901: A, 3902: B });
  g = gateAt(sid);
  check("R3 current destination under an ask route: reused, not re-asked", runOf(g) === r2 && ledgerLen(sid) === 1 && tr2(sid) === 1, g.out || g.err);
  pmHint(check, "R3 ask route reusing the destination's run", g, r2, A);
}

// capped(sid) -> drives three subagent-route runs (TR2 at the cap) and leaves the last one in flight.
function capped(sid, check, tag) {
  for (let n = 1; n <= 3; n += 1) {
    if (n > 1) D.editPlan(sid, "outline", n);
    gateAt(sid);
  }
  check(`${tag} fixture: TR2 at the cap with a run in flight`, tr2(sid) === 3 && ["pending", "in_progress"].includes(D.audit(sid).audit_phase),
    D.show(D.audit(sid)));
}

// capNoReplace(check): at the cap a no-destination in-flight run is not replaced; the cap procedure answers.
function capNoReplace(check) {
  const F = fx();
  F.setOwners({ 3901: null });
  const sid = session([3901]);
  capped(sid, check, "R4");
  const A = F.pm("pm-a");
  F.setOwners({ 3901: A });
  const g = gateAt(sid);
  check("R4 at the cap: no new run and no new count", ledgerLen(sid) === 3 && tr2(sid) === 3, D.show(D.audit(sid)));
  check("R4 at the cap: no destination finding written", !F.findings(sid).some((f) => f && f.reporter === "route:pm-dest"), D.show(F.findings(sid)));
  check("R4 at the cap: the gate enters the cap procedure (audit-block)", g.action === "audit-block", g.out || g.err);
}

// auditRoute(check): `--audit-route pm[:<tag>]`.
function auditRoute(check) {
  const F = fx();
  const A = F.pm("pm-a");
  const B = F.pm("pm-b");
  const H = F.pm("pm-held");
  F.setOwners({ 3901: A });
  let sid = session([3901]);
  let g = gateAt(sid, ["--audit-route", "pm"]);
  const r1 = runOf(g);
  check("R5 --audit-route pm, nothing in flight: the first run, counted, destination A", r1 !== "" && tr2(sid) === 1 && destNames(sid, r1, A), g.out || g.err);
  pmHint(check, "R5 --audit-route pm", g, r1, A);
  g = gateAt(sid, ["--audit-route", "pm"]);
  check("R5 --audit-route pm, a run in flight: a new run, counted", runOf(g) !== "" && runOf(g) !== r1 && tr2(sid) === 2 && destNames(sid, runOf(g), A),
    D.show([r1, runOf(g), D.audit(sid).audit_run_counts]));
  g = gateAt(sid, ["--audit-route", "pm"]);
  const r3 = runOf(g);
  check("R5 third --audit-route pm: TR2 reaches the cap", tr2(sid) === 3, D.show(D.audit(sid).audit_run_counts));
  g = gateAt(sid, ["--audit-route", "pm"]);
  check("R5 at the cap: nothing armed or counted", ledgerLen(sid) === 3 && tr2(sid) === 3, D.show(D.audit(sid)));
  check("R5 at the cap: the in-flight run is released", !["pending", "in_progress"].includes(D.audit(sid).audit_phase) &&
    ((D.runEntry(sid, r3) || {}).outcome || "") !== "", D.show(D.runEntry(sid, r3)));
  check("R5 at the cap: audit-block (cap procedure)", g.action === "audit-block", g.out || g.err);

  F.setOwners({ 3901: A, 3902: B });
  sid = session([3901, 3902]);
  g = gateAt(sid, ["--audit-route", `pm:${B.tag}`]);
  check("R5 pm:<tag>: the chosen candidate B is the destination", runOf(g) !== "" && destNames(sid, runOf(g), B) && !destNames(sid, runOf(g), A), D.show(F.findings(sid)));
  pmHint(check, "R5 pm:<tag>", g, runOf(g), B);

  const refused = (tag, owners, holders, issues, args) => {
    F.setOwners(owners, holders);
    const s = session(issues);
    const r = gateAt(s, ["--audit-route"].concat(args));
    check(`R5 refused (${tag}): nothing armed or counted`, runOf(r) === "" && ledgerLen(s) === 0 && tr2(s) === 0, r.out || r.err);
    check(`R5 refused (${tag}): no destination finding`, !F.findings(s).some((f) => f && f.reporter === "route:pm-dest"), D.show(F.findings(s)));
    return r;
  };
  refused("tag not a candidate", { 3901: A, 3902: B }, null, [3901, 3902], ["pm:pm-stranger"]);
  refused("no tag with two candidates", { 3901: A, 3902: B }, null, [3901, 3902], ["pm"]);
  refused("empty candidate set", { 3901: null }, null, [3901], ["pm"]);
  const r = refused("undecidable, local holder's tag", { 3901: null }, { 3901: [H] }, [3901], [`pm:${H.tag}`]);
  check("R5 refused (undecidable): the answer is ask, never the holder", r.reason.includes("pm-route:ask") && !r.hint.includes(H.session_id), r.out || r.err);
  refused("subagent is not a route value", { 3901: A }, null, [3901], ["subagent"]);
}

// mark(sid, command) -> the stdout + stderr of hooks/workflow-mark.js on the main conversation's Bash command.
function mark(sid, command) {
  const input = { tool_name: "Bash", session_id: sid, tool_input: { command, cwd: X.TDIR }, tool_response: { exit_code: 0 } };
  const r = spawnSync(process.execPath, [path.join(D.ROOT, "hooks", "workflow-mark.js")], {
    input: JSON.stringify(input), encoding: "utf8", timeout: 60000, env: D.childEnv({}, pmEnv()), cwd: X.TDIR,
  });
  return (r.stdout || "") + (r.stderr || "");
}
// verdictHook(callerSid, target, runId) -> the decision of hooks/block-main-audit-verdict.js on the verdict CLI.
function verdictHook(callerSid, target, runId) {
  const cmd = `node "$AGENTS_MAIN_ROOT/bin/supervisor-write-audit-verdict" --session-id ${target} --audit-run-id ${runId} --verdict CONTINUE --verdict-summary "ok"`;
  const input = { session_id: callerSid, hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command: cmd } };
  const r = spawnSync(process.execPath, [path.join(D.ROOT, "hooks", "block-main-audit-verdict.js")], {
    input: JSON.stringify(input), encoding: "utf8", timeout: 60000, env: D.childEnv({}, pmEnv()), cwd: X.TDIR,
  });
  try { return JSON.parse(String(r.stdout || "").trim()).decision || ""; } catch (_) { return "unparsed:" + r.stdout; }
}
const accepted = (target) => `echo "<<${SENTINEL}: ${target} the PM did not answer twice; the user chose the supervisor-audit>>"`;

// sentinel(check): the plan form arms a counted fallback run, the gate gives it the subagent hint, the PM cannot write it.
function sentinel(check) {
  const F = fx();
  const A = F.pm("pm-a");
  F.setOwners({ 3901: A });
  let sid = session([3901]);
  const r1 = runOf(gateAt(sid));
  const out = mark(sid, accepted("outline"));
  const runNow = D.audit(sid).audit_run_id || "";
  check("R6 sentinel: a new run is armed and counted", runNow !== "" && runNow !== r1 && tr2(sid) === 2, D.show([r1, runNow, D.audit(sid).audit_run_counts, out]));
  check("R6 sentinel: the fallback finding names the new run", findingsOf(sid, "user:pm-review-fallback", runNow).length === 1, D.show(F.findings(sid)));
  check("R6 sentinel: the fallback run carries no destination", findingsOf(sid, "route:pm-dest", runNow).length === 0, D.show(F.findings(sid)));
  F.clearLog();
  const g = gateAt(sid);
  check("R6 sentinel: the gate gives the subagent hint for the fallback run", g.action === "audit-wait" && runOf(g) === runNow && LAUNCH_RE.test(g.hint) &&
    g.reason.includes("pm-route:subagent"), g.out || g.err);
  check("R6 sentinel: the fallback run needs no owner lookup", F.ownerCalls().length === 0, D.show(F.ownerCalls()));
  check("R6 sentinel: the PM writing the fallback run is blocked", verdictHook(A.session_id, sid, runNow) === "block", "decision");

  F.setOwners({ 3901: null });
  sid = session([3901]);
  capped(sid, check, "R6");
  F.setOwners({ 3901: A });
  mark(sid, accepted("outline"));
  check("R6 sentinel at the cap: nothing armed or counted", ledgerLen(sid) === 3 && tr2(sid) === 3, D.show(D.audit(sid)));
  check("R6 sentinel at the cap: no fallback finding", !F.findings(sid).some((f) => f && f.reporter === "user:pm-review-fallback"), D.show(F.findings(sid)));
}

module.exports = { routes, lookupScope, replace, capNoReplace, auditRoute, sentinel };
