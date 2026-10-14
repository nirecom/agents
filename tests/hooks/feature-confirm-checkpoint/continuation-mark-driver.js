"use strict";
// #2650 continuation marks in hooks/lib/turn-marker.js: writeContinuationMark,
// takeContinuationMark (one-shot; removes the file even when unreadable or malformed) and
// clearContinuationMarks. Driven by ./continuation-mark.sh. Prints PASS|name / FAIL|name|detail.
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const out = [];
const ok = (n, c, d) => out.push(c ? "PASS|" + n : "FAIL|" + n + "|" + String(d).replace(/[\r\n|]+/g, " ").slice(0, 240));
const show = (x) => { try { return JSON.stringify(x); } catch (_) { return String(x); } };
const TM = require(path.join(ROOT, "hooks/lib/turn-marker.js"));
const { getSessionStateDir } = require(path.join(ROOT, "hooks/workflow-state"));
const PRELOAD = path.join(ROOT, "tests/hooks/feature-2650-confirm-continuation/unreadable-preload.js").replace(/\\/g, "/");

const fns = ["writeContinuationMark", "takeContinuationMark", "clearContinuationMarks"];
const missing = fns.filter((f) => typeof TM[f] !== "function");
if (missing.length) {
  ok("turn-marker.js exports " + fns.join(", "), false, "not implemented: " + missing.join(", "));
  process.stdout.write(out.join("\n") + "\n");
  process.exit(0);
}

let n = 0;
const sidOf = () => `cm-${process.pid}-${++n}`;
const markFile = (sid, stage) => path.join(getSessionStateDir(sid), `${sid}.confirm-plan-continue-${stage}.json`);
const fields = (tag) => ({ anchorUuid: "a-" + tag, absPath: "/plans/" + tag + "-outline.md", link: "/plans/" + tag + "-outline.md", artifactSha: "c".repeat(64) });
const seed = (sid, stage, body) => { fs.mkdirSync(path.dirname(markFile(sid, stage)), { recursive: true }); fs.writeFileSync(markFile(sid, stage), body); };

// write + take round trip, one-shot.
{
  const sid = sidOf();
  const f = fields("rt");
  const w = TM.writeContinuationMark(sid, "outline", { anchorUuid: f.anchorUuid, absPath: f.absPath, link: f.link, artifactSha: f.artifactSha });
  ok("writeContinuationMark — returns true", w === true, show(w));
  let raw = null;
  try { raw = JSON.parse(fs.readFileSync(markFile(sid, "outline"), "utf8")); } catch (_) { raw = null; }
  ok("writeContinuationMark — <stateDir>/<sid>.confirm-plan-continue-<stage>.json carries the payload",
    !!raw && raw.session_id === sid && raw.stage === "outline" && raw.anchorUuid === f.anchorUuid && raw.absPath === f.absPath &&
    raw.link === f.link && raw.artifactSha === f.artifactSha && typeof raw.created_at === "string", show(raw));
  const t1 = TM.takeContinuationMark(sid, "outline");
  ok("takeContinuationMark — {ok:true, mark} with the written fields", t1 && t1.ok === true && t1.mark && t1.mark.anchorUuid === f.anchorUuid &&
    t1.mark.artifactSha === f.artifactSha, show(t1));
  ok("takeContinuationMark — the file is removed", !fs.existsSync(markFile(sid, "outline")), "still present");
  const t2 = TM.takeContinuationMark(sid, "outline");
  ok("takeContinuationMark — one-shot: the 2nd take is absent", t2 && t2.ok === false && t2.reason === "absent", show(t2));
  const t3 = TM.takeContinuationMark(sidOf(), "detail");
  ok("takeContinuationMark — never written: absent", t3 && t3.ok === false && t3.reason === "absent", show(t3));
}

// malformed: not JSON, or a required field that is not a string; the file is removed either way.
for (const [label, body] of [
  ["not JSON", "{not json"],
  ["anchorUuid missing", JSON.stringify(Object.assign(fields("m1"), { anchorUuid: undefined }))],
  ["absPath not a string", JSON.stringify(Object.assign(fields("m2"), { absPath: 7 }))],
  ["link missing", JSON.stringify(Object.assign(fields("m3"), { link: undefined }))],
  ["artifactSha null", JSON.stringify(Object.assign(fields("m4"), { artifactSha: null }))],
]) {
  const sid = sidOf();
  seed(sid, "intent", body);
  const t = TM.takeContinuationMark(sid, "intent");
  ok(`takeContinuationMark — ${label}: malformed`, t && t.ok === false && t.reason === "malformed", show(t));
  ok(`takeContinuationMark — ${label}: the file is removed`, !fs.existsSync(markFile(sid, "intent")), "still present");
}

// unreadable: the read throws (preload), the file is still removed.
{
  const sid = sidOf();
  seed(sid, "detail", JSON.stringify(fields("u")));
  const code = `const tm=require(${JSON.stringify(path.join(ROOT, "hooks/lib/turn-marker.js"))});` +
    `process.stdout.write(JSON.stringify(tm.takeContinuationMark(${JSON.stringify(sid)},"detail")));`;
  const r = spawnSync(process.execPath, ["-e", code], { encoding: "utf8", timeout: 30000,
    env: Object.assign({}, process.env, { CC_UNREADABLE: markFile(sid, "detail"), NODE_OPTIONS: `--require "${PRELOAD}"` }) });
  let t = null;
  try { t = JSON.parse(r.stdout); } catch (_) { t = { raw: r.stdout, err: r.stderr }; }
  ok("takeContinuationMark — unreadable: {ok:false, reason:'unreadable'}", t && t.ok === false && t.reason === "unreadable", show(t));
  ok("takeContinuationMark — unreadable: the file is removed anyway", !fs.existsSync(markFile(sid, "detail")), "still present");
}

// clearContinuationMarks: every stage's mark of the session, nothing else.
{
  const sid = sidOf();
  const other = sidOf();
  for (const st of ["intent", "outline", "detail"]) seed(sid, st, JSON.stringify(fields(st)));
  seed(other, "outline", JSON.stringify(fields("other")));
  const turn = TM.writeTurnMarker(sid, { session_id: sid, absPath: "/plans/x-outline.md", suffix: "outline" });
  let threw = null;
  try { TM.clearContinuationMarks(sid); } catch (e) { threw = e.message; }
  ok("clearContinuationMarks — removes all 3 stage marks", threw === null && ["intent", "outline", "detail"].every((st) => !fs.existsSync(markFile(sid, st))), show(threw));
  ok("clearContinuationMarks — leaves turn markers and other sessions' marks", fs.existsSync(turn) && fs.existsSync(markFile(other, "outline")), "removed too much");
}

// double write before any take: the 2nd write replaces the 1st, exactly one mark is consumable,
// and no mark or tmp file of the session remains after the take and after clearContinuationMarks.
{
  const sid = sidOf();
  const leftovers = () => {
    try { return fs.readdirSync(getSessionStateDir(sid)).filter((nm) => nm.startsWith(`${sid}.confirm-plan-continue-`)); } catch (_) { return []; }
  };
  const w1 = TM.writeContinuationMark(sid, "outline", fields("first"));
  const w2 = TM.writeContinuationMark(sid, "outline", fields("second"));
  ok("double write — both writes return true", w1 === true && w2 === true, show([w1, w2]));
  ok("double write — exactly one mark file, no tmp file", show(leftovers()) === show([path.basename(markFile(sid, "outline"))]), show(leftovers()));
  const t1 = TM.takeContinuationMark(sid, "outline");
  ok("double write — the 1st take returns the 2nd write's mark", t1 && t1.ok === true && t1.mark && t1.mark.anchorUuid === "a-second" &&
    t1.mark.absPath === fields("second").absPath, show(t1));
  const t2 = TM.takeContinuationMark(sid, "outline");
  ok("double write — the 2nd take finds nothing (absent)", t2 && t2.ok === false && t2.reason === "absent", show(t2));
  ok("double write — no mark or tmp file remains after the take", leftovers().length === 0, show(leftovers()));
  TM.clearContinuationMarks(sid);
  ok("double write — no mark or tmp file remains after clearContinuationMarks", leftovers().length === 0, show(leftovers()));
}

// invalid sid: false / absent, never a throw.
{
  const bad = "../escape";
  let w; let t; let c = "ok";
  try { w = TM.writeContinuationMark(bad, "outline", fields("bad")); } catch (e) { w = "threw:" + e.message; }
  try { t = TM.takeContinuationMark(bad, "outline"); } catch (e) { t = "threw:" + e.message; }
  try { TM.clearContinuationMarks(bad); } catch (e) { c = "threw:" + e.message; }
  ok("invalid sid — writeContinuationMark returns false", w === false, show(w));
  ok("invalid sid — takeContinuationMark is absent", t && t.ok === false && t.reason === "absent", show(t));
  ok("invalid sid — clearContinuationMarks does not throw", c === "ok", c);
}

process.stdout.write(out.join("\n") + "\n");
