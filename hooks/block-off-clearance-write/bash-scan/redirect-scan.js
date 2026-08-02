// hooks/block-off-clearance-write/bash-scan/redirect-scan.js
// "Does any redirect target of these segments name a protected path?" — the
// redirect half of ./scan.js (file-split, rules/coding/file-split.md Pattern A).
"use strict";

const { classifyBashWriteTarget, commandCwd } = require("../bash-target-context");
const { priorAssignmentsText } = require("./assignment-text");

// #1780 H-4 (round-2 verification): collectWriteTargetsFromSegments RESOLVES a
// redirect target before handing it over, and any token it cannot resolve
// statically (`> $LOG`, or an NTFS ADS spelling whose stream name looks like a
// variable — `> <token>::$DATA`) makes extractRedirectTargets return null. The
// collector turns that into `parseFailure` and yields NO targets, which the
// caller previously read as "nothing protected here" — a fail-open on exactly
// the H-4 exploit, since `$DATA` is unset in bash and the write lands on the
// token itself.
//
// Blanket-blocking every unresolvable redirect would break ordinary dynamic
// redirects, so this scans the redirect target's RAW text instead: the literal
// the user typed, classified by the same protected-basename SSOT (which strips
// the ADS spec). `> $LOG` has a basename of `$LOG` and stays approved.
//
// N-1 (#1780): "classified as a literal path" was too narrow. The raw text is
// BASH text, so a `\` in it is an escape (not a separator), quotes can appear
// mid-word, and a `$NAME` set by a preceding assignment can supply the
// protected tail — all three hid the target from the old literal test while the
// real shell still landed on the protected file. classifyBashWriteTarget()
// applies the Bash-word normalizer, substitutes the preceding assignment chain,
// and fails closed on residual indirection whose chain mentions a protected
// name. `opts` ({ workflowDir, cwd }) additionally enables the N-2
// workflow-dir glob qualifier; it is optional, and its absence only disables
// that qualifier.
function redirectRawTargetsHitProtected(segments, opts) {
  const segs = segments || [];
  const workflowDir = opts && "workflowDir" in opts ? opts.workflowDir : null;
  const toolCwd = opts && typeof opts.cwd === "string" ? opts.cwd : null;
  for (let idx = 0; idx < segs.length; idx++) {
    const seg = segs[idx];
    const redirects = (seg && seg.redirects) || [];
    if (redirects.length === 0) continue;
    const assignText = priorAssignmentsText(segs, idx);
    const ctx = { workflowDir, cwd: commandCwd(segs, idx, toolCwd) };
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
