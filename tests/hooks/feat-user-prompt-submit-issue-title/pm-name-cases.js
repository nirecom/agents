"use strict";
// PM naming cases of tests/hooks/feat-user-prompt-submit-issue-title.js (#2941): a session with the
// PM mark is named "[PM] <tag>: #A #B <title of #A> sid-xxxxxxxx"; with 0 refs or archived, by its
// objective and without a forge fetch; a changed assignment renames it. No case markers.
// The `pm` key is seeded raw (tests/lib/pm-state-fixture.js). run() may return the name string or
// an object carrying sessionTitle once the writer shares the entry; nameOf accepts both.
const assert = require("node:assert");
const { test } = require("node:test");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");
const P =require("../../lib/pm-state-fixture");

const os = require("node:os");
const { sfx } = require("./name-cases");
// inFreshDirs(fn) — fn runs with both workflow dirs at fresh empty temp dirs, so no other PM's
// state is visible (the writer's overlap check would otherwise ask the forge about them).
function inFreshDirs(fn) {
  const saved = [process.env.WORKFLOW_STATE_DIR, process.env.WORKFLOW_PLANS_DIR];
  const base = fs.mkdtempSync(path.join(os.tmpdir(), "pm-name-fresh-"));
  process.env.WORKFLOW_STATE_DIR = path.join(base, "state");
  process.env.WORKFLOW_PLANS_DIR = path.join(base, "plans");
  for (const d of [process.env.WORKFLOW_STATE_DIR, process.env.WORKFLOW_PLANS_DIR]) fs.mkdirSync(d);
  try { return fn(); } finally {
    [process.env.WORKFLOW_STATE_DIR, process.env.WORKFLOW_PLANS_DIR] = saved;
    fs.rmSync(base, { recursive: true, force: true });
  }
}
function nameOf(r) {
  if (typeof r === "string") return r;
  if (!r || typeof r !== "object") return r;
  if (typeof r.sessionTitle === "string") return r.sessionTitle;
  const h = r.hookSpecificOutput;
  return h && typeof h.sessionTitle === "string" ? h.sessionTitle : r;
}

function pmNames(F) {
  const seedPm = (pmValue) => {
    const sid = crypto.randomUUID();
    F.seed(sid);
    const p = F.WS.getStatePath(sid);
    const st = JSON.parse(fs.readFileSync(p, "utf8"));
    st.pm = pmValue;
    fs.writeFileSync(p, JSON.stringify(st));
    return { sid, p };
  };
  const setIssues = (p, nums) => {
    const st = JSON.parse(fs.readFileSync(p, "utf8"));
    st.pm.issues = nums.map((n) => ({ number: n }));
    fs.writeFileSync(p, JSON.stringify(st));
  };

  test("P1 an active PM with refs is named by its tag, refs and the title of #A only", () => {
    const { sid } = seedPm(P.pm({ issues: [2728, 2927] }));
    const d = F.deps();
    assert.strictEqual(nameOf(F.call(sid, "hello", d)), `[PM] PM-infra: #2728 #2927 Title2728${sfx(sid)}`);
    assert.deepStrictEqual(d.fetchCalls.map((r) => r.number), [2728]);
  });
  test("P2 an active PM with 0 refs is named by its objective and fetches nothing", () => {
    const { sid } = seedPm(P.pm({ issues: [], objective: "theme" }));
    const d = F.deps();
    assert.strictEqual(nameOf(F.call(sid, "hello", d)), `[PM] PM-infra: theme${sfx(sid)}`);
    assert.deepStrictEqual(d.fetchCalls, []);
  });
  test("P3 an archived PM is named by its objective even when issues remain recorded", () => {
    const { sid } = seedPm(P.pm({ issues: [2728], objective: "finished PM", archived_at: "2026-11-02T00:00:00.000Z" }));
    const d = F.deps();
    assert.strictEqual(nameOf(F.call(sid, "hello", d)), `[PM] PM-infra: finished PM${sfx(sid)}`);
    assert.deepStrictEqual(d.fetchCalls, []);
  });
  test("P4 a changed assignment gives a new name on the next prompt", () => {
    const { sid, p } = seedPm(P.pm({ issues: [2728] }));
    assert.strictEqual(nameOf(F.call(sid, "hello", F.deps())), `[PM] PM-infra: #2728 Title2728${sfx(sid)}`);
    setIssues(p, [2728, 3000]);
    assert.strictEqual(nameOf(F.call(sid, "hello again", F.deps())), `[PM] PM-infra: #2728 #3000 Title2728${sfx(sid)}`);
  });
  // #2942: the neutral cwd has no origin, so a bare #N cannot be given a repo and is refused
  // (normalizeRef); the ref carries its repo, and with no GitHub origin no PM field is written.
  test("P5 a typed /pm-init is written before naming, so its own prompt gets the PM name", () => {
    inFreshDirs(() => {
      const sid = crypto.randomUUID();
      F.seed(sid);
      // A non-GitHub origin lets the ownership check resolve the origin (no fail-closed refusal)
      // while skipping the PM field write, so no gh call is made.
      const d = F.deps();
      d.spawnSync = (cmd, args, opts) => {
        d.spawnCalls.push({ cmd, args, opts });
        return cmd === "git" ? { status: 0, stdout: "https://gitlab.example.com/example/repo.git\n", stderr: "" } : { status: 1, stdout: "", stderr: "stub" };
      };
      const r = F.call(sid, F.wrapped("pm-init", "PM-name5 example/repo#55 theme"), d);
      assert.strictEqual(nameOf(r), `[PM] PM-name5: example/repo#55 Title55${sfx(sid)}`, JSON.stringify(r));
      assert.strictEqual(F.spawned(d, "gh").length, 0, F.cmds(d));
    });
  });
  test("P5b a /pm-init whose bare #N has no resolvable repo is refused and names nothing", () => {
    inFreshDirs(() => {
      const sid = crypto.randomUUID();
      F.seed(sid);
      const T = require(F.ENTRY);
      const r = T.respond(F.input(sid, F.wrapped("pm-init", "PM-name5b #55 theme")), F.deps());
      assert.ok(typeof r.block === "string" && /repo/i.test(r.block), JSON.stringify(r));
      assert.strictEqual(r.title, null, JSON.stringify(r));
      assert.strictEqual(JSON.parse(fs.readFileSync(F.WS.getStatePath(sid), "utf8")).pm, undefined, "the refused session gets no pm");
    });
  });
}

// pmOutput(F) — the entry's stdout wiring in the real hook process: a refused /pm-init gives
// {decision:"block", reason}; an accepted one gives additionalContext next to sessionTitle; a
// throwing writer is fail-open (naming continues). The throw is injected by a --require preload that
// replaces any require of pm-session/writer and leaves a mark file, so the case proves it fired.
function pmOutput(F) {
  const seedPm = (pmValue) => {
    const sid = crypto.randomUUID();
    F.seed(sid);
    const p = F.WS.getStatePath(sid);
    const st = JSON.parse(fs.readFileSync(p, "utf8"));
    st.pm = pmValue;
    fs.writeFileSync(p, JSON.stringify(st));
    return sid;
  };
  const tmp = path.dirname(F.neutral);
  const preload = path.join(tmp, "pm-writer-throws.js");
  const mark = path.join(tmp, "pm-writer-throws.mark");
  fs.writeFileSync(preload, [
    '"use strict";',
    'const M = require("module");',
    "const load = M._load;",
    "M._load = function (req, parent, isMain) {",
    "  if (/(^|[\\\\/])pm-session[\\\\/]writer(\\.js)?$/.test(String(req))) {",
    "    return { runPmWriter() { require(\"fs\").writeFileSync(process.env.PM_WRITER_THROW_MARK, \"fired\"); throw new Error(\"injected writer failure\"); } };",
    "  }",
    "  return load.apply(this, arguments);",
    "};",
  ].join("\n"));
  function hook(sid, prompt, preArgs = [], extraEnv = {}) {
    const env = Object.assign({}, process.env, extraEnv);
    delete env.CLAUDE_CODE_SESSION_ID;
    const stdin = JSON.stringify(F.input(sid, prompt));
    const r = cp.spawnSync(process.execPath, [...preArgs, F.ENTRY], { input: stdin, encoding: "utf8", timeout: 20000, cwd: F.neutral, env });
    let json = null;
    try { json = JSON.parse((r.stdout || "").trim()); } catch (_) { /* asserted below */ }
    return { code: r.status, out: (r.stdout || "").trim(), err: r.stderr || "", json };
  }
  const hso = (j) => (j && j.hookSpecificOutput) || {};

  test("PO1 a refused /pm-init (tag already used, case-insensitive) emits decision:block with a reason", () => {
    seedPm(P.pm({ tag: "PM-taken", issues: [] }));
    const sid = crypto.randomUUID();
    F.seed(sid);
    const r = hook(sid, F.wrapped("pm-init", "pm-taken theme"));
    assert.strictEqual(r.code, 0, r.err);
    assert.ok(r.json, `stdout is not JSON: ${r.out}`);
    assert.strictEqual(r.json.decision, "block", r.out);
    assert.ok(typeof r.json.reason === "string" && r.json.reason.trim() !== "", r.out);
    assert.strictEqual(JSON.parse(fs.readFileSync(F.WS.getStatePath(sid), "utf8")).pm, undefined, "the refused session gets no pm");
  });
  test("PO2 an accepted /pm-init emits additionalContext and sessionTitle in one output", () => {
    const sid = crypto.randomUUID();
    F.seed(sid);
    const r = hook(sid, F.wrapped("pm-init", "PM-wire theme"));
    assert.strictEqual(r.code, 0, r.err);
    assert.ok(r.json, `stdout is not JSON: ${r.out}`);
    assert.notStrictEqual(r.json.decision, "block", r.out);
    const h = hso(r.json);
    assert.strictEqual(h.hookEventName, "UserPromptSubmit", r.out);
    assert.strictEqual(h.sessionTitle, `[PM] PM-wire: theme${sfx(sid)}`, r.out);
    assert.ok(typeof h.additionalContext === "string" && h.additionalContext.startsWith("[pm-session] op=init tag=PM-wire"), r.out);
  });
  // #2942: a writer throw on a PM-command prompt is refused (fail-closed), not passed through.
  test("PO3 a throwing writer on a PM command is refused: exit 0, decision:block with the failure", () => {
    try { fs.rmSync(mark, { force: true }); } catch (_) { /* fresh */ }
    const sid = seedPm(P.pm({ tag: "PM-throw", issues: [], objective: "named even on failure" }));
    const r = hook(sid, F.wrapped("pm-add", "#77 reason"), ["--require", preload], { PM_WRITER_THROW_MARK: mark });
    assert.strictEqual(fs.existsSync(mark), true, `the injected writer never ran: ${r.out} ${r.err}`);
    assert.strictEqual(r.code, 0, r.err);
    assert.ok(r.json, `stdout is not JSON: ${r.out}`);
    assert.strictEqual(r.json.decision, "block", r.out);
    assert.ok(/PM writer failed/.test(r.json.reason || ""), r.out);
    assert.deepStrictEqual(JSON.parse(fs.readFileSync(F.WS.getStatePath(sid), "utf8")).pm.issues, [], "the failed add left the assignment unchanged");
  });
  test("PO4 an accepted /pm-init also emits a top-level systemMessage for the user (#2941 Steps 3)", () => {
    const sid = crypto.randomUUID();
    F.seed(sid);
    const r = hook(sid, F.wrapped("pm-init", "PM-wire4 theme"));
    assert.strictEqual(r.code, 0, r.err);
    assert.ok(r.json, `stdout is not JSON: ${r.out}`);
    assert.ok(typeof r.json.systemMessage === "string" && r.json.systemMessage.trim() !== "", r.out);
    const h = hso(r.json);
    assert.ok(typeof h.additionalContext === "string" && h.additionalContext !== "", r.out);
    assert.strictEqual(h.sessionTitle, `[PM] PM-wire4: theme${sfx(sid)}`, r.out);
  });
}

module.exports = { pmNames, pmOutput };
