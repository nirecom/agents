"use strict";
// Unit cases of hooks/lib/confirm-continuation.js: approvalArtifactPath, linkKey,
// sameTurnContinuation, markBindsArtifact and the two reasons' wording; mode "strict" runs A1-A5.
// Prints PASS|name / FAIL|name|detail lines.
const path = require("path");
const X = require("./fixture");

const { A, T, W, BASH, ECHO, STOPFB, show, check } = X;
const CC = X.tryRequire("hooks/lib/confirm-continuation.js");
if (CC.__missing) {
  check("hooks/lib/confirm-continuation.js loads", false, "not implemented: " + CC.__missing);
  process.exit(0);
}
const call = (fn, ...args) => {
  if (typeof CC[fn] !== "function") return { threw: `${fn} is not exported` };
  try { return CC[fn](...args); } catch (e) { return { threw: e.message }; }
};
const { PLAN_LINK_COMMAND } = require(path.join(X.ROOT, "hooks/lib/plan-link"));
const sid = X.uuidSid(2);

// Mode "strict" (A1-A5): the presentation turn closes on the plan-link line. No assistant text
// may follow the anchor, and the anchor text may carry only whitespace after the line.
if (process.argv[2] === "strict") {
  const mark = { stage: "outline", anchorUuid: "a-anchor" };
  const base = [A("a-write", W("/plans/x.md")), A("a-anchor", T("plan line")), STOPFB("[confirm-plan] continue: ...", "u-fb")];
  const st = (entries, self) => call("sameTurnContinuation", entries, mark, self);
  const textBetween = [...base, A("a-more", T("Anything else before I confirm?")), A("a-e", ECHO("outline", "e1"))];
  check("A1 sameTurnContinuation — an assistant text entry between the anchor and the echo (self id)", st(textBetween, "e1") === false, show(st(textBetween, "e1")));
  check("A2 sameTurnContinuation — an assistant text entry between the anchor and the echo (no self id)", st(textBetween, undefined) === false, show(st(textBetween, undefined)));
  const textOnEcho = [...base, A("a-e", T("Confirming the outline now."), ECHO("outline", "e1"))];
  check("A3 sameTurnContinuation — the echo entry itself carries a text item", st(textOnEcho, "e1") === false, show(st(textOnEcho, "e1")));
  const thinking = [...base, A("a-th", { type: "thinking", thinking: "the stop hook asks for the echo", signature: "sig" }), A("a-e", ECHO("outline", "e1"))];
  check("A4 sameTurnContinuation — only the echo after the anchor stays accepted", st([...base, A("a-e", ECHO("outline", "e1"))], "e1") === true, "expected true");
  check("A4 sameTurnContinuation — a thinking item between is not text and stays accepted", st(thinking, "e1") === true, show(st(thinking, "e1")));

  // A5: pickContinuationStage on one unapproved intent plan, gate ON (injected probe).
  // pick(tail, lineKey) -> the pick for "Here is the plan.\n\n<line><tail>"; lineKey "urlLine"
  // shows the published form.
  const pick = (tail, lineKey) => {
    const psid = X.uuidSid(5);
    X.F.writeState(psid, { workflow_init: "complete", clarify_intent: "pending" }, []);
    X.F.writePlan(psid, "intent");
    const lastText = "Here is the plan.\n\n" + X.linesFor(psid, "intent")[lineKey || "line"] + tail;
    try {
      return CC.pickContinuationStage({ sid: psid, lastText, plansDir: X.F.PLANS_DIR, markers: [],
        entries: [X.U("write the plan", "u-prompt"), A("a-anchor", T(lastText))], probe: () => "ON", timeoutMsFor: () => 1200 });
    } catch (e) { return { threw: e.message }; }
  };
  for (const [label, tail] of [["nothing", ""], ["trailing newlines", "\n\n"], ["trailing blanks", "  \n"]]) {
    const g = pick(tail);
    check(`A5 pickContinuationStage — ${label} after the plan-link line continues`, !!g && g.stage === "intent" && !!g.sha, show(g));
  }
  for (const [label, tail] of [["prose", "\n\nLet me know if you want changes."], ["a trailing period", "."], ["a trailing parenthesis", ")"]]) {
    const g = pick(tail);
    check(`A5 pickContinuationStage — ${label} after the plan-link line does not continue`, g === null, show(g));
  }

  // A5 URL: plan-sync on (publish stub), so the link is the blob URL and the URL line is shown.
  require(X.PUBLISH_STUB);
  {
    const g = pick("\n\n", "urlLine");
    check("A5 URL pickContinuationStage — only whitespace after the URL plan-link line continues on the URL",
      !!g && g.stage === "intent" && !!g.link && typeof g.link.url === "string" && g.link.url.startsWith(X.BLOB), show(g));
    const p = pick("\n\nLet me know if you want changes.", "urlLine");
    check("A5 URL pickContinuationStage — prose after the URL plan-link line does not continue", p === null, show(p));
  }
  {
    const urlMark = { stage: "intent", anchorUuid: "a-anchor" };
    const urlBase = [A("a-anchor", T("Here is the plan.\n\nintent: " + X.BLOB + "x.md (`/plans/x.md`)")), STOPFB("[confirm-plan] continue: ...", "u-fb")];
    const got = call("sameTurnContinuation", [...urlBase, A("a-more", T("Confirming now.")), A("a-e", ECHO("intent", "e1"))], urlMark, "e1");
    check("A5 URL sameTurnContinuation — assistant text before the echo after a URL anchor", got === false, show(got));
  }
  process.exit(0);
}

// approvalArtifactPath
{
  const got = call("approvalArtifactPath", sid, "outline");
  const want = path.join(X.F.PLANS_DIR, `${sid}-outline.md`);
  check("approvalArtifactPath — <plans>/<sid>-<stage>.md", typeof got === "string" && path.resolve(got).toLowerCase() === path.resolve(want).toLowerCase(), show([got, want]));
  check("approvalArtifactPath — an invalid sid is null, not a throw", call("approvalArtifactPath", "../evil", "outline") === null, show(call("approvalArtifactPath", "../evil", "outline")));
}

// linkKey
check("linkKey — the URL when one exists", call("linkKey", { url: "https://example.invalid/b/x.md", path: "/plans/x.md" }) === "https://example.invalid/b/x.md", show(call("linkKey", { url: "https://example.invalid/b/x.md", path: "/plans/x.md" })));
check("linkKey — else the path", call("linkKey", { path: "/plans/x.md", reason: "plan-sync-off" }) === "/plans/x.md", show(call("linkKey", { path: "/plans/x.md" })));
check("linkKey — neither: falsy, no throw", !call("linkKey", { reason: "no-artifact" }) && !call("linkKey", null), show([call("linkKey", {}), call("linkKey", null)]));

// sameTurnContinuation(currentTurnEntries, mark, selfToolUseId)
{
  const mark = { stage: "outline", anchorUuid: "a-anchor" };
  const base = [A("a-write", W("/plans/x.md")), A("a-anchor", T("plan line")), STOPFB("[confirm-plan] continue: ...", "u-fb")];
  const st = (entries, m, self) => call("sameTurnContinuation", entries, m, self);
  check("sameTurnContinuation — anchor, Stop feedback, then only the echo itself", st([...base, A("a-e", ECHO("outline", "e1"))], mark, "e1") === true,
    show(st([...base, A("a-e", ECHO("outline", "e1"))], mark, "e1")));
  check("sameTurnContinuation — the anchor uuid is not in the current turn", st([...base, A("a-e", ECHO("outline", "e1"))], { stage: "outline", anchorUuid: "a-old" }, "e1") === false, "expected false");
  check("sameTurnContinuation — a Write after the anchor (a redo)", st([...base, A("a-w2", W("/plans/x.md", "w2")), A("a-e", ECHO("outline", "e1"))], mark, "e1") === false, "expected false");
  check("sameTurnContinuation — a Bash after the anchor (a redo)", st([...base, A("a-b", BASH("ls", "b2")), A("a-e", ECHO("outline", "e1"))], mark, "e1") === false, "expected false");
  check("sameTurnContinuation — an earlier echo with another id after the anchor", st([...base, A("a-e0", ECHO("outline", "e0")), A("a-e", ECHO("outline", "e1"))], mark, "e1") === false, "expected false");
  check("sameTurnContinuation — no self id: a same-stage echo is accepted", st([...base, A("a-e", ECHO("outline", "e1"))], mark, undefined) === true, "expected true");
  check("sameTurnContinuation — no self id: another stage's echo is refused", st([...base, A("a-e", ECHO("detail", "e1"))], mark, undefined) === false, "expected false");
  check("sameTurnContinuation — no mark", st([...base, A("a-e", ECHO("outline", "e1"))], null, "e1") === false, "expected false");
}

// markBindsArtifact(mark, {absPath, link, sha})
{
  const abs = path.join(X.F.PLANS_DIR, `${sid}-outline.md`);
  const sha = "a".repeat(64);
  const mark = { absPath: abs, link: abs, artifactSha: sha };
  const mb = (m, t) => call("markBindsArtifact", m, t);
  const alt = process.platform === "win32" ? abs.replace(/\\/g, "/").toUpperCase() : abs.replace(/\/([^/]+)$/, "/./$1");
  check("markBindsArtifact — same file (another spelling), same link key, same sha", mb(Object.assign({}, mark, { absPath: alt }), { absPath: abs, link: { path: abs }, sha }) === true, show(alt));
  check("markBindsArtifact — another file", mb(mark, { absPath: abs.replace("-outline", "-detail"), link: { path: abs }, sha }) === false, "expected false");
  check("markBindsArtifact — the link shown differs from today's link", mb(mark, { absPath: abs, link: { url: "https://example.invalid/b/x.md", path: abs }, sha }) === false, "expected false");
  check("markBindsArtifact — the sha differs", mb(mark, { absPath: abs, link: { path: abs }, sha: "b".repeat(64) }) === false, "expected false");
  check("markBindsArtifact — a null sha never binds", mb(Object.assign({}, mark, { artifactSha: null }), { absPath: abs, link: { path: abs }, sha: null }) === false, "expected false");
}

// Wording (S6).
for (const stage of X.STAGES) {
  const S = stage.toUpperCase();
  const c = call("continueReason", stage);
  check(`continueReason(${stage}) — exact wording`,
    c === `[confirm-plan] continue: as your next message, emit only echo "<<WORKFLOW_CONFIRM_${S}: {one-line summary}>>" — the approval dialog follows.`, show(c));
  check(`continueReason(${stage}) — no URL, path, sid or error/fail/missing word`,
    typeof c === "string" && !/https?:\/\/|[\\/]\.workflow-plans|\.md\b/.test(c) && !c.includes(sid) && !/error|fail|missing/i.test(c), show(c));
  const d = call("sameTurnDenyReason", stage);
  check(`sameTurnDenyReason(${stage}) — exact wording`,
    d === `[confirm-checkpoint] CONFIRM_${S} denied: the ${stage} plan was not shown, as the message that closed the turn, right before this echo. ` +
      `Do not echo it again in this turn. Run ${PLAN_LINK_COMMAND.replace("<stage>", stage)}, end this turn with its output as-is, wait for the user's reply, ` +
      "then echo the CONFIRM alone in the next turn without rewriting the plan.", show(d));
  check(`sameTurnDenyReason(${stage}) — the plan-link command names the stage, no <stage> placeholder`,
    typeof d === "string" && !d.includes("<stage>") && d.includes(`--stage ${stage}`), show(d));
  check(`sameTurnDenyReason(${stage}) — no URL, no sid, no retry/try again`,
    typeof d === "string" && !/https?:\/\//.test(d) && !d.includes(sid) && !/retry|try again/i.test(d), show(d));
}
