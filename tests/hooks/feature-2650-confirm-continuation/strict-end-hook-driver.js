"use strict";
// #2650 B1-B4: the presentation turn must close on the plan-link line, at both ends of the
// continuation. Mode "stop" drives hooks/stop-confirm-plan-guard.js (B1); mode "checkpoint"
// drives hooks/confirm-checkpoint.js with a mark written through the Stop hook's own helpers
// (B2-B4). Prints PASS|name / FAIL|name|detail lines.
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const X = require("./fixture");

const { U, A, T, W, TR, STOPFB, ECHO, show, check } = X;
const STAGE = "outline";
const FB = "[confirm-plan] continue: as your next message, emit only the CONFIRM echo";
const PROSE = "\n\nLet me know if you want any changes.";
const mode = process.argv[2];

if (mode === "stop") {
  // presentation(tail) -> Stop-hook result for a turn that wrote the outline and closed on
  // "Here is the plan.\n\n<plan-link line><tail>".
  // publish: the plan resolves to its blob URL (publish stub) and the turn shows the URL line.
  const presentation = (tail, publish) => {
    const s = X.sessionAt(STAGE);
    X.turnMarker(s.sid, STAGE, s.plan);
    const tp = X.writeTranscript(s.sid, [U("write the plan", "u-prompt"), A("a-write", W(s.plan)), TR("w1", "u-tr"),
      A("a-anchor", T("Here is the plan.\n\n" + (publish ? s.urlLine : s.line) + tail))]);
    return { s, r: X.runStop(s.sid, tp, publish ? { publish: true } : {}) };
  };
  const continued = (r) => r.rc === 2 && r.json.decision === "block" && r.reason.startsWith("[confirm-plan] continue:");
  // quiet: the turn ends as before the continuation existed — exit 0, empty stdout, no block decision.
  const quiet = (r) => r.rc === 0 && r.out.trim() === "" && !/"decision"\s*:\s*"block"/.test(r.out);
  for (const [kind, publish] of [["local", false], ["URL", true]]) {
    {
      const { s, r } = presentation("\n", publish);
      const m = X.readMark(s.sid, STAGE);
      check(`B1 ${kind} control: the turn closing on the plan-link line (trailing newline) continues`, continued(r), show({ rc: r.rc, out: r.out, err: r.err.slice(0, 200) }));
      check(`B1 ${kind} control: the continuation mark is written`, m !== null && (!publish || m.link === s.url), show(m));
    }
    {
      const { s, r } = presentation(PROSE, publish);
      check(`B1 ${kind} prose after the plan-link line — exit 0, empty stdout, no block decision`, quiet(r), show({ rc: r.rc, out: r.out }));
      check(`B1 ${kind} prose after the plan-link line — no continuation mark file`, !fs.existsSync(X.markPath(s.sid, STAGE)), show(X.readMark(s.sid, STAGE)));
    }
  }
  {
    const { s, r } = presentation(".", false);
    check("B1 local a trailing period after the plan-link line — no continuation block", !continued(r), show({ rc: r.rc, out: r.out }));
    check("B1 local a trailing period after the plan-link line — no continuation mark file", !fs.existsSync(X.markPath(s.sid, STAGE)), show(X.readMark(s.sid, STAGE)));
  }
} else if (mode === "checkpoint") {
  const PL = require(path.join(X.ROOT, "hooks/lib/plan-link"));
  const { computeArtifactSha } = require(path.join(X.ROOT, "hooks/workflow-state/completion-approval"));
  const CC = X.tryRequire("hooks/lib/confirm-continuation.js");
  const TM = require(path.join(X.ROOT, "hooks/lib/turn-marker"));
  const ready = !CC.__missing && typeof TM.writeContinuationMark === "function";
  check("B precondition — confirm-continuation.js and writeContinuationMark exist", ready, CC.__missing || "writeContinuationMark missing");
  if (!ready) process.exit(0);

  // mark(sid) -> true when written; fields come from the implementation's helpers, as the Stop hook writes them.
  const mark = (sid) => {
    const absPath = CC.approvalArtifactPath(sid, STAGE);
    const link = CC.linkKey(PL.linkForFile(absPath, { plansDir: X.F.PLANS_DIR }));
    try {
      return TM.writeContinuationMark(sid, STAGE, { anchorUuid: "a-anchor", absPath, link, artifactSha: computeArtifactSha(sid, X.STEP[STAGE]) }) === true;
    } catch (_) { return false; }
  };
  // publish: the hook resolves the plan to its blob URL through the publish stub.
  const runHook = (s, entries, publish) => {
    const input = { session_id: s.sid, transcript_path: X.writeTranscript(s.sid, entries), hook_event_name: "PreToolUse",
      tool_name: "Bash", tool_use_id: "e1", tool_input: { command: X.echoOf(STAGE) } };
    const env = Object.assign({}, process.env, X.gateEnv());
    delete env.CLAUDE_CODE_SESSION_ID;
    if (publish) {
      env.NODE_OPTIONS = `--require "${X.PUBLISH_STUB.replace(/\\/g, "/")}"`;
      env.PLAN_SYNC_REMOTE_URL = "https://example.invalid/test-owner/test-repo.git";
    }
    const r = spawnSync(process.execPath, [path.join(X.ROOT, "hooks/confirm-checkpoint.js")], { input: JSON.stringify(input), env, encoding: "utf8", timeout: 30000, cwd: X.TDIR });
    let json = {};
    try { json = r.stdout ? JSON.parse(r.stdout) : {}; } catch (_) { json = { unparsed: r.stdout }; }
    const hso = json.hookSpecificOutput || {};
    return { json, rc: r.status, deny: hso.permissionDecision === "deny", msg: json.systemMessage || "" };
  };
  const passes = (r) => !r.deny && r.rc === 0 && r.json.decision !== "block" && r.msg.includes("Click Allow");
  // sameTurn(s, anchorText, extra, echoEntry) -> the presentation turn, the Stop feedback, extras, the echo.
  const sameTurn = (s, anchorText, extra, echoEntry) => [U("write the plan", "u-prompt"), A("a-write", W(s.plan)), TR("w1", "u-tr"),
    A("a-anchor", T(anchorText)), STOPFB(FB, "u-fb"), ...(extra || []), echoEntry || A("a-echo", ECHO(STAGE, "e1"))];
  const scene = (label, build, publish) => {
    const s = X.sessionAt(STAGE);
    const w = mark(s.sid);
    check(`${label} — precondition: the mark was written`, w, "not written");
    if (publish) check(`${label} — precondition: the mark binds the blob URL`, (X.readMark(s.sid, STAGE) || {}).link === s.url, show(X.readMark(s.sid, STAGE)));
    const r = runHook(s, build(s), publish);
    check(`${label} — the mark is consumed`, !fs.existsSync(X.markPath(s.sid, STAGE)), "mark left");
    return r;
  };

  {
    const r = scene("B control: anchor closing on the plan-link line", (s) => sameTurn(s, "Here is the plan.\n\n" + s.line + "\n"));
    check("B control: anchor closing on the plan-link line — same-turn echo passes to the dialog", passes(r), show(r.json));
  }
  {
    const r = scene("B2 anchor with prose after the plan-link line", (s) => sameTurn(s, "Here is the plan.\n\n" + s.line + PROSE));
    check("B2 anchor with prose after the plan-link line — the same-turn echo is denied", r.deny, show(r.json));
  }
  {
    const r = scene("B3 text entry between the anchor and the echo", (s) => sameTurn(s, "Here is the plan.\n\n" + s.line, [A("a-more", T("Confirming now."))]));
    check("B3 text entry between the anchor and the echo — the same-turn echo is denied", r.deny, show(r.json));
  }
  {
    const r = scene("B3b text item on the echo entry", (s) => sameTurn(s, "Here is the plan.\n\n" + s.line, [], A("a-echo", T("Confirming now."), ECHO(STAGE, "e1"))));
    check("B3b text item on the echo entry — the same-turn echo is denied", r.deny, show(r.json));
  }
  {
    const s = X.sessionAt(STAGE);
    const r = runHook(s, [U("write the plan"), A(null, T("Here is the plan.\n\n" + s.line)), U("looks good, go ahead"), A("a-echo", ECHO(STAGE, "e1"))]);
    check("B4 two-turn fallback without a mark — passes to the dialog", passes(r), show(r.json));
  }

  // URL-backed scenes: from here on, plan-link in this process resolves every plan to its blob
  // URL, so the mark binds the URL as the Stop hook writes it when plan-sync is on.
  require(X.PUBLISH_STUB);
  {
    const r = scene("B URL control: anchor closing on the URL plan-link line", (s) => sameTurn(s, "Here is the plan.\n\n" + s.urlLine + "\n"), true);
    check("B URL control: anchor closing on the URL plan-link line — same-turn echo passes to the dialog with the URL", passes(r) && r.msg.includes(X.BLOB), show(r.json));
  }
  {
    const r = scene("B2 URL anchor with prose after the URL plan-link line", (s) => sameTurn(s, "Here is the plan.\n\n" + s.urlLine + PROSE), true);
    check("B2 URL anchor with prose after the URL plan-link line — the same-turn echo is denied", r.deny, show(r.json));
  }
  {
    const r = scene("B3 URL text entry between the anchor and the echo", (s) => sameTurn(s, "Here is the plan.\n\n" + s.urlLine, [A("a-more", T("Confirming now."))]), true);
    check("B3 URL text entry between the anchor and the echo — the same-turn echo is denied", r.deny, show(r.json));
  }
} else {
  check("strict-end-hook-driver mode", false, "unknown mode: " + mode);
}
