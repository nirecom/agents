"use strict";
// Resume cases of tests/hooks/feat-user-prompt-submit-issue-title.js (#2668). No case markers.
// Assumed API: the detail plan does not fix who gives the name again after a resume; it leaves the
// owner to verification (a) (hooks/session-start.js when SessionStart accepts sessionTitle, else the
// first UserPromptSubmit after the resume). So every case asserts each hook's output on its own:
// SessionStart never names on startup, after a /rename, or with an unreadable transcript; the first
// UserPromptSubmit names a new start and stays silent after a /rename or an unreadable transcript.
// The one branch-dependent point is the matching resume: exactly one of the two hooks gives the name
// (the latest custom-title equal to last_emitted), never both and never neither.
const assert = require("node:assert");
const { test } = require("node:test");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");

const { sfx } = require("./name-cases");
const titleRecord = (sid, t) => `${JSON.stringify({ type: "custom-title", sessionId: sid, customTitle: t })}\n`;

function makeResume(F) {
  const base = path.dirname(F.neutral);
  const home = path.join(base, "resume-home");
  fs.mkdirSync(home, { recursive: true });
  const transcript = (sid) => path.join(process.env.CLAUDE_TRANSCRIPT_BASE_DIR, `${sid}.jsonl`);
  // sessionStart(sid, source, tpath) -> the sessionTitle of the real hook (child process), else null.
  function sessionStart(sid, source, tpath) {
    const env = Object.assign({}, process.env, { HOME: home, USERPROFILE: home });
    delete env.CLAUDE_CODE_SESSION_ID;
    const input = JSON.stringify({ session_id: sid, hook_event_name: "SessionStart", source, transcript_path: tpath, cwd: F.neutral });
    const r = cp.spawnSync(process.execPath, [path.join(F.ROOT, "hooks", "session-start.js")], { input, cwd: F.neutral, env, encoding: "utf8", timeout: 30000 });
    assert.strictEqual(r.status, 0, `session-start exit: ${`${r.stderr || ""}${r.error ? String(r.error) : ""}`.slice(0, 400)}`);
    const m = String(r.stdout || "").match(/"sessionTitle"\s*:\s*("(?:[^"\\]|\\.)*")/);
    return m ? JSON.parse(m[1]) : null;
  }
  // prompt(sid, text, tpath) -> the sessionTitle string the UserPromptSubmit run() returns, else null.
  function prompt(sid, text, tpath) {
    let r;
    try { r = require(F.ENTRY).run(Object.assign(F.input(sid, text), { transcript_path: tpath }), F.deps()); } catch (e) { r = { threw: e.message }; }
    assert.ok(!(r && r.threw), `UserPromptSubmit threw: ${r && r.threw}`);
    return typeof r === "string" ? r : null;
  }
  // resume(sid, tpath) -> { ss, ups }: SessionStart (resume) output, then the first prompt's output.
  function resume(sid, tpath) {
    const ss = sessionStart(sid, "resume", tpath);
    return { ss, ups: prompt(sid, "hello", tpath) };
  }
  // named(transcriptText) -> a UUID session that got "#12 Title12 [xxxxxxxx]" before the resume,
  // with its transcript then holding transcriptText(sid, name), or removed when it is null.
  function named(transcriptText) {
    const sid = crypto.randomUUID();
    const tpath = transcript(sid);
    F.seed(sid, { transcript: tpath });
    fs.writeFileSync(tpath, "");
    const name = prompt(sid, "/wf-init #12", tpath);
    assert.strictEqual(name, `#12 Title12${sfx(sid)}`);
    if (transcriptText !== null) fs.writeFileSync(tpath, transcriptText(sid, name));
    else fs.rmSync(tpath, { force: true });
    return { sid, tpath, name };
  }
  return { sessionStart, prompt, resume, named, transcript };
}

// assertHandoff(got, name): exactly one hook gives the name on a matching resume.
function assertHandoff(got, name, msg) {
  const owners = [got.ss, got.ups].filter((t) => t !== null);
  assert.deepStrictEqual(owners, [name], `${msg || "matching resume"}: SessionStart=[${got.ss}] UserPromptSubmit=[${got.ups}]`);
}
// assertSilent(got): neither hook gives a name.
function assertSilent(got) {
  assert.strictEqual(got.ss, null, "SessionStart must not give a name");
  assert.strictEqual(got.ups, null, "the first UserPromptSubmit must not give a name");
}

function resumeNames(F) {
  const R = makeResume(F);
  test("N6 new start: SessionStart (startup) gives no name; the first UserPromptSubmit gives the none name", () => {
    const sid = crypto.randomUUID();
    const tpath = R.transcript(sid);
    fs.writeFileSync(tpath, "");
    assert.strictEqual(R.sessionStart(sid, "startup", tpath), null);
    assert.strictEqual(R.prompt(sid, "hello", tpath), `neutral${sfx(sid)}`);
  });
  test("N6 resume, latest custom-title equal to last_emitted: exactly one hook gives the name", () => {
    const s = R.named((sid, name) => titleRecord(sid, name));
    assertHandoff(R.resume(s.sid, s.tpath), s.name);
    assert.strictEqual((F.readRecord(s.sid) || {}).last_emitted, s.name);
  });
  test("N6 resume after a /rename: SessionStart and the first UserPromptSubmit both give nothing; the control hands off", () => {
    const ctl = R.named((sid, name) => titleRecord(sid, name));
    assertHandoff(R.resume(ctl.sid, ctl.tpath), ctl.name, "control");
    const s = R.named((sid, name) => titleRecord(sid, name) + titleRecord(sid, "my own name"));
    assertSilent(R.resume(s.sid, s.tpath));
  });
  test("N6 resume with an older matching title under a newer /rename: both hooks give nothing; the control hands off", () => {
    const ctl = R.named((sid, name) => titleRecord(sid, "my own name") + titleRecord(sid, name));
    assertHandoff(R.resume(ctl.sid, ctl.tpath), ctl.name, "control: the latest title decides");
    const s = R.named((sid, name) => titleRecord(sid, "my own name") + titleRecord(sid, name) + titleRecord(sid, "renamed again"));
    assertSilent(R.resume(s.sid, s.tpath));
  });
  test("N6 resume with an unreadable transcript: both hooks give nothing; the control hands off", () => {
    const ctl = R.named((sid, name) => titleRecord(sid, name));
    assertHandoff(R.resume(ctl.sid, ctl.tpath), ctl.name, "control");
    const s = R.named(null);
    assertSilent(R.resume(s.sid, s.tpath));
  });
  test("#2993 manual custom-title and last_emitted null: no none name, no origin lookup", () => {
    const sid = crypto.randomUUID();
    const tpath = R.transcript(sid);
    fs.writeFileSync(tpath, titleRecord(sid, "[PM] manual"));
    const d = F.deps();
    for (let i = 0; i < 2; i++) {
      const r = require(F.ENTRY).run(Object.assign(F.input(sid, "hello"), { transcript_path: tpath }), d);
      assert.notStrictEqual(typeof r, "string", `call ${i + 1} must not give a name`);
      assert.strictEqual(r, null);
    }
    assert.strictEqual(F.spawned(d, "git").length, 0, "no origin lookup");
    assert.strictEqual((F.readRecord(sid) || {}).last_emitted == null, true);
  });
  test("#2993 transcript without a custom-title: none name as before", () => {
    const sid = crypto.randomUUID();
    const tpath = R.transcript(sid);
    fs.writeFileSync(tpath, `${JSON.stringify({ type: "user" })}\n`);
    assert.strictEqual(R.prompt(sid, "hello", tpath), `neutral${sfx(sid)}`);
    const sid2 = crypto.randomUUID();
    const tpath2 = R.transcript(crypto.randomUUID());
    assert.strictEqual(R.prompt(sid2, "hello", tpath2), `neutral${sfx(sid2)}`);
  });
  test("#2993 empty custom-title record: no none name", () => {
    const sid = crypto.randomUUID();
    const tpath = R.transcript(sid);
    fs.writeFileSync(tpath, titleRecord(sid, ""));
    assert.strictEqual(R.prompt(sid, "hello", tpath), null);
  });
  test("#2993 transcript path from session_start_context, input without it", () => {
    const sid = crypto.randomUUID();
    const tpath = R.transcript(sid);
    fs.writeFileSync(tpath, titleRecord(sid, "[PM] manual"));
    F.seed(sid, { transcript: tpath });
    assert.ok(F.quiet(F.call(sid, "hello", F.deps())));
    assert.strictEqual((F.readRecord(sid) || {}).last_emitted == null, true);
    fs.writeFileSync(tpath, `${JSON.stringify({ type: "user" })}\n`);
    assert.strictEqual(F.call(sid, "hello", F.deps()), `neutral${sfx(sid)}`);
  });
  test("#2993 input transcript_path takes priority over session_start_context", () => {
    const plain = `${JSON.stringify({ type: "user" })}\n`;
    const sid = crypto.randomUUID();
    const tState = R.transcript(crypto.randomUUID());
    const tInput = R.transcript(sid);
    fs.writeFileSync(tState, plain);
    fs.writeFileSync(tInput, titleRecord(sid, "[PM] manual"));
    F.seed(sid, { transcript: tState });
    const d = F.deps();
    const r = require(F.ENTRY).run(Object.assign(F.input(sid, "hello"), { transcript_path: tInput }), d);
    assert.notStrictEqual(typeof r, "string", "input transcript with a custom-title must suppress the none name");
    assert.strictEqual(r, null);
    assert.strictEqual(F.spawned(d, "git").length, 0, "no origin lookup");
    assert.strictEqual((F.readRecord(sid) || {}).last_emitted == null, true);
    // control: the opposite placement; the input (no custom-title) wins over the state (custom-title).
    const sid2 = crypto.randomUUID();
    const tState2 = R.transcript(crypto.randomUUID());
    const tInput2 = R.transcript(sid2);
    fs.writeFileSync(tState2, titleRecord(sid2, "[PM] manual"));
    fs.writeFileSync(tInput2, plain);
    F.seed(sid2, { transcript: tState2 });
    assert.strictEqual(R.prompt(sid2, "hello", tInput2), `neutral${sfx(sid2)}`);
  });
  test("#2993 empty-string input transcript_path does not take priority over session_start_context", () => {
    const sid = crypto.randomUUID();
    const tpath = R.transcript(sid);
    fs.writeFileSync(tpath, titleRecord(sid, "[PM] manual"));
    F.seed(sid, { transcript: tpath });
    const r = require(F.ENTRY).run(Object.assign(F.input(sid, "hello"), { transcript_path: "" }), F.deps());
    assert.strictEqual(r, null);
    assert.strictEqual((F.readRecord(sid) || {}).last_emitted == null, true);
    // control: the same placement with a transcript without a custom-title gives the none name.
    const sid2 = crypto.randomUUID();
    const tpath2 = R.transcript(sid2);
    fs.writeFileSync(tpath2, `${JSON.stringify({ type: "user" })}\n`);
    F.seed(sid2, { transcript: tpath2 });
    assert.strictEqual(R.prompt(sid2, "hello", ""), `neutral${sfx(sid2)}`);
  });
  test("#2993 no transcript path in input or state: fail-open, none name", () => {
    const sid = crypto.randomUUID();
    assert.strictEqual(F.call(sid, "hello", F.deps()), `neutral${sfx(sid)}`);
  });
  test("#2993 transcript mentioning custom-title without a valid custom-title record: none name", () => {
    const sid = crypto.randomUUID();
    const tpath = R.transcript(sid);
    const lines = [
      JSON.stringify({ type: "user", message: { content: "please explain custom-title records" } }),
      '{"type":"custom-title", "customTitle": broken-json custom-title',
      JSON.stringify({ type: "assistant", note: "custom-title" }),
    ];
    fs.writeFileSync(tpath, `${lines.join("\n")}\n`);
    assert.strictEqual(R.prompt(sid, "hello", tpath), `neutral${sfx(sid)}`);
  });
  suffixForms(F, R);
}

// suffixForms(F, R) — resumeName after the suffix change (#2941 Steps 4): a name ending in the new
// form moves to this session id; an old-form or suffix-less name is not given again (no old-form
// reader) and its record stays as it was; a prompt that can build a name gives the new form.
function suffixForms(F, R) {
  const SN = require(require("node:path").join(F.ROOT, "hooks", "lib", "session-name.js"));
  // armed(lastEmitted) -> a session whose record holds lastEmitted, whose transcript's latest
  // custom-title equals it, and whose resume mark is armed (as SessionStart source=resume leaves it).
  const armed = (lastEmitted) => {
    const sid = crypto.randomUUID();
    const tpath = R.transcript(sid);
    F.seed(sid, { transcript: tpath });
    fs.writeFileSync(tpath, titleRecord(sid, lastEmitted));
    fs.mkdirSync(path.dirname(F.recordPath(sid)), { recursive: true });
    fs.writeFileSync(F.recordPath(sid), JSON.stringify({ v: 1, last_emitted: lastEmitted, titles: {}, failures: {} }));
    assert.strictEqual(SN.armResumeMark(sid), true, "the resume mark was not armed");
    return { sid, tpath };
  };
  test("N6 resume of a new-form name: the suffix moves to this session id", () => {
    const s = armed("#12 Title12 sid-0badc0de");
    assert.strictEqual(R.prompt(s.sid, "hello", s.tpath), `#12 Title12${sfx(s.sid)}`);
  });
  test("N6 resume of an old-form name with no candidate gives nothing and leaves the record unchanged", () => {
    const s = armed("x [0badc0de]");
    const before = fs.readFileSync(F.recordPath(s.sid), "utf8");
    assert.strictEqual(R.prompt(s.sid, "hello", s.tpath), null);
    assert.strictEqual(fs.readFileSync(F.recordPath(s.sid), "utf8"), before);
  });
  test("N6 resume of an old-form name where the prompt builds a name gives the new form", () => {
    const s = armed("#12 Title12 [0badc0de]");
    assert.strictEqual(R.prompt(s.sid, "/wf-init #12", s.tpath), `#12 Title12${sfx(s.sid)}`);
  });
}

module.exports = { resumeNames };
