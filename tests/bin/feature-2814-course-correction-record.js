"use strict";
// Tests: bin/course-correction-record, bin/lib/course-correction-record/extract.js, bin/lib/course-correction-record/locate.js
// Tags: TL1, course-correction, transcript, upstream-inconsistency, issue-2814, scope:issue-specific, security
// #2814 reopen R6 (T8): `extract --transcript --uuid --out` copies the target real user prompt and
// the 3 real prompts before it (user text, assistant text items only) verbatim into a Markdown
// record, written through a tmp file; `locate --session` finds the transcript by the cwd-encoded
// path, then by scanning. Exit codes: 0 ok, 2 arguments, 3 not found, 1 IO.
// TL3 gap (what this test does NOT catch):
// - a live Claude Code transcript shape drifting from the fixture entries used here.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");

const ROOT = path.resolve(__dirname, "..", "..");
const CLI = path.join(ROOT, "bin", "course-correction-record");
const { encodeCwd } = require(path.join(ROOT, "hooks", "lib", "transcript-paths"));
const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2814ccr-"));
const BASE = path.join(TMP, "projects");
fs.mkdirSync(BASE);
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

function run(args, opts = {}) {
  const env = { ...process.env, CLAUDE_TRANSCRIPT_BASE_DIR: opts.base || BASE };
  delete env.CLAUDE_CODE_SESSION_ID;
  return spawnSync(process.execPath, [CLI, ...args], { encoding: "utf8", env, cwd: opts.cwd || TMP, timeout: 60000 });
}
const uid = (n) => `${String(n).padStart(8, "0")}-2222-4333-8444-555555555555`;
let tick = 0;
const ts = () => `2026-10-01T00:00:${String(tick++).padStart(2, "0")}Z`;
const user = (n, content, extra = {}) => ({ type: "user", uuid: uid(n), timestamp: ts(), message: { role: "user", content }, ...extra });
const asst = (n, content, extra = {}) => ({ type: "assistant", uuid: uid(n), timestamp: ts(), message: { role: "assistant", content }, ...extra });

// Texts carrying characters a re-encoding would change: unicode, backticks, CRLF-free multi-line.
const P = [
  "P1 first prompt — out of range when the target is P5",
  "P2 second prompt: keep `the stop` «exact»",
  "P3 third prompt\nwith a second line\n  and indentation",
  "P4 fourth prompt (array text item)",
  "P5 drop the stop; re-delegate the planner right away — \u{65E5}\u{672C}\u{8A9E}\u{3082}\u{539F}\u{6587}\u{306E}\u{307E}\u{307E}",
];
const A = ["A1 reply before P2", "A2 reply in range", "A3 reply\nover two lines", "A4 reply before the target"];
const DROP = ["TOOLUSE-MARK", "TOOLRESULT-MARK", "THINKING-MARK", "ISMETA-MARK", "COMPACT-MARK", "SIDECHAIN-USER-MARK", "SIDECHAIN-ASST-MARK"];
const entries = [
  user(1, P[0]),
  asst(2, [{ type: "text", text: A[0] }]),
  user(3, P[1]),
  asst(4, [{ type: "thinking", thinking: "THINKING-MARK" }, { type: "text", text: A[1] }, { type: "tool_use", id: "t1", name: "Bash", input: { command: "echo TOOLUSE-MARK" } }]),
  user(5, [{ type: "tool_result", tool_use_id: "t1", content: "TOOLRESULT-MARK" }]),
  user(6, "ISMETA-MARK", { isMeta: true }),
  user(7, P[2]),
  user(8, "SIDECHAIN-USER-MARK", { isSidechain: true }),
  asst(9, [{ type: "text", text: "SIDECHAIN-ASST-MARK" }], { isSidechain: true }),
  asst(10, [{ type: "text", text: A[2] }]),
  user(11, "COMPACT-MARK", { isCompactSummary: true }),
  user(12, [{ type: "text", text: P[3] }]),
  asst(13, [{ type: "text", text: A[3] }]),
  user(14, P[4]),
  asst(15, [{ type: "text", text: "A5 reply after the target" }]),
];
const TR = path.join(TMP, "fixture.jsonl");
fs.writeFileSync(TR, `${entries.slice(0, 7).map((e) => JSON.stringify(e)).join("\n")}\n{"type":"user","broken\n${entries.slice(7).map((e) => JSON.stringify(e)).join("\n")}\n`);

let outSeq = 0;
function extract(uuid, transcript = TR) {
  const dir = path.join(TMP, `out-${++outSeq}`);
  fs.mkdirSync(dir);
  const out = path.join(dir, "record.md");
  const r = run(["extract", "--transcript", transcript, "--uuid", uuid, "--out", out]);
  return { r, out, dir, body: fs.existsSync(out) ? fs.readFileSync(out, "utf8") : null };
}
const headings = (body) => body.split("\n").filter((l) => /^## (user|assistant) /.test(l)).map((l) => l.split(" ")[1]);

caseBegin("extract-range-and-verbatim-text", "bin/lib/course-correction-record/extract.js");
test("(1) the target and the 3 real prompts before it, texts byte-equal to the source", () => {
  assert.ok(fs.existsSync(CLI), "bin/course-correction-record exists");
  const { r, body } = extract(uid(14));
  assert.strictEqual(r.status, 0, `exit 0 (stderr: ${r.stderr})`);
  assert.ok(body !== null, "the record file is written");
  const lines = body.split("\n");
  assert.strictEqual(lines[0], "# Course correction record");
  assert.ok(lines.some((l) => l.startsWith("- transcript: ")), "a transcript line");
  assert.ok(lines.includes(`- uuid: ${uid(14)}`), "the uuid line");
  for (const t of [P[1], P[2], P[3], P[4], A[1], A[2], A[3]]) assert.ok(body.includes(`\n${t}\n`), `verbatim: ${t}`);
  for (const t of [P[0], A[0], "A5 reply after the target"]) assert.ok(!body.includes(t), `out of range: ${t}`);
  assert.deepStrictEqual(headings(body), ["user", "assistant", "user", "assistant", "user", "assistant", "user"]);
  assert.ok(lines.includes(`## user ${entries[13].timestamp}`), "the target heading carries its timestamp");
});
caseEnd();

caseBegin("extract-drops-non-text-entries", "bin/lib/course-correction-record/extract.js");
test("(2) tool_use, tool_result, thinking, isMeta, compact summary and sidechain are dropped", () => {
  const { r, body } = extract(uid(14));
  assert.strictEqual(r.status, 0, `exit 0 (stderr: ${r.stderr})`);
  for (const m of DROP) assert.ok(!body.includes(m), `dropped: ${m}`);
});
caseEnd();

caseBegin("extract-short-history-starts-at-first", "bin/lib/course-correction-record/extract.js");
test("(3) fewer than 3 earlier prompts: the range starts at the first prompt", () => {
  const { r, body } = extract(uid(7));
  assert.strictEqual(r.status, 0, `exit 0 (stderr: ${r.stderr})`);
  for (const t of [P[0], A[0], P[1], A[1], P[2]]) assert.ok(body.includes(`\n${t}\n`), `in range: ${t}`);
  for (const t of [A[2], P[3]]) assert.ok(!body.includes(t), `after the target: ${t}`);
  assert.deepStrictEqual(headings(body), ["user", "assistant", "user", "assistant", "user"]);
});
caseEnd();

caseBegin("extract-not-found-exit-3", "bin/lib/course-correction-record/extract.js");
test("(4) a uuid on a tool_result / meta / sidechain / compact summary entry, or no such uuid: exit 3, no file", () => {
  for (const u of [uid(5), uid(6), uid(8), uid(10), uid(11), uid(99)]) {
    const { r, out } = extract(u);
    assert.strictEqual(r.status, 3, `${u}: exit 3 (stderr: ${r.stderr})`);
    assert.ok(!fs.existsSync(out), `${u}: no record file`);
  }
});
caseEnd();

caseBegin("extract-skips-broken-lines", "bin/lib/course-correction-record/extract.js");
test("(5) a broken JSON line is skipped and the rest still parses", () => {
  assert.ok(fs.readFileSync(TR, "utf8").includes('{"type":"user","broken\n'), "the fixture has a broken line (precondition)");
  const { r, body } = extract(uid(12));
  assert.strictEqual(r.status, 0, `exit 0 (stderr: ${r.stderr})`);
  assert.ok(body.includes(`\n${P[3]}\n`), "the target after the broken line is found");
});
caseEnd();

caseBegin("cli-argument-errors-exit-2", "bin/course-correction-record");
test("(6) a missing option, an option without a value or an unknown subcommand exits 2", () => {
  const out = path.join(TMP, "never.md");
  const cases = [
    ["extract", "--uuid", uid(14), "--out", out],
    ["extract", "--transcript", TR, "--out", out],
    ["extract", "--transcript", TR, "--uuid", uid(14)],
    ["extract", "--transcript", TR, "--uuid"],
    ["bogus"],
    [],
    ["locate"],
  ];
  for (const a of cases) assert.strictEqual(run(a).status, 2, `exit 2 for: ${a.join(" ") || "<none>"}`);
  assert.ok(!fs.existsSync(out), "no file is written");
});
caseEnd();

caseBegin("extract-leaves-no-tmp-file", "bin/lib/course-correction-record/extract.js");
test("(7) after a write only the record is left in the output directory", () => {
  const { r, dir } = extract(uid(14));
  assert.strictEqual(r.status, 0, `exit 0 (stderr: ${r.stderr})`);
  assert.deepStrictEqual(fs.readdirSync(dir), ["record.md"]);
  const again = run(["extract", "--transcript", TR, "--uuid", uid(14), "--out", path.join(dir, "record.md")]);
  assert.strictEqual(again.status, 0, "a rewrite of the same record exits 0 (idempotent)");
  assert.deepStrictEqual(fs.readdirSync(dir), ["record.md"]);
});
caseEnd();

caseBegin("extract-io-failure-exit-1", "bin/lib/course-correction-record/extract.js");
test("(7b) an unwritable output (missing parent, or a directory on the out path): exit 1, no tmp left", () => {
  // Without the CLI node itself exits 1 (module not found): pin its presence first.
  assert.ok(fs.existsSync(CLI), "bin/course-correction-record exists (precondition)");
  const missing = path.join(TMP, "no-such-dir", "record.md");
  const r1 = run(["extract", "--transcript", TR, "--uuid", uid(14), "--out", missing]);
  assert.strictEqual(r1.status, 1, `missing parent: exit 1 (stderr: ${r1.stderr})`);
  assert.ok(!fs.existsSync(path.dirname(missing)), "missing parent: nothing is created");
  const dir = path.join(TMP, `out-${++outSeq}`);
  const squat = path.join(dir, "record.md");
  fs.mkdirSync(squat, { recursive: true });
  const r2 = run(["extract", "--transcript", TR, "--uuid", uid(14), "--out", squat]);
  assert.strictEqual(r2.status, 1, `rename onto a directory: exit 1 (stderr: ${r2.stderr})`);
  assert.deepStrictEqual(fs.readdirSync(dir), ["record.md"], "rename failure: no tmp file left beside the out path");
  assert.deepStrictEqual(fs.readdirSync(squat), [], "rename failure: nothing written into the squatting directory");
});
caseEnd();

caseBegin("locate-cwd-path-then-discover", "bin/lib/course-correction-record/locate.js");
test("(8) locate: the cwd-encoded path, then the scan; not found 3; an invalid sid 2", () => {
  const sidA = "aaaaaaaa-1111-4222-8333-444444444444";
  const sidB = "bbbbbbbb-1111-4222-8333-444444444444";
  const cwd = fs.realpathSync(fs.mkdtempSync(path.join(TMP, "cwd-")));
  const pa = path.join(BASE, encodeCwd(cwd), `${sidA}.jsonl`);
  fs.mkdirSync(path.dirname(pa), { recursive: true });
  fs.writeFileSync(pa, "{}\n");
  const pb = path.join(BASE, "some-other-project", `${sidB}.jsonl`);
  fs.mkdirSync(path.dirname(pb), { recursive: true });
  fs.writeFileSync(pb, "{}\n");
  const norm = (s) => path.resolve(String(s).trim()).toLowerCase();
  let r = run(["locate", "--session", sidA], { cwd });
  assert.strictEqual(r.status, 0, `cwd path: exit 0 (stderr: ${r.stderr})`);
  assert.strictEqual(norm(r.stdout), norm(pa));
  assert.strictEqual(r.stdout.trim().split("\n").length, 1, "one line");
  r = run(["locate", "--session", sidB], { cwd });
  assert.strictEqual(r.status, 0, `discover: exit 0 (stderr: ${r.stderr})`);
  assert.strictEqual(norm(r.stdout), norm(pb));
  r = run(["locate", "--session", "cccccccc-1111-4222-8333-444444444444"], { cwd });
  assert.strictEqual(r.status, 3, "not found: exit 3");
  assert.strictEqual(r.stdout, "", "not found: no output");
  for (const bad of ["../escape", "a b", ""]) assert.strictEqual(run(["locate", "--session", bad], { cwd }).status, 2, `invalid sid '${bad}': exit 2`);
});
caseEnd();

// security-scanner F1: a task-notification is a type:"user" entry the user never typed — a string
// starting with the tag, or origin.kind "task-notification". It is never a target nor a prior prompt.
const R = ["R0 oldest real prompt, out of range", "R1 earliest real prompt in range", "R2 second real prompt", "R3 third real prompt", "T  target real prompt"];
const NOTIF_STR = "<task-notification>\n<task-id>bg1</task-id>\nNOTIF-STRING-MARK\n</task-notification>";
const NOTIF_ORIGIN = "NOTIF-ORIGIN-MARK background task finished";
const ORDINARY = "Why does a <task-notification> tag show up in the middle of my prompt?";
const notifEntries = [
  user(101, R[0]), asst(102, [{ type: "text", text: "reply to R0" }]),
  user(103, R[1]), user(104, R[2]),
  user(114, "\n  <task-notification>LEADWS-PRIOR-MARK</task-notification>"),
  user(115, [{ type: "text", text: "<task-notification>ARRAYTAG-PRIOR-MARK</task-notification>" }]),
  user(105, NOTIF_STR),
  user(106, R[3]),
  user(107, [{ type: "text", text: NOTIF_ORIGIN }], { origin: { kind: "task-notification" } }),
  asst(108, [{ type: "text", text: "reply before the target" }]),
  user(109, R[4]),
  user(110, ORDINARY),
  user(111, " \n<task-notification>\nLEADWS-MARK\n</task-notification>"),
  user(112, [{ type: "text", text: "<task-notification>\nARRAYTAG-MARK\n</task-notification>" }]),
  user(113, "ORIGIN-USER prompt typed by the user", { origin: { kind: "user" } }),
  user(116, [{ type: "image", source: { type: "base64", media_type: "image/png", data: "iVBORw0KGgo=" } }, { type: "text", text: "<task-notification>IMAGEFIRST-MARK</task-notification>" }]),
];
const TRN = path.join(TMP, "notif.jsonl");
fs.writeFileSync(TRN, `${notifEntries.map((e) => JSON.stringify(e)).join("\n")}\n`);

caseBegin("extract-notification-uuid-not-a-target", "bin/lib/course-correction-record/extract.js");
test("(9) F1: a target uuid on a task-notification (string tag, or origin.kind): exit 3, no file", () => {
  const cases = [
    [uid(105), "string content starting with <task-notification>"], [uid(107), "origin.kind task-notification"],
    [uid(111), "the tag after leading whitespace and a newline"], [uid(112), "an array text item starting with the tag, no origin"],
    [uid(116), "an image item first, then a text item starting with the tag"],
  ];
  for (const [u, label] of cases) {
    const { r, out } = extract(u, TRN);
    assert.strictEqual(r.status, 3, `${label}: exit 3 (stderr: ${r.stderr})`);
    assert.ok(!fs.existsSync(out), `${label}: no record file`);
  }
});
caseEnd();

caseBegin("extract-notification-not-a-prior-prompt", "bin/lib/course-correction-record/extract.js");
test("(10) F1: the 3 prior prompts are the 3 prior REAL prompts; notifications are not counted", () => {
  const { r, body } = extract(uid(109), TRN);
  assert.strictEqual(r.status, 0, `exit 0 (stderr: ${r.stderr})`);
  for (const t of [R[1], R[2], R[3], R[4]]) assert.ok(body.includes(`\n${t}\n`), `in range: ${t}`);
  assert.ok(!body.includes(R[0]), "a 4th earlier real prompt stays out of range");
  for (const m of ["NOTIF-STRING-MARK", "NOTIF-ORIGIN-MARK", "LEADWS-PRIOR-MARK", "ARRAYTAG-PRIOR-MARK", "<task-notification>"]) assert.ok(!body.includes(m), `notification text is not in the record: ${m}`);
  assert.strictEqual(headings(body).filter((h) => h === "user").length, 4, "one user heading per real prompt (R1, R2, R3, target)");
});
caseEnd();

caseBegin("extract-ordinary-prompt-mentioning-tag-accepted", "bin/lib/course-correction-record/extract.js");
test("(11) F1 counterpart: the tag mid-text, or an origin.kind other than task-notification, is still a target", () => {
  for (const [u, text] of [[uid(110), ORDINARY], [uid(113), "ORIGIN-USER prompt typed by the user"]]) {
    const { r, body } = extract(u, TRN);
    assert.strictEqual(r.status, 0, `${u}: exit 0 (stderr: ${r.stderr})`);
    assert.ok(body.includes(`\n${text}\n`), `${u}: the prompt is quoted verbatim`);
  }
});
caseEnd();

// security-scanner F3: each entry body sits in a backtick fence of max(3, longest run + 1), so a
// body line never becomes a heading. fenced(body) -> {headings outside fences, entries [{fence, text}]}.
function fenced(body) {
  const lines = body.split("\n");
  const res = { headings: 0, entries: [] };
  for (let i = 0; i < lines.length; i++) {
    if (!lines[i].startsWith("## ")) continue;
    res.headings++;
    const m = /^(`{3,})[^`]*$/.exec(lines[i + 1] || "");
    if (!m) { res.entries.push({ fence: "", text: null }); continue; }
    const close = lines.indexOf(m[1], i + 2);
    if (close < 0) { res.entries.push({ fence: m[1], text: null }); break; }
    res.entries.push({ fence: m[1], text: lines.slice(i + 2, close).join("\n") });
    i = close;
  }
  return res;
}
const INJECT = "F3 heading injection\n## user 2026-01-01\nforged prompt the user never typed";
const TICKS = "F3 body with a fence\n```\nmid\n```\nafter the fence";
const PLAIN = "F3 plain target";
const RUN4 = "F3 inline ````four```` run, not at line start";
const TOOL_ONLY = asst(204, [{ type: "tool_use", id: "t2", name: "Bash", input: { command: "true" } }]);
const SHORT_THEN_LONG = "a ``` b\n`````\n## user 2026-01-01 forged";
const fenceEntries = [user(201, INJECT), asst(202, [{ type: "text", text: TICKS }]), TOOL_ONLY, asst(205, [{ type: "text", text: RUN4 }]), asst(206, [{ type: "text", text: SHORT_THEN_LONG }]), user(203, PLAIN)];
const TRF = path.join(TMP, "fence.jsonl");
fs.writeFileSync(TRF, `${fenceEntries.map((e) => JSON.stringify(e)).join("\n")}\n`);

caseBegin("extract-fence-blocks-heading-injection", "bin/lib/course-correction-record/extract.js");
test("(12) F3: a body line '## user ...' stays inside its fence, not a heading", () => {
  const { r, body } = extract(uid(203), TRF);
  assert.strictEqual(r.status, 0, `exit 0 (stderr: ${r.stderr})`);
  const f = fenced(body);
  assert.strictEqual(f.headings, 5, "only the 5 rendered entries are headings outside fences");
  assert.strictEqual(f.entries[0].text, INJECT, "the injected line round-trips inside the first entry's fence");
});
caseEnd();

caseBegin("extract-fence-longer-than-body-run", "bin/lib/course-correction-record/extract.js");
test("(13) F3: a body holding a ``` run gets a 4-backtick fence and round-trips verbatim", () => {
  const { r, body } = extract(uid(203), TRF);
  assert.strictEqual(r.status, 0, `exit 0 (stderr: ${r.stderr})`);
  const e = fenced(body).entries[1] || {};
  assert.strictEqual(e.fence, "````", "fence = longest run (3) + 1");
  assert.strictEqual(e.text, TICKS, "the body is verbatim inside the fence");
});
caseEnd();

caseBegin("extract-fence-plain-body-three-ticks", "bin/lib/course-correction-record/extract.js");
test("(14) F3: a plain body gets a fence of exactly 3 backticks", () => {
  const { r, body } = extract(uid(203), TRF);
  assert.strictEqual(r.status, 0, `exit 0 (stderr: ${r.stderr})`);
  assert.deepStrictEqual(fenced(body).entries[4], { fence: "```", text: PLAIN });
});
caseEnd();

caseBegin("extract-fence-counts-inline-runs", "bin/lib/course-correction-record/extract.js");
test("(15) F3: a 4-backtick run mid-line gets a 5-backtick fence; an entry with no text renders nothing", () => {
  const { r, body } = extract(uid(203), TRF);
  assert.strictEqual(r.status, 0, `exit 0 (stderr: ${r.stderr})`);
  assert.ok(!body.includes(`## assistant ${TOOL_ONLY.timestamp}`), "the tool-only entry has no heading (kept behavior)");
  assert.deepStrictEqual(fenced(body).entries[2], { fence: "`````", text: RUN4 });
});
caseEnd();

caseBegin("extract-fence-measures-longest-run", "bin/lib/course-correction-record/extract.js");
test("(16) F3: a short run then a longer one: the fence beats the longest (6 backticks), not the first", () => {
  const { r, body } = extract(uid(203), TRF);
  assert.strictEqual(r.status, 0, `exit 0 (stderr: ${r.stderr})`);
  const f = fenced(body);
  assert.deepStrictEqual(f.entries[3], { fence: "``````", text: SHORT_THEN_LONG });
  assert.strictEqual(f.headings, f.entries.length, "headings outside fences = rendered entries");
  assert.strictEqual(f.entries.length, 5, "5 rendered entries");
});
caseEnd();
