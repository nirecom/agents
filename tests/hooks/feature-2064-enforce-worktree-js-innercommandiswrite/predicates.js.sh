# Tests: hooks/lib/bash-write-patterns/classify.js, hooks/lib/bash-write-patterns/dispatch-provenance.js, hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-targets.js
# Tags: worktree, enforce, hook, write-detector, dispatch-provenance, scope:issue-specific
# JS chunk 4/4: predicate dispatcher. Reads last two argv entries, resolves fixture from FIX/SYNTH, prints one token. Must be concatenated LAST.
JS_PREDICATES="$(cat <<'JSEOF'

function req(rel) {
  try { return require(A + rel); } catch (e) { return null; }
}
function b(v) { return v ? "true" : "false"; }

// Last two argv entries: robust across `node -e ... -- p id` and `node file p id`.
const _a = process.argv.slice(-2);
const pred = _a[0];
const id = _a[1];

// Synthetic IRs for layer-1 condition 1 (no fixture string can produce them).
const SYNTH = {
  P1: null,
  P2: { rawText: "x", parseFailure: true, segments: [] },
  P3: { rawText: "", parseFailure: false, segments: [] },
};

// `kindstr` (added for Sections 17/19): prints the ACTUAL segmentDispatchKind
// value per segment ("known-dispatch" / "gh-group-a" / "null"), where the older
// `kind` predicate only prints yes/no. Additive early-return so the existing
// predicate chain below is untouched.
if (pred === "kindstr") {
  const m = req("/hooks/lib/bash-write-patterns/dispatch-provenance");
  if (!m) { console.log("MODULE-MISSING:hooks/lib/bash-write-patterns/dispatch-provenance.js"); process.exit(0); }
  if (typeof m.segmentDispatchKind !== "function") { console.log("EXPORT-MISSING:segmentDispatchKind"); process.exit(0); }
  const kIr = parse(FIX[id]);
  console.log((kIr.segments || []).map((s) => String(m.segmentDispatchKind(s))).join("/"));
  process.exit(0);
}

let out;
if (pred === "prov" || pred === "kind") {
  const m = req("/hooks/lib/bash-write-patterns/dispatch-provenance");
  if (!m) { console.log("MODULE-MISSING:hooks/lib/bash-write-patterns/dispatch-provenance.js"); process.exit(0); }
  if (pred === "prov") {
    if (typeof m.deriveDispatchProvenance !== "function") { console.log("EXPORT-MISSING:deriveDispatchProvenance"); process.exit(0); }
    const ir = Object.prototype.hasOwnProperty.call(SYNTH, id) ? SYNTH[id] : parse(FIX[id]);
    const r = m.deriveDispatchProvenance(ir);
    out = (r && r.dispatchCleared === true) ? "cleared" : "null";
  } else {
    if (typeof m.segmentDispatchKind !== "function") { console.log("EXPORT-MISSING:segmentDispatchKind"); process.exit(0); }
    const ir = parse(FIX[id]);
    out = (ir.segments || []).map((s) => (m.segmentDispatchKind(s) != null ? "yes" : "no")).join("/");
  }
} else if (pred === "trunc" || pred === "truncnoir") {
  const m = req("/hooks/lib/bash-write-patterns/classify");
  if (!m || typeof m.isTruncatedCatHeredocOnly !== "function") { console.log("EXPORT-MISSING:isTruncatedCatHeredocOnly (classify.js)"); process.exit(0); }
  const cmd = FIX[id];
  out = b(pred === "truncnoir" ? m.isTruncatedCatHeredocOnly(cmd, undefined) : m.isTruncatedCatHeredocOnly(cmd, parse(cmd)));
} else if (pred === "ghwrite") {
  const { isGhWriteIR } = require(A + "/hooks/lib/bash-write-patterns/patterns");
  out = b(isGhWriteIR(parse(FIX[id])));
} else if (pred === "detect") {
  const { detectWritePredicate } = require(A + "/hooks/enforce-worktree/write-detector");
  const r = detectWritePredicate(parse(FIX[id]));
  out = r ? r.name : "null";
} else if (pred === "everyExcl" || pred === "outsideScope" || pred === "underWf") {
  const SC = require(A + "/hooks/enforce-worktree/bash-write-scope/segment-checks");
  const ir = parse(FIX[id]);
  if (pred === "everyExcl") out = b(SC.isEverySegmentExcluded(ir, "/tmp/repo", ["/tmp/**", "**/tmp/**"]));
  else if (pred === "outsideScope") out = b(SC.areAllWriteSegmentsOutsideSessionScope(ir, "/tmp/repo", ["/tmp/session"]));
  else out = b(SC.areAllWriteSegmentsUnderWorkflowDir(ir, "/tmp/repo"));
} else {
  const fn = { nl: T.isNewlineInjectedWriteIR, cs: T.isCommandSubstWriteIR, exo: T.isExoticExecWriteIR }[pred];
  out = b(fn(parse(FIX[id])));
}
console.log(out);
JSEOF
)"
