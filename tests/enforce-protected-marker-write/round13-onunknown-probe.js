// Helper for tests/enforce-protected-marker-write/cases-round13-onunknown.sh.
//
// Lives in a FILE rather than a `node -e` body for the same reason as its
// sibling ./round5-containment-probe.js: hooks/block-off-clearance-write.js
// blocks interpreter bodies that spell a protected basename, and a file keeps
// the fixture text out of the command line entirely.
//
// Usage:
//   node round13-onunknown-probe.js <agentsDir> <wfDir> <loopDir> <deepDir> \
//        <outsideLoopDir> <outsideDir>
//   <loopDir>/<deepDir>        unresolvable symlink ancestors UNDER the workflow dir
//   <outsideLoopDir>           an unresolvable symlink ancestor OUTSIDE it
//   <outsideDir>               an ordinary resolvable directory outside it
//
// Prints `key=value` lines (value: true/false/error:<msg>) — one assertion each.
"use strict";

const path = require("path");

const [agentsDir, wfDir, loopDir, deepDir, outsideLoopDir, outsideDir] = process.argv.slice(2);
const H = (...p) => path.join(agentsDir, "hooks", ...p);

const pc = require(H("lib", "path-containment.js"));
const btc = require(H("block-off-clearance-write", "bash-target-context.js"));

const out = [];
function emit(key, fn) {
  let v;
  try { v = fn(); } catch (e) { v = "error:" + (e && e.message ? e.message : String(e)); }
  out.push(key + "=" + v);
}

// Forward-slash join on purpose — these stand in for BASH WORDS as they appear
// on a command line, not for host-native paths (a `\` in a bash word is an
// ESCAPE that unquoteBashWord eats). Same reasoning as ./round5-containment-probe.js.
const j = (dir, base) => String(dir).replace(/\\/g, "/").replace(/\/+$/, "") + "/" + base;
const ctx = { workflowDir: wfDir, cwd: wfDir };
const globInside = (p) => btc.globTargetInsideWorkflowDir(p, ctx);
const dynInside = (p) => btc.dynamicTargetInsideWorkflowDir(p, ctx);
const textInside = (t) => btc.textNamesPathInsideWorkflowDir(t, ctx);

// --- fixture viability: the premise of every row below --------------------
// If the host cannot produce a real symlink, these are false and the bash side
// SKIPs the crafted rows rather than passing vacuously.
const unresolvable = (p) => { try { pc.realResolve(p); return false; } catch (_) { return true; } };
emit("loop_unresolvable", () => unresolvable(loopDir));
emit("deep_unresolvable", () => unresolvable(deepDir));
emit("outside_loop_unresolvable", () => unresolvable(outsideLoopDir));

// --- call site 1: targetBaseInsideWorkflowDir (glob qualifier) ------------
// A pure-wildcard basename commits no literal character to a protected suffix,
// so hooks/lib/basename-glob-normalize.js reports it as a NON-match by design.
// The ONLY thing that then keeps `<wf>/*` from being a free forge/truncation
// route is this containment qualifier. An ancestor the resolver cannot resolve
// must therefore ARM it (onUnknown: true), not clear it.
emit("glob_loop", () => globInside(j(loopDir, "x*")));
emit("glob_deep", () => globInside(j(deepDir, "x*")));
// Pre-fix control: the plain, fully resolvable spelling already blocked. It
// pins the defect to the UNRESOLVABLE ancestor rather than to the rule itself.
emit("glob_plain_inside", () => globInside(j(wfDir, "x*")));
// CPR-5 counterpart: an ordinary resolvable directory outside the workflow dir
// must still answer false, so the fix cannot degenerate into "every glob".
emit("glob_plain_outside", () => globInside(j(outsideDir, "x*")));
// ACCEPTED OVER-BLOCK, pinned deliberately: an unresolvable ancestor ANYWHERE
// answers true, including outside the workflow dir. That is the cost of the
// detection direction and it is bounded — it takes a symlink loop / >40-hop
// chain to reach, which no ordinary bulk glob has.
emit("glob_outside_loop", () => globInside(j(outsideLoopDir, "x*")));

// --- call site 1b: the residual-expansion sibling of the same qualifier ---
// dynamicTargetInsideWorkflowDir shares targetBaseInsideWorkflowDir, so it
// shares the fail direction (CPR-5 — one class, one treatment).
emit("dyn_loop", () => dynInside(j(loopDir, "x$V")));
emit("dyn_plain_inside", () => dynInside(j(wfDir, "x$V")));
emit("dyn_plain_outside", () => dynInside(j(outsideDir, "x$V")));

// --- call site 2: textNamesPathInsideWorkflowDir --------------------------
// The third evidence source, and the only one that survives a target assembled
// INSIDE a substitution. It is the symmetric member of the same class and must
// carry the same onUnknown: true.
emit("text_loop", () => textInside("echo x > " + j(loopDir, "f.txt")));
emit("text_plain_inside", () => textInside("echo x > " + j(wfDir, "f.txt")));
emit("text_plain_outside", () => textInside("echo x > " + j(outsideDir, "f.txt")));

process.stdout.write(out.join("\n") + "\n");
