"use strict";
// Home-repo normalization cases of tests/hooks/feature-2941-pm-writer.js (#2941). No case markers.
// The default cwd's origin is o/r (./fixture.js), so a `#N` is stored as {number, repo: "o/r"}.
const assert = require("node:assert");
const { test } = require("node:test");
const W = require("./fixture");
const { P } = W;

const HOME = "o/r";
const R = (n, repo) => ({ number: n, repo: repo || HOME });

function homeRefs() {
  test("H1 /pm-init #N stores the issue with the home repo, in pm.issues and assignment_log", () => {
    const sid = W.nextSid();
    P.seedState(sid);
    const tag = W.nextTag("PM-home");
    W.assertAccepted(W.write(sid, P.wrapped("pm-init", `${tag} #7012`)), "init", tag);
    const pm = P.readPm(sid);
    assert.deepStrictEqual(pm.issues, [R(7012)]);
    assert.deepStrictEqual(W.lastLog(pm).issues, [R(7012)]);
    W.archive(sid);
  });
  test("H2 /pm-add #N stores the home repo; #N beside other/x#N keeps both as distinct issues", () => {
    const sid = W.nextSid();
    const tag = W.nextTag("PM-home");
    P.seedPm(sid, P.pm({ tag, issues: [R(7022, "other/x")] }));
    W.assertAccepted(W.write(sid, P.wrapped("pm-add", "#7021 #7022")), "add", tag);
    const pm = P.readPm(sid);
    assert.deepStrictEqual(pm.issues, [R(7022, "other/x"), R(7021), R(7022)]);
    assert.deepStrictEqual(W.lastLog(pm).issues, [R(7021), R(7022)]);
    W.archive(sid);
  });
  test("H3 the context and notice show the qualified ref o/r#N", () => {
    const sid = W.nextSid();
    P.seedState(sid);
    const tag = W.nextTag("PM-home");
    const r = W.write(sid, P.wrapped("pm-init", `${tag} #7031`));
    W.assertAccepted(r, "init", tag);
    assert.ok(String(r.context).includes("refs=o/r#7031"), W.brief(r));
    assert.ok(String(r.notice).includes(": o/r#7031 (reason="), W.brief(r));
    W.archive(sid);
  });
}

module.exports = { homeRefs };
