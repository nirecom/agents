#!/usr/bin/env node
"use strict";
// Tests: hooks/gate-reset-from-sentinel.js, settings.json
// Tags: TL2, reset-from, reset-allowance, pretooluse, permission, settings, scope:issue-specific, pwsh-not-required
// #2852: the PreToolUse hook gate-reset-from-sentinel answers the canonical RESET_FROM echo with
// allow (reason names the remaining allowance) or ask (reason carries the reset reason block),
// answers lookalikes and runInTerminal / runCommands carrying the RESET_FROM token with ask, leaves the rest alone,
// and never denies. settings.json drops the static ask row and registers the hook; the PostToolUse workflow-mark.js row recording the reset stays.
// TL3 gap: the live firing and the merge of allow / ask with the permission rules in claude -p are
// tests/hooks/TL3-hook-reset-from-gate.sh's (Bash only). Neither file catches runInTerminal /
// runCommands on a live host, nor two RESET_FROM echoes racing in one turn (WARN(2) is sequential).

const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const { confirmEnvRoot, childEnvWith } = require("../lib/confirm-env-fixture");

const restore = isolate();
const BASE = fs.mkdtempSync(path.join(os.tmpdir(), "f2852g-"));
const REPO = path.join(BASE, "repo");
const NO_TRANSCRIPTS = path.join(BASE, "transcripts");
fs.mkdirSync(REPO);
fs.mkdirSync(NO_TRANSCRIPTS);
gitInit(REPO);
after(() => {
  restore();
  fs.rmSync(BASE, { recursive: true, force: true });
});

const F = require("./feature-2852-reset-allowance/fixture");
const HOOK = path.join(F.ROOT, "hooks", "gate-reset-from-sentinel.js");
const CFG_OFF = confirmEnvRoot(BASE, F.ALL_OFF);
const CUR = "review_security";

let n = 0;
const newSid = (tag) => `f2852g-${tag}-${++n}`;
const sentinel = (step, reason) => `echo "<<WORKFLOW_RESET_FROM_${step}: ${reason || "fixture reset"}>>"`;
const bodyCmd = (body) => `echo "<<WORKFLOW_RESET_FROM_write_code: ${body}>>"`;

// runHook(sid, input, opts) - one PreToolUse call; answers { decision, reason } where decision is
// allow / ask / deny / none. A hook that does not answer fails the case with its output.
function runHook(sid, input, opts) {
  const o = opts || {};
  assert.ok(fs.existsSync(HOOK), "hooks/gate-reset-from-sentinel.js does not exist");
  const env = childEnvWith(o.cfg || CFG_OFF);
  env.WORKFLOW_SESSION_ID = sid;
  env.CLAUDE_PROJECT_DIR = REPO;
  env.CLAUDE_TRANSCRIPT_BASE_DIR = NO_TRANSCRIPTS;
  for (const k of ["CLAUDECODE", "NODE_OPTIONS", "WORKFLOW_DECISION_TIME_LIMIT_MS"]) delete env[k];
  Object.assign(env, o.env || {});
  const body = typeof input === "string" ? input : JSON.stringify(Object.assign({ session_id: sid, cwd: REPO, hook_event_name: "PreToolUse" }, input));
  const done = spawnSync(process.execPath, [HOOK], { input: body, env, cwd: REPO, encoding: "utf8", timeout: 30000 });
  const lines = String(done.stdout || "").trim().split(/\r?\n/).filter(Boolean);
  let out = null;
  try {
    out = lines.length === 0 ? {} : JSON.parse(lines[lines.length - 1]);
  } catch {
    out = null;
  }
  assert.ok(!done.error && done.status === 0 && out !== null,
    `hook did not answer: status=${done.status} error=${done.error} stdout=${done.stdout} stderr=${done.stderr}`);
  if (out.decision === "block") return { decision: "deny", reason: String(out.reason || "") };
  const h = out.hookSpecificOutput;
  if (!h || !h.permissionDecision) return { decision: "none", reason: "" };
  return { decision: h.permissionDecision, reason: String(h.permissionDecisionReason || "") };
}
const bash = (command) => ({ tool_name: "Bash", tool_input: { command } });

function expectDecision(got, want, label) {
  assert.notStrictEqual(got.decision, "deny", `${label}: the hook never denies (${got.reason})`);
  assert.strictEqual(got.decision, want, `${label}: ${JSON.stringify(got)}`);
}

// session(events) - a fresh session standing at review_security with the given reset history.
function session(items, tag) {
  const sid = newSid(tag || "s");
  F.seed(sid, F.history(CUR, items || []), { cwd: REPO });
  return sid;
}

caseBegin("not-a-sentinel-abstains", "hooks/gate-reset-from-sentinel.js");
test("commands without the sentinel and other tools get no decision", () => {
  const sid = session([]);
  for (const command of ["ls", "echo hello", "git status", 'echo "<<WORKFLOW_CONFIRM_OUTLINE: ok>>"']) {
    expectDecision(runHook(sid, bash(command)), "none", command);
  }
  expectDecision(runHook(sid, { tool_name: "Read", tool_input: { file_path: "x" } }), "none", "Read");
});
caseEnd();

caseBegin("canonical-sentinel-allow-and-ask", "hooks/gate-reset-from-sentinel.js");
test("allowance left -> allow, and the reason names the remaining allowance", () => {
  const got = runHook(session([]), bash(sentinel("write_code")));
  expectDecision(got, "allow", "first reset");
  assert.match(got.reason, /allowance/);
  assert.match(got.reason, /\d/);
});
test("allowance spent -> ask, and the reason carries the reset reasons", () => {
  const got = runHook(session([{ to: "write_code", reason: "beta-one" }, { to: "write_code", reason: "beta-two" }]), bash(sentinel("write_code")));
  expectDecision(got, "ask", "third reset");
  assert.match(got.reason, /beta-one/);
  assert.match(got.reason, /beta-two/);
});
caseEnd();

// review_code_security C1 (HIGH): runInTerminal / runCommands may run pwsh, where U+201C / U+201D /
// U+201E delimit strings like `"`. Only Bash is judged; a non-Bash command tool always asks.
const terminal = (command) => ({ tool_name: "runInTerminal", tool_input: { command } });
const commands = (command) => ({ tool_name: "runCommands", tool_input: { commands: [command] } });
function expectNonBashAsk(got, label) {
  assert.notStrictEqual(got.decision, "allow", `${label}: a non-Bash command tool is never allowed (${got.reason})`);
  expectDecision(got, "ask", label);
  assert.ok(!/[\x00-\x09\x0b-\x1f\x7f]/.test(got.reason), `${label}: control character in ${JSON.stringify(got.reason)}`);
}
caseBegin("non-bash-command-tool-asks", "hooks/gate-reset-from-sentinel.js");
test("runInTerminal with the canonical safe echo asks with the allowance full", () => {
  expectNonBashAsk(runHook(session([], "nb-term"), terminal(sentinel("write_code"))), "runInTerminal canonical");
});
test("runCommands with one canonical safe element asks with the allowance full", () => {
  expectNonBashAsk(runHook(session([], "nb-cmds"), commands(sentinel("write_code"))), "runCommands canonical");
});
const SMART_QUOTES = [["U+201C", "\u{201C}"], ["U+201D", "\u{201D}"], ["U+201E", "\u{201E}"]];
for (const [name, q] of SMART_QUOTES) {
  const cmd = bodyCmd(`abc${q}; Remove-Item foo ;${q}`);
  test(`smart quote ${name} breakout: the command still matches RESET_FROM_RE_DQ`, () => {
    const { RESET_FROM_RE_DQ, hasUnsafeSentinelBody } = require(path.join(F.ROOT, "hooks", "lib", "sentinel-patterns.js"));
    const m = RESET_FROM_RE_DQ.exec(cmd);
    assert.ok(m && m[1] === "write_code", `fixture must reach stage 2 shape: ${cmd}`);
    assert.strictEqual(hasUnsafeSentinelBody(m[2]), false, "fixture must pass the Bash body check");
  });
  test(`runInTerminal smart quote ${name} breakout asks`, () => {
    expectNonBashAsk(runHook(session([], "nb-sq-term"), terminal(cmd)), `runInTerminal ${name}`);
  });
  test(`runCommands smart quote ${name} breakout asks`, () => {
    expectNonBashAsk(runHook(session([], "nb-sq-cmds"), commands(cmd)), `runCommands ${name}`);
  });
}
test("control: Bash with the same canonical safe echo still allows", () => {
  expectDecision(runHook(session([], "nb-bash"), bash(sentinel("write_code"))), "allow", "Bash canonical");
});
test("control: a non-Bash command without the RESET_FROM token gets no decision", () => {
  const sid = session([], "nb-none");
  const rows = [
    ["runInTerminal echo hello", terminal("echo hello")],
    ["runInTerminal other sentinel", terminal('echo "<<WORKFLOW_CONFIRM_OUTLINE: ok>>"')],
    ["runCommands ls, git status", { tool_name: "runCommands", tool_input: { commands: ["ls", "git status"] } }],
  ];
  for (const [label, input] of rows) expectDecision(runHook(sid, input), "none", label);
});
for (const [label, cmds] of [["commands as a string", sentinel("write_code")], ["commands with an empty element first", ["", sentinel("write_code")]]]) {
  test(`runCommands payload variant asks: ${label}`, () => {
    expectNonBashAsk(runHook(session([], "nb-shape"), { tool_name: "runCommands", tool_input: { commands: cmds } }), label);
  });
}
caseEnd();

caseBegin("sentinel-lookalikes-ask", "hooks/gate-reset-from-sentinel.js");
test("a chained, piped or multi-element sentinel asks even with the allowance full", () => {
  const sid = session([]);
  const s = sentinel("write_code");
  for (const command of [`${s} && ls`, `ls; ${s}`, `${s} | cat`, `${s} > out.txt`, `true || ${s}`]) {
    expectDecision(runHook(sid, bash(command)), "ask", command);
  }
  const two = { tool_name: "runCommands", tool_input: { commands: [s, "ls"] } };
  expectDecision(runHook(sid, two), "ask", "runCommands with two elements");
});
test("near-miss spellings of the sentinel ask", () => {
  const sid = session([]);
  const lookalikes = [
    'echo "<<WORKFLOW_RESET_FROM_write_code\u{FF1A} full-width colon>>"',
    'echo "<<WORKFLOW_RESET_FROM_write_code : space before colon>>"',
    'echo "<<WORKFLOW_RESET_FROM_WRITE_CODE: upper case>>"',
    "echo '<<WORKFLOW_RESET_FROM_write_code: single quotes>>'",
    'grep "<<WORKFLOW_RESET_FROM_write_code: as an argument>>" log.txt',
    'echo "<<WORKFLOW_RESET_FROM_write_code: no closing"',
  ];
  for (const command of lookalikes) expectDecision(runHook(sid, bash(command)), "ask", command);
});
caseEnd();

caseBegin("stage-two-failures-ask", "hooks/gate-reset-from-sentinel.js");
test("an unknown session asks", () => {
  expectDecision(runHook(newSid("unknown"), bash(sentinel("write_code"))), "ask", "no state file");
});
test("a state file that is not JSON asks", () => {
  const sid = newSid("json");
  fs.writeFileSync(F.statePath(sid), "{ not json", "utf8");
  expectDecision(runHook(sid, bash(sentinel("write_code"))), "ask", "invalid JSON state");
});
test("a decision past its time limit asks", () => {
  const got = runHook(session([]), bash(sentinel("write_code")), { env: { WORKFLOW_DECISION_TIME_LIMIT_MS: "1" } });
  expectDecision(got, "ask", "time limit 1 ms");
});
test("an unknown target step asks", () => {
  expectDecision(runHook(session([]), bash(sentinel("bogus_step"))), "ask", "bogus_step");
});
test("a reset past the current step asks", () => {
  expectDecision(runHook(session([]), bash(sentinel("docs"))), "ask", "docs while at review_security");
});
test("unreadable stdin is never allowed or denied", () => {
  // The plan has stage 1 abstain on a stdin read failure; the request said ask. Either is safe,
  // so only the unsafe answers are excluded here (see the final report).
  const got = runHook(newSid("stdin"), "{ not json");
  assert.ok(["none", "ask"].includes(got.decision), JSON.stringify(got));
});
caseEnd();

// The fault preload sits in the issue fixture dir; the log proves the fault was reached, so an ask
// with another cause cannot pass these cases. Each session would otherwise allow (allowance full).
const FAULT_PRELOAD = F.fwd(path.join(__dirname, "feature-2852-reset-allowance", "fault-preload.js"));
function runWithFault(mode) {
  const log = path.join(BASE, `fault-${mode}-${++n}.log`);
  const got = runHook(session([], mode), bash(sentinel("write_code")), {
    env: { NODE_OPTIONS: `--require "${FAULT_PRELOAD}"`, F2852_FAULT: mode, F2852_FAULT_LOG: log },
  });
  const seen = fs.existsSync(log) ? fs.readFileSync(log, "utf8") : "";
  return { got, seen };
}
caseBegin("judgment-part-failures-ask", "hooks/gate-reset-from-sentinel.js");
test("control: the same session without a fault allows", () => {
  expectDecision(runHook(session([], "nofault"), bash(sentinel("write_code"))), "allow", "no fault");
});
test("a judgment part that fails to load asks, never denies", () => {
  const { got, seen } = runWithFault("require-fails");
  expectDecision(got, "ask", "reset-allowance require fails");
  assert.match(seen, /^require .*reset-allowance/m, `the hook never required the judgment parts: ${seen}`);
});
test("decideReset throwing asks, never denies", () => {
  const { got, seen } = runWithFault("decide-throws");
  expectDecision(got, "ask", "decideReset throws");
  assert.match(seen, /^decideReset$/m, `decideReset was never called: ${seen}`);
});
caseEnd();

caseBegin("confirm-flag-reaches-the-hook", "hooks/gate-reset-from-sentinel.js");
test("the hook reads the CONFIRM_* flags from AGENTS_MAIN_ROOT/.env", () => {
  const sid = session([]);
  expectDecision(runHook(sid, bash(sentinel("outline"))), "allow", "outline, all off");
  const cfg = confirmEnvRoot(BASE, Object.assign({}, F.ALL_OFF, { CONFIRM_OUTLINE: "on" }));
  expectDecision(runHook(sid, bash(sentinel("outline")), { cfg }), "ask", "outline, CONFIRM_OUTLINE=on");
});
caseEnd();

caseBegin("ask-reason-block", "hooks/gate-reset-from-sentinel.js");
test("the ask reason lists the most recent five reset reasons only", () => {
  const items = [];
  for (let i = 1; i <= 7; i++) items.push({ to: "write_code", reason: `alpha${i}` });
  const got = runHook(session(items, "block"), bash(sentinel("write_code", "alpha8")));
  expectDecision(got, "ask", "eighth reset");
  for (let i = 3; i <= 7; i++) assert.ok(got.reason.includes(`alpha${i}`), `alpha${i} listed: ${got.reason}`);
  for (const old of ["alpha1", "alpha2"]) assert.ok(!new RegExp(`${old}(?!\\d)`).test(got.reason), `${old} dropped: ${got.reason}`);
});
test("the ask reason names this reset, the count, the allowance left and each row's outcome", () => {
  // Replay with all flags off: two passes, then an approved ask on an implementation step (no
  // refill), so the fourth reset asks with 0 left. The count may include this reset (3 or 4).
  const items = [1, 2, 3].map((i) => ({ to: "write_code", reason: `gamma${i}` }));
  const got = runHook(session(items, "block-fields"), bash(sentinel("write_code", "gamma-now")));
  expectDecision(got, "ask", "fourth reset");
  const text = got.reason;
  assert.match(text, /write_code/, `target step: ${text}`);
  assert.match(text, /gamma-now/, `this reset's reason: ${text}`);
  assert.match(text, /(?:reset|count)[^\n]{0,40}\b[34]\b|\b[34]\b[^\n]{0,20}reset/i, `reset count: ${text}`);
  assert.match(text, /allowance[^\n]{0,40}\b0\b/i, `allowance left: ${text}`);
  const lines = text.split(/\r?\n/);
  // A past reset that went through an ask and was recorded reads back as "approved" (detail: replay outcome).
  for (const [i, outcome] of [[1, "passed"], [2, "passed"], [3, "approved"]]) {
    const row = lines.filter((l) => new RegExp(`gamma${i}(?!\\d)`).test(l));
    assert.strictEqual(row.length, 1, `one row for gamma${i}: ${text}`);
    assert.match(row[0], new RegExp(`\\b${outcome}\\b`), `gamma${i} row carries outcome ${outcome}: ${row[0]}`);
  }
});
caseEnd();

caseBegin("no-reservation-between-judgments", "hooks/gate-reset-from-sentinel.js");
test("audit WARN(2): judging twice spends nothing; only a recorded reset does", () => {
  // The hook only reads. With one pass left, two evaluations before any reset is recorded both
  // allow; the allowance moves only when workflow-mark records the reset events.
  const sid = session(["write_code"], "warn2");
  expectDecision(runHook(sid, bash(sentinel("write_code"))), "allow", "first evaluation");
  expectDecision(runHook(sid, bash(sentinel("write_code"))), "allow", "second evaluation");
  F.append(sid, F.resetEvents("write_code", "recorded").concat(F.completeRange("write_code", CUR)));
  expectDecision(runHook(sid, bash(sentinel("write_code"))), "ask", "after the reset was recorded");
});
caseEnd();

caseBegin("settings-registration", "settings.json");
const settings = () => JSON.parse(fs.readFileSync(path.join(F.ROOT, "settings.json"), "utf8"));
const hookRows = (event) => (settings().hooks[event] || []).flatMap((e) => (e.hooks || []).map((h) => Object.assign({ matcher: e.matcher }, h)));
test("no static permission row names the RESET_FROM sentinel", () => {
  const perms = settings().permissions || {};
  for (const list of ["ask", "allow", "deny"]) {
    const rows = (perms[list] || []).filter((r) => r.includes("WORKFLOW_RESET_FROM"));
    assert.deepStrictEqual(rows, [], `permissions.${list}`);
  }
});
test("PreToolUse runs gate-reset-from-sentinel.js for Bash, runInTerminal and runCommands", () => {
  const rows = hookRows("PreToolUse").filter((h) => String(h.command).includes("hooks/gate-reset-from-sentinel.js"));
  assert.strictEqual(rows.length, 1, JSON.stringify(rows));
  assert.strictEqual(rows[0].matcher, "Bash|runInTerminal|runCommands");
  assert.strictEqual(rows[0].command, 'node "$AGENTS_MAIN_ROOT/hooks/gate-reset-from-sentinel.js"');
  assert.strictEqual(rows[0].timeout, 15);
});
test("PostToolUse still records the reset through workflow-mark.js", () => {
  const rows = hookRows("PostToolUse").filter((h) => String(h.command).includes("hooks/workflow-mark.js"));
  assert.ok(rows.some((h) => h.matcher === "Bash|runInTerminal|runCommands"), JSON.stringify(rows));
  const src = fs.readFileSync(path.join(F.ROOT, "hooks", "workflow-mark.js"), "utf8");
  assert.match(src, /require\(["']\.\/workflow-mark\/reset-handler["']\)/);
});
caseEnd();

// review_security F1 (HIGH): RESET_FROM_RE_DQ alone lets a body that closes the quote, expands or
// spans lines through to an allow. Every row runs on a session whose allowance is full and whose
// flags are off, so the same command with a clean body would allow (control rows below).
caseBegin("unsafe-sentinel-body-asks", "hooks/gate-reset-from-sentinel.js");
const unsafeBodyCases = [
  { name: "command substitution", input: bash(bodyCmd("$(touch pwned)")) },
  { name: "backtick substitution", input: bash(bodyCmd("`touch pwned`")) },
  { name: "variable expansion", input: bash(bodyCmd("$HOME")) },
  { name: "quote closed and chained", input: bash('echo "<<WORKFLOW_RESET_FROM_write_code: a"; touch x; echo "b>>"') },
  { name: "LF splits into commands", input: bash(bodyCmd("a\ntouch x\nb")) },
  { name: "CR alone in the body", input: bash(bodyCmd("a\rtouch x")) },
  { name: "backslash in the body", input: bash(bodyCmd("a\\ b")) },
  { name: "runInTerminal command substitution", input: { tool_name: "runInTerminal", tool_input: { command: bodyCmd("$(touch pwned)") } } },
  { name: "runCommands command substitution", input: { tool_name: "runCommands", tool_input: { commands: [bodyCmd("$(touch pwned)")] } } },
];
for (const { name, input } of unsafeBodyCases) {
  test(`unsafe body asks with the allowance full: ${name}`, () => {
    const got = runHook(session([], "unsafe"), input);
    assert.notStrictEqual(got.decision, "allow", `${name}: an unsafe body must never be allowed (${got.reason})`);
    expectDecision(got, "ask", name);
  });
}
const safeBodyCases = [
  { name: "plain ascii", body: "fixture reset" },
  { name: "japanese with colon, parentheses and comma", body: "\u{518D}\u{5B9F}\u{884C}: \u{30C6}\u{30B9}\u{30C8}\u{5931}\u{6557} (2\u{56DE}\u{76EE}, review)" },
];
for (const { name, body } of safeBodyCases) {
  test(`control: a clean body still allows: ${name}`, () => {
    expectDecision(runHook(session([], "safe"), bash(bodyCmd(body))), "allow", name);
  });
}
caseEnd();

// review_security F3 (LOW): an internal error message (it may hold an absolute path) never reaches
// the ask text. The fault log proves the fault fired, so the ask is the fault's.
caseBegin("internal-error-message-hidden", "hooks/gate-reset-from-sentinel.js");
test("decideReset throwing: the ask text omits the exception message", () => {
  const { got, seen } = runWithFault("decide-throws");
  expectDecision(got, "ask", "decideReset throws");
  assert.match(seen, /^decideReset$/m, `decideReset was never called: ${seen}`);
  for (const leak of ["F2852_FAULT", "decideReset failed"]) {
    assert.ok(!got.reason.includes(leak), `ask text leaks "${leak}": ${got.reason}`);
  }
});
test("a judgment part that fails to load: the ask text omits the message and the module path", () => {
  const { got, seen } = runWithFault("require-fails");
  expectDecision(got, "ask", "reset-allowance require fails");
  assert.match(seen, /^require .*reset-allowance/m, `the hook never required the judgment parts: ${seen}`);
  const modulePath = seen.split(/\r?\n/)[0].replace(/^require /, "");
  for (const leak of ["F2852_FAULT", "cannot load", modulePath, F.fwd(modulePath)]) {
    assert.ok(!got.reason.includes(leak), `ask text leaks "${leak}": ${got.reason}`);
  }
});
caseEnd();

// review_security F2 (MEDIUM) through the hook: TAB and other control characters are not in the F1
// unsafe set, so they reach the judge; both ask texts (askReason and the plain fallback head)
// must show them as spaces and keep this reset on one line.
const CTRL_REASON = "tab\there bell\x07here";
function expectOneCleanLine(text, label) {
  assert.ok(!/[\x00-\x09\x0b-\x1f\x7f]/.test(text), `${label}: control character left in ${JSON.stringify(text)}`);
  const line = text.split("\n").find((l) => l.includes("RESET_FROM_write_code"));
  assert.ok(line && /tab\s+here/.test(line) && /bell\s+here/.test(line), `${label}: this reset on one line: ${JSON.stringify(text)}`);
}
caseBegin("control-characters-in-ask-text", "hooks/gate-reset-from-sentinel.js");
test("askReason path (allowance spent): control characters become spaces", () => {
  const got = runHook(session(["write_code", "write_code"], "ctrl"), bash(bodyCmd(CTRL_REASON)));
  expectDecision(got, "ask", "third reset");
  expectOneCleanLine(got.reason, "askReason");
});
test("fallback head (judgment parts fail to load): control characters become spaces", () => {
  const log = path.join(BASE, `fault-ctrl-${++n}.log`);
  const got = runHook(session([], "ctrl-fault"), bash(bodyCmd(CTRL_REASON)), {
    env: { NODE_OPTIONS: `--require "${FAULT_PRELOAD}"`, F2852_FAULT: "require-fails", F2852_FAULT_LOG: log },
  });
  expectDecision(got, "ask", "require fails");
  assert.ok(fs.existsSync(log), "the fault never fired");
  expectOneCleanLine(got.reason, "fallback head");
});
caseEnd();
