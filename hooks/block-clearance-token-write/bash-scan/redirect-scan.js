// hooks/block-clearance-token-write/bash-scan/redirect-scan.js
// "Does any redirect target of these segments name a protected path?" — the
// redirect half of ./scan.js (file-split, rules/coding/file-split.md Pattern A).
"use strict";

const { classifyBashWriteTarget, commandCwd } = require("../bash-target-context");
const { priorAssignmentsText } = require("./assignment-text");

// #1780 H-4: a redirect target the collector cannot resolve statically
// (`> $LOG`, `> <token>::$DATA`) yields NO targets, which the caller read as
// "nothing protected here" — fail-open on exactly the H-4 exploit. Blanket-
// blocking unresolvable redirects would break ordinary dynamic redirects, so
// this scans the redirect target's RAW text instead, via
// classifyBashWriteTarget(): Bash-word normalization, preceding-assignment
// substitution, and fail-closed on residual indirection that mentions a
// protected name (N-1). `opts` ({ workflowDir, cwd, sessionCtx }) is optional;
// its absence only disables the N-2 workflow-dir glob qualifier.
function redirectRawTargetsHitProtected(segments, opts) {
  const segs = segments || [];
  const workflowDir = opts && "workflowDir" in opts ? opts.workflowDir : null;
  const toolCwd = opts && typeof opts.cwd === "string" ? opts.cwd : null;
  for (let idx = 0; idx < segs.length; idx++) {
    const seg = segs[idx];
    const redirects = (seg && seg.redirects) || [];
    if (redirects.length === 0) continue;
    const assignText = priorAssignmentsText(segs, idx);
    const ctx = { workflowDir, cwd: commandCwd(segs, idx, toolCwd), sessionCtx: opts && opts.sessionCtx };
    for (const r of redirects) {
      if (!r || r.op === "<" || r.op === "<<<") continue;
      const raw = typeof r.targetRaw === "string" && r.targetRaw !== "" ? r.targetRaw : r.target;
      const kind = classifyBashWriteTarget(typeof raw === "string" ? raw : "", assignText, ctx);
      if (kind) return kind;
    }
  }
  return null;
}

module.exports = { redirectRawTargetsHitProtected };
