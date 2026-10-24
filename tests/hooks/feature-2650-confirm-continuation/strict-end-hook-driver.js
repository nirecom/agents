"use strict";
// #2650 B1-B4, rebased on the #2729 presentation receipt. Mode "stop" drives
// hooks/stop-confirm-plan-guard.js (B1): a turn closing on the plan-link line writes a receipt and
// continues; prose after the line blocks (not-last) and writes none. Mode "checkpoint" drives
// hooks/confirm-checkpoint.js (B2-B4): only the receipt decides, never the transcript shape.
// Prints PASS|name / FAIL|name|detail lines.
const path = require("path");
const { spawnSync } = require("child_process");
const X = require("./fixture");

const { U, A, T, W, TR, STOPFB, ECHO, show, check } = X;
const STAGE = "outline";
const FB = "[confirm-plan] continue: as your next message, emit only the CONFIRM echo";
const PROSE = "\n\nLet me know if you want any changes.";
const mode = process.argv[2];
const readReceipt = (sid) => { try { return JSON.parse(require("fs").readFileSync(X.receiptPath(sid, STAGE), "utf8")); } catch (_) { return null; } };

if (mode === "stop") {
  // presentation(tail, publish) -> Stop-hook result for a turn that wrote the outline and closed on
  // "Here is the plan.\n\n<plan-link line><tail>"; publish shows the blob URL line (publish stub).
  const presentation = (tail, publish) => {
    const s = X.sessionAt(STAGE);
    X.turnMarker(s.sid, STAGE, s.plan);
    const tp = X.writeTranscript(s.sid, [U("write the plan", "u-prompt"), A("a-write", W(s.plan)), TR("w1", "u-tr"),
      A("a-anchor", T("Here is the plan.\n\n" + (publish ? s.urlLine : s.line) + tail))]);
    return { s, r: X.runStop(s.sid, tp, publish ? { publish: true } : {}) };
  };
  const continued = (r) => r.rc === 2 && r.json.decision === "block" && r.reason.startsWith("[confirm-plan] continue:");
  // notLast: the Stop hook blocks with presentAgainReason(stage, "not-last") — names the plan-link command.
  const notLast = (r) => r.json.decision === "block" && !continued(r) && r.reason.includes(`--stage ${STAGE}`);
  for (const [kind, publish] of [["local", false], ["URL", true]]) {
    {
      const { s, r } = presentation("\n", publish);
      const rc = readReceipt(s.sid);
      check(`B1 ${kind} control: the turn closing on the plan-link line (trailing newline) continues`, continued(r), show({ rc: r.rc, out: r.out, err: r.err.slice(0, 200) }));
      check(`B1 ${kind} control: the presentation receipt is written`,
        !!rc && !!rc.link && (publish ? rc.link.kind === "url" && rc.link.value === s.url : rc.link.kind === "path"), show(rc));
    }
    {
      const { s, r } = presentation(PROSE, publish);
      check(`B1 ${kind} prose after the plan-link line — blocks to present again (not-last)`, notLast(r), show({ rc: r.rc, out: r.out }));
      check(`B1 ${kind} prose after the plan-link line — no presentation receipt`, !X.receiptExists(s.sid, STAGE), show(readReceipt(s.sid)));
    }
  }
  {
    const { s, r } = presentation(".", false);
    check("B1 local a trailing period after the plan-link line — no continuation block", !continued(r), show({ rc: r.rc, out: r.out }));
    check("B1 local a trailing period after the plan-link line — blocks to present again (not-last)", notLast(r), show({ rc: r.rc, out: r.out }));
    check("B1 local a trailing period after the plan-link line — no presentation receipt", !X.receiptExists(s.sid, STAGE), show(readReceipt(s.sid)));
  }
} else if (mode === "checkpoint") {
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
  // #2731: the dialog systemMessage is the stage fact line (`[<stage>] ...`), no "Click Allow" wording.
  const passes = (r) => !r.deny && r.rc === 0 && r.json.decision !== "block" && /^\[(intent|outline|detail)\] /.test(r.msg);
  // sameTurn(s, anchorText, extra, echoEntry) -> the presentation turn, the Stop feedback, extras, the echo.
  const sameTurn = (s, anchorText, extra, echoEntry) => [U("write the plan", "u-prompt"), A("a-write", W(s.plan)), TR("w1", "u-tr"),
    A("a-anchor", T(anchorText)), STOPFB(FB, "u-fb"), ...(extra || []), echoEntry || A("a-echo", ECHO(STAGE, "e1"))];
  // scene(label, build, {receipt, publish}): receipt=true seeds the receipt the Stop hook would have written.
  const scene = (label, build, o) => {
    const s = X.sessionAt(STAGE);
    if (o.receipt) check(`${label} — precondition: the receipt was seeded`, !!X.seedReceipt(s.sid, STAGE, o.link ? { link: o.link(s) } : undefined), "not seeded");
    const r = runHook(s, build(s), o.publish);
    if (o.receipt && passes(r)) check(`${label} — the pass consumed the receipt`, !X.receiptExists(s.sid, STAGE), "receipt left");
    return r;
  };
  const anchor = (s, key) => "Here is the plan.\n\n" + s[key || "line"];

  {
    const r = scene("B control: receipt, anchor closing on the plan-link line", (s) => sameTurn(s, anchor(s) + "\n"), { receipt: true });
    check("B control: receipt, anchor closing on the plan-link line — echo passes to the dialog", passes(r), show(r.json));
  }
  {
    const r = scene("B2 prose after the plan-link line (Stop wrote no receipt)", (s) => sameTurn(s, anchor(s) + PROSE), {});
    check("B2 prose after the plan-link line, no receipt — the echo is denied", r.deny, show(r.json));
  }
  {
    const r = scene("B3 receipt, text entry between the anchor and the echo", (s) => sameTurn(s, anchor(s), [A("a-more", T("Confirming now."))]), { receipt: true });
    check("B3 receipt, text entry between the anchor and the echo — the transcript shape decides nothing: dialog", passes(r), show(r.json));
  }
  {
    const r = scene("B3b receipt, text item on the echo entry", (s) => sameTurn(s, anchor(s), [], A("a-echo", T("Confirming now."), ECHO(STAGE, "e1"))), { receipt: true });
    check("B3b receipt, text item on the echo entry — the transcript shape decides nothing: dialog", passes(r), show(r.json));
  }
  {
    const twoTurn = (s) => [U("write the plan"), A(null, T(anchor(s))), U("looks good, go ahead"), A("a-echo", ECHO(STAGE, "e1"))];
    const r = scene("B4 two-turn echo without a receipt", twoTurn, {});
    check("B4 two-turn echo without a receipt — denied, even though the previous turn ends on the line", r.deny, show(r.json));
    const ok = scene("B4 two-turn echo with a receipt", twoTurn, { receipt: true });
    check("B4 two-turn echo with a receipt — passes to the dialog", passes(ok), show(ok.json));
  }

  // URL-backed scenes: from here on, plan-link in this process resolves every plan to its blob
  // URL, so seeded receipts bind the URL as the Stop hook writes them when plan-sync is on.
  require(X.PUBLISH_STUB);
  {
    const r = scene("B URL control: URL receipt", (s) => sameTurn(s, anchor(s, "urlLine") + "\n"), { receipt: true, publish: true });
    check("B URL control: URL receipt — echo passes to the dialog with the URL", passes(r) && r.msg.includes(X.BLOB), show(r.json));
  }
  {
    const r = scene("B2 URL prose after the URL line (no receipt)", (s) => sameTurn(s, anchor(s, "urlLine") + PROSE), { publish: true });
    check("B2 URL prose after the URL line, no receipt — the echo is denied", r.deny, show(r.json));
  }
  {
    const r = scene("B5 URL-capable env, path-only receipt", (s) => sameTurn(s, anchor(s) + "\n"),
      { receipt: true, publish: true, link: (s) => ({ kind: "path", value: s.plan }) });
    check("B5 URL-capable env, path-only presentation — the echo is denied (link mismatch)", r.deny && r.msg === "", show(r.json));
  }
} else {
  check("strict-end-hook-driver mode", false, "unknown mode: " + mode);
}
