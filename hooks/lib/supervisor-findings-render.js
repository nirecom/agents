"use strict";

function escapeTokens(str) {
  return typeof str === "string" ? str.replace(/</g, "‹") : str;
}

function aggregateCategories(findings) {
  const seen = new Set();
  const out = [];
  for (const f of findings) {
    if (!f || !Array.isArray(f.categories)) continue;
    for (const c of f.categories) {
      if (typeof c === "string" && !seen.has(c)) { seen.add(c); out.push(c); }
    }
  }
  return out;
}

/**
 * Format alert findings for display after the Final Report.
 * Returns a string when there is content to show, null when nothing to surface.
 *
 * @param {Array} findings - alert.findings array from supervisor state
 * @param {Object} opts
 * @param {string} opts.sessionId
 * @param {string|null} [opts.workflowSessionId]
 * @param {string} opts.supervisorPath
 * @param {string} opts.stateFilePath
 * @param {boolean} [opts.forFinalReport] - when true, escape `<` to U+2039, normalize newlines, and suppress footer
 * @param {boolean} [opts.summaryOnly] - when true, return a 1-line summary instead of the full list
 * @param {boolean} [opts.actionableOnly] - when true, return only severity>=warning findings, one line each; zero actionable → 1-line "no actionable findings" message
 */
function formatLayer2Findings(findings, opts) {
  if (!Array.isArray(findings) || findings.length === 0) return null;

  const { sessionId, workflowSessionId, supervisorPath, stateFilePath } = opts;
  const forFinalReport = opts.forFinalReport === true;
  const summaryOnly = opts.summaryOnly === true;
  const actionableOnly = opts.actionableOnly === true;

  if (summaryOnly) {
    const SRANK = { error: 2, warning: 1, notice: 0 };
    let highestSev = "notice";
    for (const f of findings) {
      if (!f) continue;
      const s = f.severity;
      if (typeof s === "string" && (SRANK[s] !== undefined ? SRANK[s] : -1) > (SRANK[highestSev] !== undefined ? SRANK[highestSev] : -1)) highestSev = s;
    }
    return `[EM Supervisor] ${findings.length} finding(s), highest severity: ${highestSev}.`;
  }
  if (actionableOnly) {
    const actionable = findings.filter(f => f && (f.severity === "error" || f.severity === "warning"));
    if (actionable.length === 0) {
      return "[EM Supervisor] Review complete — no actionable findings.";
    }
    const ISSUE_CREATE_CATEGORIES = new Set(["workflow", "intent", "outline", "detail", "test", "security"]);
    const lines = [];
    for (const f of actionable) {
      let cats = Array.isArray(f.categories) ? f.categories.join(", ") : "(none)";
      let detail = typeof f.detail === "string" ? f.detail : "(no detail)";
      detail = escapeTokens(detail.replace(/[\r\n]+/g, " "));
      cats = escapeTokens(cats);
      let line = `[EM Supervisor] ${f.severity} (${cats}): ${detail}`;
      const needsHint = Array.isArray(f.categories) && f.categories.some(c => ISSUE_CREATE_CATEGORIES.has(c));
      if (needsHint) line += " [→ /issue-create 推奨]";
      lines.push(line);
    }
    return lines.join("\n");
  }
  const wsidLabel = workflowSessionId == null ? "UNAVAILABLE" : workflowSessionId;

  const warningOrErrorFindings = findings.filter(f => f && (f.severity === "error" || f.severity === "warning"));
  const noticeFindings = findings.filter(f => f && f.severity === "notice");

  if (warningOrErrorFindings.length === 0 && noticeFindings.length === 0) return null;

  const allCatsRaw = aggregateCategories(findings);
  const allCats = forFinalReport ? allCatsRaw.map(escapeTokens) : allCatsRaw;
  const lines = [];

  lines.push(`[EM Supervisor] Alert mode findings (post-completion review):`);
  lines.push(`Categories: ${allCats.length > 0 ? allCats.join(", ") : "(none)"}`);

  if (warningOrErrorFindings.length > 0) {
    lines.push(`Findings (severity >= warning):`);
    for (let i = 0; i < warningOrErrorFindings.length; i++) {
      const f = warningOrErrorFindings[i];
      let cats = Array.isArray(f.categories) ? f.categories.join(", ") : "(none)";
      let detail = typeof f.detail === "string" ? f.detail : "(no detail)";
      let reporterValue = typeof f.reporter === "string" && f.reporter ? f.reporter : "(none)";
      if (forFinalReport) {
        detail = detail.replace(/[\r\n]+/g, " ");
        cats = escapeTokens(cats);
        detail = escapeTokens(detail);
        reporterValue = escapeTokens(reporterValue);
      }
      lines.push(`  [${i + 1}] categories=${cats} severity=${f.severity || "(none)"} reporter=${reporterValue} detail=${detail}`);
    }
  }

  if (noticeFindings.length > 0) {
    const noticeRef = forFinalReport
      ? "see supervisor state for full audit trail"
      : `consult ${stateFilePath} for the full audit trail`;
    lines.push(`Notices: ${noticeFindings.length} additional notice-severity finding(s) recorded — not shown (${noticeRef}).`);
  }

  if (!forFinalReport) {
    lines.push(`Session ID: ${sessionId}`);
    lines.push(`Workflow session ID: ${wsidLabel}`);
    lines.push(`Full audit trail: ${stateFilePath}`);
    lines.push(`Recommended action: review and address per agents/supervisor.md (${supervisorPath}).`);
  }

  return lines.join("\n");
}

module.exports = { formatLayer2Findings };
