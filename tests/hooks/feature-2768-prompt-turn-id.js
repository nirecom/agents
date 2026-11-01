"use strict";
// tests/hooks/feature-2768-prompt-turn-id.js
// Tests: hooks/user-prompt-submit-turn-id.js, hooks/lib/prompt-turn-id.js, hooks/lib/user-dialog-turn.js
// Tags: scope:issue-specific, TL2, plan-sync, turn-commit, prompt-turn, user-prompt-submit, a-pure
// #2768 (A-pure): the UserPromptSubmit hook alone marks the turn boundary. It removes the previous
// prompt-turn.json, then writes {turn_id, created_at}; resolveTurnContext reads that file and never a transcript.

// TL3 gap (what this test does NOT catch), category: hook-registration
// - whether UserPromptSubmit really fires once per typed prompt in a live session (and not on a Stop-guard continuation)
// - whether a real subagent PostToolUse input carries the parent's session_id (the P8 premise)

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { after, test } = require("node:test");
const { noNewFailures } = require("../lib/case-verdict");

const restore = isolate();
const F = require("../lib/plan-sync-turn-fixture");
after(() => {
  F.finish();
  restore();
});
const HOOK = "hooks/user-prompt-submit-turn-id.js";
const HEX32 = /^[0-9a-f]{32}$/;
const hookInput = (sid, prompt) => ({ session_id: sid, hook_event_name: "UserPromptSubmit",
  prompt: prompt === undefined ? "hello" : prompt, cwd: F.DIRS.neutral });
const keysOf = (o) => JSON.stringify(Object.keys(o || {}).sort());

function lib() { return F.mod("hooks/lib/prompt-turn-id.js"); }

// writeFileAt(file, text) -> file: a fixture file written without the code under test.
function writeFileAt(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text);
  return file;
}
// newerPromptLine(text) -> one transcript line holding a human prompt newer than any turn file here.
const newerPromptLine = (text) => JSON.stringify({ type: "user", message: { role: "user", content: text }, origin: { kind: "human" },
  timestamp: F.iso(Date.now() + 60000), uuid: crypto.randomUUID() }) + "\n";
// listTree(dir) -> every path under <dir> (sorted), for "nothing was created or removed" checks.
function listTree(dir) {
  const out = [];
  const walk = (d) => { for (const n of fs.readdirSync(d)) { const p = path.join(d, n); out.push(p); if (fs.lstatSync(p).isDirectory()) walk(p); } };
  if (fs.existsSync(dir)) walk(dir);
  return out.sort();
}
const readRaw = (sid) => { try { return fs.readFileSync(F.promptTurnPath(sid), "utf8"); } catch (_) { return null; } };
const tmpLeftovers = (sid) => { const d = path.dirname(F.promptTurnPath(sid)); return fs.existsSync(d) ? fs.readdirSync(d).filter((n) => /prompt-turn/.test(n) && n !== "prompt-turn.json") : []; };
// failingFs() -> an fs whose renameSync throws, every other call left to the real fs.
const failingFs = () => Object.create(fs, { renameSync: { value: () => { throw Object.assign(new Error("EPERM rename (test)"), { code: "EPERM" }); } } });

caseBegin("P1-P3, P9, P9b hook writes one turn id per prompt, fail-open", "hooks/user-prompt-submit-turn-id.js");
test("P1-P3, P9, P9b hook writes one turn id per prompt, fail-open", () => noNewFailures(F.failureCount, () => {
  F.guard("P1 hook writes prompt-turn.json", () => {
    const sid = F.newSid("p1");
    const r = F.runNode(HOOK, hookInput(sid, "hello, plan this"));
    F.check("P1 exit 0", r.code === 0, `code=${r.code} err=${r.err}`);
    F.check("P1 stdout is {}", r.out.trim() === "{}", r.out);
    const body = F.readPromptTurnFile(sid);
    F.check("P1 turn_id is 32 hex", body && HEX32.test(String(body.turn_id)), JSON.stringify(body));
    const at = body ? Date.parse(body.created_at) : NaN;
    F.check("P1 created_at is a recent ISO time", Number.isFinite(at) && Math.abs(Date.now() - at) < 120000, body && body.created_at);
    F.check("P1 the file holds exactly turn_id and created_at (no prompt hash)", keysOf(body) === '["created_at","turn_id"]', JSON.stringify(body));
    F.check("P1 no temp file left behind", tmpLeftovers(sid).length === 0, tmpLeftovers(sid).join(","));
  });
  F.guard("P1 settings.json registers the hook under UserPromptSubmit", () => {
    const s = JSON.parse(fs.readFileSync(path.join(F.ROOT, "settings.json"), "utf8"));
    const cmds = ((s.hooks && s.hooks.UserPromptSubmit) || []).flatMap((g) => (g.hooks || []).map((h) => String(h.command)));
    F.check("P1 registration present", cmds.some((c) => c.includes("hooks/user-prompt-submit-turn-id.js")), cmds.join(" | "));
  });
  F.guard("P2 a second prompt gets a new id", () => {
    const sid = F.newSid("p2");
    F.runNode(HOOK, hookInput(sid));
    const a = F.readPromptTurnFile(sid);
    const r = F.runNode(HOOK, hookInput(sid, "second"));
    const b = F.readPromptTurnFile(sid);
    F.check("P2 exit 0", r.code === 0, r.err);
    F.check("P2 ids differ", a && b && HEX32.test(String(b.turn_id)) && a.turn_id !== b.turn_id, `${a && a.turn_id} ${b && b.turn_id}`);
  });
  F.guard("P3 empty input is fail-open", () => {
    const r = F.runNode(HOOK, {});
    F.check("P3 {} input exit 0 + {}", r.code === 0 && r.out.trim() === "{}", `code=${r.code} out=${r.out} err=${r.err}`);
    const g = F.runNode(HOOK, "not json");
    F.check("P3 garbage input exit 0 + {}", g.code === 0 && g.out.trim() === "{}", `code=${g.code} out=${g.out}`);
  });
  F.guard("P3 no prompt or an empty prompt still writes a turn id", () => {
    for (const [name, prompt] of [["missing", null], ["empty", ""], ["not a string", 42]]) {
      const sid = F.newSid("p3p");
      const input = hookInput(sid);
      if (prompt === null) delete input.prompt; else input.prompt = prompt;
      const r = F.runNode(HOOK, input);
      F.check(`P3 prompt ${name}: exit 0 + {}`, r.code === 0 && r.out.trim() === "{}", `code=${r.code} out=${r.out} err=${r.err}`);
      const body = F.readPromptTurnFile(sid);
      F.check(`P3 prompt ${name}: a 32-hex turn id is written`, body && HEX32.test(String(body.turn_id)), JSON.stringify(body));
    }
  });
  F.guard("P3 a prompt with no text after a valid turn starts a new turn", () => {
    const repo = F.makeRepo("p3s");
    const sid = F.newSid("p3s");
    const t = F.startTurn(sid);
    const a = F.planName(sid, "intent");
    F.writePlan(repo, a, "a1\n");
    F.hookWrite(repo, a, { sid });
    const X = F.bareTip(repo);
    F.check("P3 precondition: X carries the prior turn", F.tipTrailers(repo).turn[0] === t.turn.turnId, JSON.stringify(F.tipTrailers(repo)));
    const input = hookInput(sid);
    delete input.prompt;
    F.check("P3 the next prompt's hook exits 0", F.runNode(HOOK, input).code === 0, "non-zero");
    const next = F.readPromptTurnFile(sid) || {};
    F.check("P3 the next prompt has a new turn id", HEX32.test(String(next.turn_id)) && next.turn_id !== t.turn.turnId, JSON.stringify(next));
    F.writePlan(repo, a, "a2\n");
    F.hookWrite(repo, a, { sid });
    F.check("P3 X survives and the write appends on it", F.bareTip(repo) !== X && F.parentsOf(repo, F.bareTip(repo))[0] === X, F.bareTip(repo));
    F.check("P3 the appended commit carries the new turn", F.tipTrailers(repo).turn[0] === next.turn_id, JSON.stringify(F.tipTrailers(repo)));
  });
  F.guard("P3 unwritable state dir is fail-open", () => {
    const file = `${F.TMP}/state-is-a-file`;
    fs.writeFileSync(file, "x");
    const r = F.runNode(HOOK, hookInput(F.newSid("p3")), { env: { WORKFLOW_STATE_DIR: file } });
    F.check("P3 state dir is a file: exit 0 + {}", r.code === 0 && r.out.trim() === "{}", `code=${r.code} out=${r.out} err=${r.err}`);
  });
  F.guard("P3 invalid sid writes nothing", () => {
    const before = fs.readdirSync(process.env.WORKFLOW_STATE_DIR).length;
    for (const sid of ["../escape", "a b", "x;rm -rf .", "a\nb"]) {
      const r = F.runNode(HOOK, hookInput(sid));
      F.check(`P3 sid ${JSON.stringify(sid)}: exit 0 + {}`, r.code === 0 && r.out.trim() === "{}", `code=${r.code} out=${r.out}`);
    }
    F.check("P3 no control dir created for invalid sids", fs.readdirSync(process.env.WORKFLOW_STATE_DIR).length === before,
      fs.readdirSync(process.env.WORKFLOW_STATE_DIR).join(","));
    F.check("P3 nothing escaped the state dir", !fs.existsSync(path.join(process.env.WORKFLOW_STATE_DIR, "..", "escape.control")), "escape");
  });
  F.guard("P9 rename failure: old turn file is gone, hook still exits 0, no turn resolves", () => {
    const sid = F.newSid("p9");
    F.writePromptTurnFile(sid, { turn_id: "a".repeat(32), created_at: F.iso(Date.now() - 600000) });
    const r = F.runNode(HOOK, hookInput(sid), { nodeArgs: ["--require", F.renameFailPreload()] });
    F.check("P9 exit 0 + {}", r.code === 0 && r.out.trim() === "{}", `code=${r.code} out=${r.out} err=${r.err}`);
    F.check("P9 the previous prompt-turn.json is removed", !fs.existsSync(F.promptTurnPath(sid)), JSON.stringify(F.readPromptTurnFile(sid)));
    F.check("P9 no temp file left behind", tmpLeftovers(sid).length === 0, tmpLeftovers(sid).join(","));
    const L = lib();
    if (!L) return;
    F.check("P9 resolveTurnContext -> null after the failed write", L.resolveTurnContext({ session_id: sid }) === null,
      JSON.stringify(L.resolveTurnContext({ session_id: sid })));
  });
  F.guard("P9b no identifiable target: the hook touches no control file", () => {
    const keep = F.newSid("p9b");
    F.writePromptTurnFile(keep, { turn_id: "c".repeat(32), created_at: F.iso(Date.now() - 1000) });
    const raw0 = readRaw(keep);
    const tree0 = listTree(process.env.WORKFLOW_STATE_DIR);
    const ups = { hook_event_name: "UserPromptSubmit", prompt: "p", transcript_path: F.txPath(keep), cwd: F.DIRS.neutral };
    const cases = [
      ["(a) truncated JSON naming the kept sid", `{"session_id":"${keep}","hook_event_name":"UserPromptSubmit","prompt":"p"`],
      ["(a) non-JSON stdin", "not json at all"], ["(a) empty stdin", ""],
      ["(b) no session_id (transcript_path names the kept sid)", ups],
      ["(c) session_id with a traversal", Object.assign({ session_id: `../${keep}` }, ups)],
      ["(c) session_id with a trailing space", Object.assign({ session_id: `${keep} ` }, ups)],
      ["(c) session_id with a newline", Object.assign({ session_id: `${keep}\n` }, ups)],
      ["(c) session_id with a slash", Object.assign({ session_id: `${keep}/x` }, ups)],
      ["(c) empty session_id", Object.assign({ session_id: "" }, ups)], ["(c) numeric session_id", Object.assign({ session_id: 42 }, ups)],
    ];
    for (const [name, input] of cases) {
      const r = F.runNode(HOOK, input);
      F.check(`P9b ${name}: exit 0 + {}`, r.code === 0 && r.out.trim() === "{}", `code=${r.code} out=${r.out} err=${r.err}`);
      F.check(`P9b ${name}: the kept prompt-turn.json is unchanged`, readRaw(keep) === raw0, String(readRaw(keep)));
      const tree = listTree(process.env.WORKFLOW_STATE_DIR);
      F.check(`P9b ${name}: no file created or removed in the state dir`, JSON.stringify(tree) === JSON.stringify(tree0),
        tree.filter((p) => !tree0.includes(p)).concat(tree0.filter((p) => !tree.includes(p))).join(","));
    }
  });
}));
caseEnd();

caseBegin("P4, P8, P9 writePromptTurn, readPromptTurn and resolveTurnContext", "hooks/lib/prompt-turn-id.js");
test("P4, P8, P9 writePromptTurn, readPromptTurn and resolveTurnContext", () => noNewFailures(F.failureCount, () => {
  F.guard("P4 constants", () => {
    const L = lib();
    if (!L) return;
    F.check("P4 PROMPT_TURN_FILE", L.PROMPT_TURN_FILE === "prompt-turn.json", L.PROMPT_TURN_FILE);
  });
  F.guard("P4 write/read round-trip", () => {
    const L = lib();
    if (!L) return;
    for (const [name, deps] of [["no deps", undefined], ["empty deps", {}]]) {
      const sid = F.newSid("p4");
      const id = L.writePromptTurn(sid, deps);
      F.check(`P4 ${name}: writePromptTurn returns 32 hex`, HEX32.test(String(id)), id);
      const disk = F.readPromptTurnFile(sid);
      F.check(`P4 ${name}: the file holds exactly the id and created_at`, disk && disk.turn_id === id && keysOf(disk) === '["created_at","turn_id"]',
        JSON.stringify(disk));
      const rd = L.readPromptTurn(sid);
      F.check(`P4 ${name}: readPromptTurn -> {turnId, createdAt}`, rd && rd.turnId === id && rd.createdAt === (disk && disk.created_at) &&
        keysOf(rd) === '["createdAt","turnId"]', JSON.stringify(rd));
    }
  });
  F.guard("P4 resolveTurnContext returns the turn whatever transcript_path says", () => {
    const L = lib();
    if (!L) return;
    const sid = F.newSid("p4r");
    const t = F.startTurn(sid);
    const want = JSON.stringify({ sid, turnId: t.turn.turnId });
    const newer = writeFileAt(`${F.TMP}/tx-ignored/${sid}.jsonl`, newerPromptLine("a newer prompt the hook never saw"));
    const variants = [["absent", undefined], ["a missing file", `${F.TMP}/tx-nowhere/${sid}.jsonl`], ["a directory", `${F.TMP}/tx-ignored`],
      ["a transcript with a newer human prompt", newer], ["another session's transcript", writeFileAt(`${F.TMP}/tx-ignored/other.jsonl`, newerPromptLine("x"))]];
    for (const [name, tp] of variants) {
      const input = { session_id: sid };
      if (tp !== undefined) input.transcript_path = tp;
      const got = L.resolveTurnContext(input);
      F.check(`P4 transcript_path ${name} -> {sid, turnId}`, JSON.stringify(got) === want, JSON.stringify(got));
    }
    F.check("P4 resolving twice gives the same turn", JSON.stringify(L.resolveTurnContext({ session_id: sid })) === want, "differs");
  });
  F.guard("P4 corrupt or absent prompt-turn files read as null", () => {
    const L = lib();
    if (!L) return;
    const now = F.iso(Date.now());
    const variants = {
      "bad JSON": "{not json", "JSON null": "null", "JSON array": "[]", "uppercase id": { turn_id: "A".repeat(32), created_at: now },
      "31-char id": { turn_id: "a".repeat(31), created_at: now }, "33-char id": { turn_id: "a".repeat(33), created_at: now },
      "id not a string": { turn_id: 12, created_at: now }, "no turn_id": { created_at: now },
      "bad created_at": { turn_id: "b".repeat(32), created_at: "yesterday-ish" }, "no created_at": { turn_id: "c".repeat(32) },
    };
    for (const [name, body] of Object.entries(variants)) {
      const sid = F.newSid("p4c");
      F.writePromptTurnFile(sid, body);
      F.check(`P4 ${name} -> readPromptTurn null`, L.readPromptTurn(sid) === null, JSON.stringify(L.readPromptTurn(sid)));
      F.check(`P4 ${name} -> resolveTurnContext null`, L.resolveTurnContext({ session_id: sid }) === null, name);
    }
    const missing = F.newSid("p4m");
    F.check("P4 missing file -> readPromptTurn null", L.readPromptTurn(missing) === null, "missing");
    F.check("P4 missing file -> resolveTurnContext null", L.resolveTurnContext({ session_id: missing }) === null, "missing");
  });
  F.guard("P4 no resolvable session -> null", () => {
    const L = lib();
    if (!L) return;
    for (const [name, input] of [["no input", undefined], ["empty input", {}], ["invalid session_id", { session_id: "../x" }]]) {
      F.check(`P4 ${name} -> null`, L.resolveTurnContext(input) === null, JSON.stringify(L.resolveTurnContext(input)));
    }
  });
  F.guard("P8 a subagent transcript_path with the parent's session_id resolves the parent's turn", () => {
    const L = lib();
    if (!L) return;
    const sid = F.newSid("p8");
    const t = F.startTurn(sid);
    const want = JSON.stringify({ sid, turnId: t.turn.turnId });
    const sub = writeFileAt(`${F.TMP}/tx-p8/${sid}/subagents/agent-x.jsonl`, newerPromptLine("subagent task prompt"));
    const got = L.resolveTurnContext({ session_id: sid, transcript_path: sub });
    F.check("P8 subagent path, main transcript absent -> same turn", JSON.stringify(got) === want, JSON.stringify(got));
    writeFileAt(`${F.TMP}/tx-p8/${sid}.jsonl`, newerPromptLine("user typed again"));
    const got2 = L.resolveTurnContext({ session_id: sid, transcript_path: sub });
    F.check("P8 subagent path, main transcript with a newer prompt -> same turn", JSON.stringify(got2) === want, JSON.stringify(got2));
  });
  F.guard("P9 writePromptTurn with a failing rename -> null, the file untouched, no temp left", () => {
    const L = lib();
    if (!L) return;
    const sid = F.newSid("p9l");
    const id1 = L.writePromptTurn(sid);
    F.check("P9 precondition: a first write succeeds", HEX32.test(String(id1)), id1);
    let got;
    let threw = null;
    try { got = L.writePromptTurn(sid, { fs: failingFs() }); } catch (e) { threw = e; }
    F.check("P9 failing rename -> returns null (does not throw)", threw === null && got === null, threw ? threw.message : got);
    F.check("P9 the file still holds the first id", (F.readPromptTurnFile(sid) || {}).turn_id === id1, JSON.stringify(F.readPromptTurnFile(sid)));
    F.check("P9 no temp file left behind", tmpLeftovers(sid).length === 0, tmpLeftovers(sid).join(","));
  });
}));
caseEnd();
