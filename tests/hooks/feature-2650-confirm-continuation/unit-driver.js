"use strict";
// Unit cases of hooks/lib/confirm-continuation.js and (#2729) hooks/lib/presentation-receipt.js:
// approvalArtifactPath and linkKey (moved to presentation-receipt.js), continueReason and
// presentAgainReason wording. Mode "strict": the #2650 transcript-shape predicates are gone —
// the judge reads the presentation receipt instead (tests/hooks/feature-2729-presentation-receipt.sh).
// Prints PASS|name / FAIL|name|detail lines.
const path = require("path");
const X = require("./fixture");

const { show, check } = X;
const CC = X.tryRequire("hooks/lib/confirm-continuation.js");
if (CC.__missing) {
  check("hooks/lib/confirm-continuation.js loads", false, "not implemented: " + CC.__missing);
  process.exit(0);
}
const PR = X.tryRequire("hooks/lib/presentation-receipt.js");
const callIn = (mod, fn, ...args) => {
  if (mod.__missing) return { threw: `module missing: ${mod.__missing}` };
  if (typeof mod[fn] !== "function") return { threw: `${fn} is not exported` };
  try { return mod[fn](...args); } catch (e) { return { threw: e.message }; }
};
const call = (fn, ...args) => callIn(CC, fn, ...args);
const pr = (fn, ...args) => callIn(PR, fn, ...args);
const sid = X.uuidSid(2);

// Mode "strict" (#2729): the same-turn transcript predicates and the single-candidate pick are removed.
if (process.argv[2] === "strict") {
  for (const fn of ["sameTurnContinuation", "anchorClosesOnLink", "markBindsArtifact", "sameTurnDenyReason", "pickContinuationStage"]) {
    check(`#2729 confirm-continuation no longer exports ${fn}`, typeof CC[fn] !== "function", `${fn} still exported`);
  }
  for (const fn of ["presentedStages", "continuationStage", "presentAgainReason", "continueReason"]) {
    check(`#2729 confirm-continuation exports ${fn}`, typeof CC[fn] === "function", `${fn} missing`);
  }
  process.exit(0);
}

// approvalArtifactPath (presentation-receipt.js)
{
  const got = pr("approvalArtifactPath", sid, "outline");
  const want = path.join(X.F.PLANS_DIR, `${sid}-outline.md`);
  check("approvalArtifactPath — <plans>/<sid>-<stage>.md", typeof got === "string" && path.resolve(got).toLowerCase() === path.resolve(want).toLowerCase(), show([got, want]));
  check("approvalArtifactPath — an invalid sid is null, not a throw", pr("approvalArtifactPath", "../evil", "outline") === null, show(pr("approvalArtifactPath", "../evil", "outline")));
}

// linkKey (presentation-receipt.js)
check("linkKey — the URL when one exists", pr("linkKey", { url: "https://example.invalid/b/x.md", path: "/plans/x.md" }) === "https://example.invalid/b/x.md", show(pr("linkKey", { url: "https://example.invalid/b/x.md", path: "/plans/x.md" })));
check("linkKey — else the path", pr("linkKey", { path: "/plans/x.md", reason: "plan-sync-off" }) === "/plans/x.md", show(pr("linkKey", { path: "/plans/x.md" })));
check("linkKey — neither: falsy, no throw", !pr("linkKey", { reason: "no-artifact" }) && !pr("linkKey", null) && !(pr("linkKey", null) || {}).threw, show([pr("linkKey", {}), pr("linkKey", null)]));

// Wording (S6).
for (const stage of X.STAGES) {
  const S = stage.toUpperCase();
  const c = call("continueReason", stage);
  check(`continueReason(${stage}) — exact wording`,
    c === `[confirm-plan] continue: as your next message, emit only echo "<<WORKFLOW_CONFIRM_${S}: {one-line summary}>>" — the approval dialog follows.`, show(c));
  check(`continueReason(${stage}) — no URL, path, sid or error/fail/missing word`,
    typeof c === "string" && !/https?:\/\/|[\\/]\.workflow-plans|\.md\b/.test(c) && !c.includes(sid) && !/error|fail|missing/i.test(c), show(c));
  for (const cause of ["no-receipt", "not-last", "unpublished"]) {
    const d = call("presentAgainReason", stage, cause);
    check(`presentAgainReason(${stage}, ${cause}) — names bin/plan-link --stage ${stage}, no <stage> placeholder`,
      typeof d === "string" && d.includes("plan-link") && d.includes(`--stage ${stage}`) && !d.includes("<stage>"), show(d));
    check(`presentAgainReason(${stage}, ${cause}) — no URL, no sid, no retry/try again`,
      typeof d === "string" && !/https?:\/\//.test(d) && !d.includes(sid) && !/retry|try again/i.test(d), show(d));
  }
}
