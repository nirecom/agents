"use strict";
// Tests: bin/migrate-needs, bin/lib/migrate-needs.js, bin/lib/tracker-fields/expected.js, bin/lib/tracker-fields/backfill.js, bin/pm-state
// Tags: TL2, scope:issue-specific, pm-session, pm-field, migrate, issue-3135
// #3135 the /migrate path through the real code, the forge faked at the gh binary (board mode of fake-gh.js):
// migrate-needs reports migrate-tracker for a tracker-done board without `pm`; the backend step the sub-skill
// runs (assumed: run-issue-setup.sh --step repair) prepares the board, judges again and backfills; then
// bin/pm-state owner answers the holder. ensure-project-ready.sh takes its field names from EXPECTED_FIELDS.
// TL3 gap (what this test does NOT catch):
// - the real GitHub board API, and the model following /migrate and /migrate-tracker SKILL.md.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const assert = require("node:assert");
const cp = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test, after } = require("node:test");

const restore = isolate();
const X = require("../lib/pm-s3-fixture");
const { P, G } = X;
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "pm-migrate-path-"));
after(() => { fs.rmSync(tmp, { recursive: true, force: true }); restore(); });

const STATUS = { id: "PVTF_Status", name: "Status", dataType: "SINGLE_SELECT", options: ["Todo", "In Progress", "Done"].map((name) => ({ id: `OPT_${name}`, name })) };
const NO_PM = [{ id: "PVTF_Content_Date", name: "Content Date", dataType: "DATE" }, STATUS, { id: "PVTF_session_id", name: "session-id", dataType: "TEXT" }];
const WITH_PM = NO_PM.concat([{ id: "PVTF_pm", name: "pm", dataType: "TEXT" }]);
const boardFile = path.join(tmp, "board.json");
const setBoard = (fields) => { fs.writeFileSync(boardFile, JSON.stringify({ fields })); process.env.PM_FAKE_GH_BOARD = boardFile; };
const boardNames = () => JSON.parse(fs.readFileSync(boardFile, "utf8")).fields.map((f) => f.name);
const item = (num) => `PVTI_o_r_${num}`;
const brief = (r) => `${r.status}\n${r.stdout}\n${r.stderr}`.slice(0, 1500);
let n = 0;

function env(extra) {
  const e = Object.assign({}, process.env, extra || {});
  delete e.CLAUDE_CODE_SESSION_ID;
  return e;
}
// repo() -> a fresh checkout whose origin is o/r and whose .agents.json records migrate.tracker done.
function repo() {
  const dir = path.join(tmp, `repo-${++n}`);
  fs.mkdirSync(dir);
  gitInit(dir);
  cp.spawnSync("git", ["-C", dir, "remote", "add", "origin", "https://github.com/o/r.git"], { encoding: "utf8", timeout: 20000 });
  const r = cp.spawnSync(process.execPath, [path.join(P.ROOT, "bin", "repo-settings"), "--root", dir, "--set-migrate", "tracker"], { encoding: "utf8", env: env(), timeout: 30000 });
  assert.strictEqual(r.status, 0, brief(r));
  return dir;
}
function needed(dir) {
  const r = cp.spawnSync(process.execPath, [path.join(P.ROOT, "bin", "migrate-needs"), "--root", dir], { encoding: "utf8", env: env(), timeout: 60000 });
  assert.strictEqual(r.status, 0, brief(r));
  const m = /^NEEDED=(.*)$/m.exec(r.stdout);
  return m ? m[1].trim().split(",").filter(Boolean) : [];
}
const repair = (dir, extra) => cp.spawnSync("bash", [P.fwd(path.join(P.ROOT, "skills", "migrate-tracker", "scripts", "run-issue-setup.sh")),
  "--step", "repair", "--repo", "o/r", "--root", P.fwd(dir), "--no-push"], { encoding: "utf8", env: env(extra), timeout: 150000 });
function owner(dir, num) {
  const r = cp.spawnSync("bash", ["-c", '"$0" "$@"', P.fwd(path.join(P.ROOT, "bin", "pm-state")), "owner", "--issue", `#${num}`], { cwd: dir, encoding: "utf8", env: env(), timeout: 60000 });
  try { return JSON.parse(String(r.stdout).trim()); } catch (_) { return { raw: brief(r) }; }
}
const holder = (tag, nums) => { const s = P.uuid(0x31355000 + (++n)); P.seedPm(s, P.pm({ tag, issues: nums.map((number) => ({ number, repo: "o/r" })) })); return s; };

caseBegin("migrate-hub-repair-path", "bin/lib/migrate-needs.js");
test("M1 a tracker-done board without pm: migrate-needs lists migrate-tracker, the repair step fixes it, owner answers the holder", () => {
  const dir = repo();
  setBoard(NO_PM);
  G.setMap({ "o/r#9301": {} });
  const s = holder("PM-m1", [9301]);
  assert.ok(needed(dir).includes("migrate-tracker"), "the hub never runs migrate-tracker for a board without pm");
  const r = repair(dir);
  assert.strictEqual(r.status, 0, brief(r));
  assert.ok(boardNames().includes("pm"), `the board was not prepared: ${boardNames()}`);
  assert.strictEqual(G.pmStore()[item(9301)], "PM-m1", `not backfilled: ${JSON.stringify(G.pmStore())}`);
  assert.deepStrictEqual(owner(dir, 9301), { tag: "PM-m1", session_id: s });
  assert.ok(!needed(dir).includes("migrate-tracker"), "migrate-tracker is still listed after the repair");
});
test("M2 the migrate-tracker skill runs the repair step for a tracker-done repo", () => {
  const md = fs.readFileSync(path.join(P.ROOT, "skills", "migrate-tracker", "SKILL.md"), "utf8");
  assert.match(md, /--step repair\b/, "migrate-tracker SKILL.md never runs run-issue-setup.sh --step repair");
});
test("M3 field present but unbackfilled: not NEEDED for the hub", () => {
  const dir = repo();
  setBoard(WITH_PM);
  G.setMap({ "o/r#9302": {} });
  holder("PM-m3", [9302]);
  assert.ok(!needed(dir).includes("migrate-tracker"), "an unbackfilled board alone made migrate-tracker NEEDED");
});
test("M4 (b) an explicit repair run backfills an unbackfilled board without preparing it", () => {
  const dir = repo();
  setBoard(WITH_PM);
  G.setMap({ "o/r#9303": {} });
  const s = holder("PM-m4", [9303]);
  const before = G.queries().length;
  const r = repair(dir);
  assert.strictEqual(r.status, 0, brief(r));
  assert.ok(!G.queries().slice(before).some((q) => /createProjectV2Field/.test(q)), "the board was prepared again");
  assert.strictEqual(G.pmStore()[item(9303)], "PM-m4");
  assert.deepStrictEqual(owner(dir, 9303), { tag: "PM-m4", session_id: s });
});
test("M5 the pm field cannot be created: the repair step fails and writes no field value", () => {
  const dir = repo();
  setBoard(NO_PM);
  G.setMap({ "o/r#9304": {} });
  holder("PM-m5", [9304]);
  const r = repair(dir, { PM_FAKE_GH_BOARD_FAIL: "create" });
  assert.notStrictEqual(r.status, 0, brief(r));
  assert.doesNotMatch(r.stderr, /unknown --step/, brief(r));
  assert.ok(!(item(9304) in G.pmStore()), "a value was written to a board without the field");
});
caseEnd();

caseBegin("expected-fields-drive-preparation", "bin/lib/tracker-fields/expected.js");
// prepare(root) -> the field names ensure_project_ready (from root's tree) leaves on an empty board.
function prepare(root) {
  setBoard([]);
  const script = P.fwd(path.join(root, "bin", "github-issues", "lib", "ensure-project-ready.sh"));
  const r = cp.spawnSync("bash", ["-c", '. "$0" && ensure_project_ready o/r', script], { encoding: "utf8", env: env({ AGENTS_MAIN_ROOT: P.fwd(root) }), timeout: 120000 });
  assert.strictEqual(r.status, 0, brief(r));
  return boardNames();
}
test("F3 an empty board is prepared with exactly the fields EXPECTED_FIELDS names", () => {
  const table = P.load("bin/lib/tracker-fields/expected.js").EXPECTED_FIELDS;
  assert.ok(Array.isArray(table), "EXPECTED_FIELDS is not an array");
  assert.deepStrictEqual(prepare(P.ROOT).slice().sort(), table.map((f) => f.name).sort());
});
test("F4 renaming pm in a copy of EXPECTED_FIELDS renames the field the copy's preparation creates", () => {
  const mirror = path.join(tmp, "mirror");
  for (const d of ["bin", path.join("hooks", "lib")]) fs.cpSync(path.join(P.ROOT, d), path.join(mirror, d), { recursive: true });
  const file = path.join(mirror, "bin", "lib", "tracker-fields", "expected.js");
  assert.ok(fs.existsSync(file), "bin/lib/tracker-fields/expected.js does not exist");
  const src = fs.readFileSync(file, "utf8");
  const swapped = src.replace(/(["'])pm\1/g, '"pm-swapped"');
  assert.notStrictEqual(swapped, src, "expected.js does not spell the pm field name");
  fs.writeFileSync(file, swapped);
  const names = prepare(mirror);
  assert.ok(names.includes("pm-swapped") && !names.includes("pm"), `the preparation ignored the table: ${names}`);
});
caseEnd();
