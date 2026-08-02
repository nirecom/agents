// Helper for tests/enforce-protected-marker-write/cases-round5-containment.sh.
//
// Lives in a FILE rather than a `node -e` body on purpose: the OFF-clearance
// token suffix is itself a protected string, and hooks/block-off-clearance-write.js
// blocks any interpreter body that spells one. Everything protected here is
// derived from the SSOT (hooks/lib/protected-basenames.js) at runtime, so this
// file also never hardcodes a suffix that could drift.
//
// Usage: node round5-containment-probe.js <agentsDir> <wfDir> <aliasDir> <outsideDir>
//   CLAUDE_WORKFLOW_DIR / WORKFLOW_PLANS_DIR must point at <wfDir> so that the
//   enforce-worktree side's getWorkflowDir() resolves to the same directory the
//   block-off-clearance-write side is handed explicitly.
// Prints `key=value` lines (value: true/false/error:<msg>) — one assertion each.
"use strict";

const path = require("path");

const [agentsDir, wfDir, aliasDir, outsideDir] = process.argv.slice(2);
const H = (...p) => path.join(agentsDir, "hooks", ...p);

const pc = require(H("lib", "path-containment.js"));
const pb = require(H("lib", "protected-basenames.js"));
const tnorm = require(H("enforce-worktree", "bash-write-scope", "target-normalize.js"));
const rres = require(H("enforce-worktree", "bash-write-scope", "realpath-resolve.js"));
const gate = require(H("enforce-worktree", "bash-write-scope", "marker-gate.js"));
const btc = require(H("block-off-clearance-write", "bash-target-context.js"));

const MARKER_SUF = "." + pb.SESSION_MARKER_KINDS[0];
const TOKEN_SUF = pb.OFF_CLEARANCE_TOKEN_SUFFIXES[0];

const out = [];
function emit(key, fn) {
  let v;
  try { v = fn(); } catch (e) { v = "error:" + (e && e.message ? e.message : String(e)); }
  out.push(key + "=" + v);
}

const t = (p) => ({ resolveVia: "ancestor", path: p });
// Forward-slash join on purpose: these stand in for BASH WORDS as they appear in
// a command line, not for host-native paths. A `\` in a bash word is an ESCAPE
// (unquoteBashWord eats it), so building fixtures with path.join() on Windows
// would feed the matcher a mangled spelling and let a case pass for the wrong
// reason.
const j = (dir, base) => String(dir).replace(/\\/g, "/").replace(/\/+$/, "") + "/" + base;
const globInside = (p) => btc.globTargetInsideWorkflowDir(p, { workflowDir: wfDir, cwd: wfDir });
const gateAllows = (p) => gate.areAllBashTargetsUnderWorkflowDir([t(p)]);

// --- the shared implementation is literally shared, not merely equivalent -----
// Function identity is the only drift check that cannot pass by coincidence: a
// re-forked copy in either subtree fails here even while behaving identically today.
emit("id_isContainedUnder", () => tnorm.isContainedUnder === pc.isContainedUnder);
emit("id_realResolve", () => rres.realResolve === pc.realResolve);
emit("id_caseProbe", () => tnorm.isCaseInsensitiveFsAt === pc.isCaseInsensitiveFsAt);

// --- the two call sites must AGREE about the same directory ------------------
// A symlinked alias of the workflow dir is "outside" under a lexical prefix test
// and "inside" under a realpath-aware one. Whichever answer the shared module
// gives, both call sites must give it — disagreement is the exploitable state.
emit("alias_glob", () => globInside(j(aliasDir, "x*")));
emit("alias_gate", () => gateAllows(j(aliasDir, "x.json")));

// Case-only spelling difference. The EXPECTATION is not hardcoded: it is whatever
// the volume actually does (CPR-8 — no implicit branch on platform), and both
// sides must match it.
const CI = pc.isCaseInsensitiveFsAt(wfDir);
emit("case_expected", () => CI);
emit("case_glob", () => globInside(j(wfDir.toUpperCase(), "x*")));
emit("case_gate", () => gateAllows(j(wfDir.toUpperCase(), "x.json")));

// Outside stays outside on both sides (CPR-5 counterpart: the shared helper must
// not have widened containment).
emit("outside_glob", () => globInside(j(outsideDir, "x*")));
emit("outside_gate", () => gateAllows(j(outsideDir, "x.json")));
emit("inside_glob", () => globInside(j(wfDir, "x*")));
emit("inside_gate", () => gateAllows(j(wfDir, "x.json")));

// --- MEDIUM-7: bashTargetsHitProtectedMarker is a DETECTION predicate --------
// It answers "skip every allow fast-path". Both protected FAMILIES count, and a
// target the normalizer could not parse must count too — `false` there handed the
// allow paths back for exactly the inputs nothing could vouch for.
emit("det_marker", () => gate.bashTargetsHitProtectedMarker([t(j(wfDir, "s1" + MARKER_SUF))]));
emit("det_token", () => gate.bashTargetsHitProtectedMarker([t(j(wfDir, "s1" + TOKEN_SUF))]));
emit("det_token_bare", () => gate.bashTargetsHitProtectedMarker([t("s1" + TOKEN_SUF)]));
emit("det_malformed_null", () => gate.bashTargetsHitProtectedMarker([null]));
emit("det_malformed_nopath", () => gate.bashTargetsHitProtectedMarker([{ resolveVia: "ancestor" }]));
emit("det_malformed_mixed", () => gate.bashTargetsHitProtectedMarker([t(j(wfDir, "ok.json")), null]));
emit("det_plain", () => gate.bashTargetsHitProtectedMarker([t(j(wfDir, "notes.txt"))]));
emit("det_empty", () => gate.bashTargetsHitProtectedMarker([]));

// --- the permission-direction sibling answers the OPPOSITE way ---------------
// Same two families, same malformed input, but here `false` is the safe answer.
emit("perm_marker", () => gateAllows(j(wfDir, "s1" + MARKER_SUF)));
emit("perm_token", () => gateAllows(j(wfDir, "s1" + TOKEN_SUF)));
emit("perm_malformed", () => gate.areAllBashTargetsUnderWorkflowDir([null]));

process.stdout.write(out.join("\n") + "\n");
