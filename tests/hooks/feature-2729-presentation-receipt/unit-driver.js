"use strict";
// #2729 unit cases for hooks/lib/presentation-receipt.js: the receipt store's write guard, the
// read shapes, discard (discardAll is gone, #2771), and matchReceipt's causes. Prints PASS|name / FAIL|name|detail.
const path = require("path");
const R = require("./fixture");
const { check, show } = R;

const PR = R.tryRequire("hooks/lib/presentation-receipt.js");
if (PR.__missing) {
  check("presentation-receipt.js loads", false, PR.__missing);
  process.exit(0);
}
const s = R.sessionAt("outline", { tag: 900 });
const p = s.plan;
const url = { kind: "url", value: s.url };
const sha = R.sha256(p);
const fields = { absPath: p, link: url, contentSha: sha, anchorUuid: "a-1" };

check("receiptPath is <stateDir>/<sid>.confirm-plan-receipt-<stage>.json",
  typeof PR.receiptPath === "function" && path.resolve(PR.receiptPath(s.sid, "outline")) === path.resolve(R.receiptPath(s.sid, "outline")),
  show(typeof PR.receiptPath === "function" ? PR.receiptPath(s.sid, "outline") : "missing"));

check("writeReceipt with a url link returns true", PR.writeReceipt(s.sid, "outline", fields) === true, "false");
const raw = R.readReceiptRaw(s.sid, "outline");
check("the written receipt carries absPath, link, contentSha, anchorUuid, writtenAt",
  raw && raw.contentSha === sha && raw.anchorUuid === "a-1" && raw.link && raw.link.kind === "url" && typeof raw.writtenAt === "string", show(raw));
const rr = PR.readReceipt(s.sid, "outline");
check("readReceipt -> {ok:true, receipt}", rr && rr.ok === true && rr.receipt && rr.receipt.contentSha === sha, show(rr));

check("writeReceipt refuses a url link that is not http(s)", PR.writeReceipt(s.sid, "intent", Object.assign({}, fields, { link: { kind: "url", value: "ftp://x" } })) === false, "true");
check("writeReceipt refuses a path link that is not absPath", PR.writeReceipt(s.sid, "intent", Object.assign({}, fields, { link: { kind: "path", value: p + ".other" } })) === false, "true");
check("a refused write leaves no file", !R.receiptExists(s.sid, "intent"), "file written");
check("writeReceipt accepts a path link equal to absPath", PR.writeReceipt(s.sid, "detail", Object.assign({}, fields, { link: { kind: "path", value: p } })) === true, "false");

check("readReceipt of a missing file -> absent", show(PR.readReceipt(s.sid, "intent")) === show({ ok: false, reason: "absent" }), show(PR.readReceipt(s.sid, "intent")));
R.writeReceiptRaw(s.sid, "intent", "{ not json");
check("readReceipt of non-JSON -> unreadable", show(PR.readReceipt(s.sid, "intent")) === show({ ok: false, reason: "unreadable" }), show(PR.readReceipt(s.sid, "intent")));
R.writeReceiptRaw(s.sid, "intent", { absPath: p, link: url, anchorUuid: "a" });
check("readReceipt with a missing field -> unreadable", PR.readReceipt(s.sid, "intent").reason === "unreadable", show(PR.readReceipt(s.sid, "intent")));
R.writeReceiptRaw(s.sid, "intent", Object.assign({}, fields, { writtenAt: "x", link: { kind: "blob", value: s.url } }));
check("readReceipt with a link of neither shape -> unreadable", PR.readReceipt(s.sid, "intent").reason === "unreadable", show(PR.readReceipt(s.sid, "intent")));

const rec = PR.readReceipt(s.sid, "outline").receipt;
const m = (cur) => { try { return PR.matchReceipt(rec, cur); } catch (e) { return "threw:" + e.message; } };
check("matchReceipt: same path, link and content -> ok", show(m({ absPath: p, link: url, contentSha: sha })) === show({ ok: true }), show(m({ absPath: p, link: url, contentSha: sha })));
check("matchReceipt: another path -> path", m({ absPath: p + ".x", link: url, contentSha: sha }).cause === "path", show(m({ absPath: p + ".x", link: url, contentSha: sha })));
check("matchReceipt: another url -> link", m({ absPath: p, link: { kind: "url", value: s.url + "x" }, contentSha: sha }).cause === "link", "");
check("matchReceipt: another link kind -> link", m({ absPath: p, link: { kind: "path", value: p }, contentSha: sha }).cause === "link", "");
check("matchReceipt: another content -> content", m({ absPath: p, link: url, contentSha: "0".repeat(64) }).cause === "content", "");

PR.discardReceipt(s.sid, "outline");
check("discardReceipt removes the file", !R.receiptExists(s.sid, "outline"), "still present");
let threw = null;
try { PR.discardReceipt(s.sid, "outline"); } catch (e) { threw = e.message; }
check("discardReceipt of a missing file does not throw", threw === null, threw);
// #2771: nothing voids every receipt at once any more (a block or an exception keeps them).
check("discardAllReceipts is no longer exported", typeof PR.discardAllReceipts === "undefined", typeof PR.discardAllReceipts);
PR.discardReceipt(s.sid, "detail");

// A failed write (fs error on the temp file or on the rename) is fail-closed: writeReceipt returns
// false without throwing, leaves neither the receipt nor its temp file, and a later read is absent,
// so the echo that follows is denied.
const fs = require("fs");
const stateDir = path.dirname(R.receiptPath(s.sid, "outline"));
const tmpsLeft = () => { try { return fs.readdirSync(stateDir).filter((n) => n.includes(".confirm-plan-receipt-") && n.endsWith(".tmp")).length; } catch (_) { return 0; } };
for (const [label, name] of [["writeFileSync", "writeFileSync"], ["renameSync", "renameSync"]]) {
  const orig = fs[name];
  fs[name] = function (...args) {
    if (String(args[0]).includes(".confirm-plan-receipt-")) { const e = new Error("EACCES: injected"); e.code = "EACCES"; throw e; }
    return orig.apply(this, args);
  };
  let got;
  let thrown = null;
  try { got = PR.writeReceipt(s.sid, "outline", fields); } catch (e) { thrown = e.message; } finally { fs[name] = orig; }
  check(`writeReceipt with ${label} failing returns false and does not throw`, thrown === null && got === false, show({ got, thrown }));
  check(`writeReceipt with ${label} failing leaves no receipt`, !R.receiptExists(s.sid, "outline"), show(R.readReceiptRaw(s.sid, "outline")));
  check(`writeReceipt with ${label} failing leaves no temp file`, tmpsLeft() === 0, "tmp files=" + tmpsLeft());
  check(`readReceipt after a failed ${label} write -> absent`, show(PR.readReceipt(s.sid, "outline")) === show({ ok: false, reason: "absent" }), show(PR.readReceipt(s.sid, "outline")));
}
// The later echo is denied: confirm-checkpoint's judge finds no receipt.
const deniedAfterFail = R.echo(s.sid, "outline");
check("the echo after a failed receipt write is denied (fail-closed)", deniedAfterFail.denied && !deniedAfterFail.dialog, show({ rc: deniedAfterFail.rc, json: deniedAfterFail.json }));
// Same predicate as r-cases-driver.js presentAgain (that file is a script, not a module).
const presentAgain = (reason, stage) => reason !== "" && !reason.startsWith("[confirm-plan] continue:") &&
  reason.includes("plan-link") && reason.includes(`--stage ${stage}`);
check("the deny reason after a failed receipt write asks to present the plan again",
  presentAgain(deniedAfterFail.reason, "outline"), deniedAfterFail.reason);

const CA = R.tryRequire("hooks/workflow-state/completion-approval.js");
const cs = typeof CA.computeContentSha === "function" ? CA.computeContentSha(p) : "missing";
check("computeContentSha is the sha256 of the whole file (## Issues included)", cs === sha, show(cs));
check("computeContentSha of an unreadable path is null", typeof CA.computeContentSha === "function" && CA.computeContentSha(p + ".none") === null, "not null");
