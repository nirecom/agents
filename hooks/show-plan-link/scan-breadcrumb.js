"use strict";
// hooks/show-plan-link/scan-breadcrumb.js
// The display of a plan-sync failure from the pre-push outbound scan (#3150): reason, up to
// MAX_SHOWN `rel:line [kind]` findings, and the way out. The matched text is never shown.
// scanLines(result, absPath) -> fact lines for the systemMessage | null (not a scan failure)
// scanNote(result, absPath) -> the model-facing explanation | null

const MAX_SHOWN = 5;
const ALLOWLIST = ".private-info-allowlist";
const SKIP_CLI = 'node "$AGENTS_MAIN_ROOT/bin/plan-sync-scan-skip"';

const isScanFailure = (r) => Boolean(r && r.status === "failed" && typeof r.reason === "string" && r.reason.startsWith("scan-"));
const skipCommand = (absPath) => `${SKIP_CLI} "${absPath}" --reason "<text>"`;
const wayOut = (r, absPath) => (r.reason === "scan-blocked" ? `allowlist=${ALLOWLIST}` : skipCommand(absPath));

// One token per field; blanks in a kind would read as prose, so they become dashes.
const token = (v) => String(v).replace(/\s+/g, "-");

function scanLines(result, absPath) {
  if (!isScanFailure(result)) return null;
  const findings = Array.isArray(result.findings) ? result.findings : [];
  const lines = [`[plan-sync] ${result.reason} ${wayOut(result, absPath)}`];
  for (const f of findings.slice(0, MAX_SHOWN)) lines.push(`[plan-sync] ${token(f.rel)}:${Number(f.line)} [${token(f.kind)}]`);
  if (findings.length > MAX_SHOWN) lines.push(`[plan-sync] +${findings.length - MAX_SHOWN} more`);
  return lines;
}

function scanNote(result, absPath) {
  if (!isScanFailure(result)) return null;
  if (result.reason === "scan-blocked") {
    return `plan-sync did not push (${result.reason}): the outbound scan found private information in the plan or a carried plan. `
      + `Fix the listed lines and save the plan again, or, for a false positive, add a pattern to ${ALLOWLIST} in the main worktree.`;
  }
  return `plan-sync did not push (${result.reason}): the outbound scanner could not finish. `
    + `To push once without the scan, the user approves running ${skipCommand(absPath)} (plan-sync-scan-skip), then the plan is saved again.`;
}

module.exports = { scanLines, scanNote };
