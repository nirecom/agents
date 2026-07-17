"use strict";

const CATEGORIES = [
  { label: "Claude Code restart", newKey: "CC_RESTART_REQUIRED", reasonKey: "CC_RESTART_REASON", legacyKey: "CLAUDE_CODE_RESTART_REQUIRED", legacyYes: "yes" },
  { label: "VS Code reload",      newKey: "VSCODE_RELOAD_REQUIRED",   reasonKey: "VSCODE_RELOAD_REASON",   legacyKey: null, legacyYes: null },
  { label: "Installer rerun",     newKey: "INSTALLER_RERUN_REQUIRED", reasonKey: "INSTALLER_RERUN_REASON", legacyKey: null, legacyYes: null },
  { label: "OS reboot",           newKey: "OS_REBOOT_REQUIRED",       reasonKey: "OS_REBOOT_REASON",       legacyKey: null, legacyYes: null },
];

const SECTIONS = [
  {
    id: "header",
    heading: (sid) => `## Final Report — ${sid}`,
    renderLines: () => [],
    probes: [],
  },
  {
    id: "closed_issues",
    heading: () => "### Closed Issues",
    renderLines: (envBag, sid, ctx) => [ctx.closedIssuesLine],
    probes: [],
  },
  {
    id: "merged_pr",
    heading: () => "### Merged PR",
    renderLines: (envBag, sid, ctx) => [
      `- PR #${ctx.safeEnv("PR_NUMBER")}: ${ctx.safeEnv("PR_TITLE")}`,
      `- URL: ${ctx.safeEnv("PR_URL")}`,
      `- State: ${ctx.safeEnv("PR_STATE")}`,
    ],
    probes: [],
  },
  {
    id: "worktree",
    heading: () => "### Worktree",
    renderLines: (envBag, sid, ctx) => [
      `- Branch: ${ctx.safeEnv("BRANCH")}`,
      `- Path: ${ctx.safeEnv("WORKTREE_PATH")}`,
      `- Created: ${ctx.safeEnv("CREATED_DATE")}`,
      "- Removed: ✓",
    ],
    probes: [],
  },
  {
    id: "backup",
    heading: () => "### Backup",
    renderLines: (envBag, sid, ctx) => [
      `- Manifest: ${ctx.safeEnv("BACKUP_MANIFEST_PATH")}`,
      `- Branches deleted: ${ctx.safeEnv("BRANCH_DELETED")}`,
    ],
    probes: [],
  },
  {
    id: "closed_issue_outcomes",
    heading: () => "### Closed Issue Outcomes",
    renderLines: (envBag, sid, ctx) => ctx.closedIssueOutcomeLines,
    probes: ["- "],
  },
  {
    id: "post_merge",
    heading: () => "### Post-Merge Actions Required",
    renderLines: (envBag, sid, ctx) => ctx.buildPostMergeLines(),
    probes: [
      "- Claude Code restart:",
      "- VS Code reload:",
      "- Installer rerun:",
      "- OS reboot:",
    ],
  },
  {
    id: "bugs_found",
    heading: () => "### Bugs Found",
    renderLines: (envBag, sid, ctx) => ctx.bugsLines,
    probes: [],
  },
  {
    id: "related_tasks",
    heading: () => "### Related Tasks",
    renderLines: (envBag, sid, ctx) => ctx.relatedLines,
    probes: [],
  },
  {
    id: "next_tasks",
    heading: () => "### Next Tasks",
    renderLines: (envBag, sid, ctx) => ctx.nextLines,
    probes: [],
  },
  {
    id: "supervisor_alert",
    heading: () => "### Supervisor Alert",
    renderLines: (envBag, sid, ctx) => ["<SUPERVISOR_ALERT_SUMMARY>"],
    probes: [],
  },
  {
    id: "supervisor_audit",
    heading: () => "### Supervisor Audit",
    renderLines: (envBag, sid, ctx) => ["<SUPERVISOR_AUDIT_SUMMARY>"],
    probes: [],
  },
  {
    id: "supervisor_findings",
    heading: () => "### Supervisor Findings",
    renderLines: () => ["<SUPERVISOR_FINDINGS_DETAIL>"],
    probes: [],
  },
];

function safeEnvVal(env, key) {
  const v = env[key];
  if (v === undefined || v === null || v === "") return "(none)";
  return String(v).replace(/[\r\n]/g, " ").slice(0, 200);
}

function catValue(env, cat) {
  const v = safeEnvVal(env, cat.newKey);
  if (v !== "(none)") return v;
  if (!cat.legacyKey) return "not_required";
  const legacy = safeEnvVal(env, cat.legacyKey);
  if (legacy !== "(none)") {
    if (legacy === cat.legacyYes) return "required";
    if (legacy === "no") return "not_required";
    return legacy;
  }
  return "not_required";
}

function buildPostMergeLines(env) {
  const lines = ["### Post-Merge Actions Required"];
  for (const cat of CATEGORIES) {
    const v = catValue(env, cat);
    const reasonVal = safeEnvVal(env, cat.reasonKey);
    if (v === "required" && reasonVal !== "(none)") {
      lines.push(`- ${cat.label}: required (${reasonVal})`);
    } else {
      lines.push(`- ${cat.label}: ${v}`);
    }
  }
  return lines;
}

function getSectionHeadings(sessionId) {
  return SECTIONS.map((s) => s.heading(sessionId));
}

function getProbes() {
  const out = [];
  for (const s of SECTIONS) {
    if (Array.isArray(s.probes) && s.probes.length > 0) {
      out.push(...s.probes);
    }
  }
  return out;
}

function renderSkeleton(sessionId) {
  if (!/^[A-Za-z0-9_-]+$/.test(sessionId)) {
    throw new Error(`renderSkeleton: invalid sessionId "${sessionId}"`);
  }
  const placeholders = {
    closed_issues: ["<CLOSED_ISSUES_LIST>"],
    merged_pr: [
      "- PR #<PR_NUMBER>: <PR_TITLE>",
      "- URL: <PR_URL>",
      "- State: <PR_STATE>",
    ],
    worktree: [
      "- Branch: <BRANCH>",
      "- Path: <WORKTREE_PATH>",
      "- Created: <CREATED_DATE>",
      "- Removed: ✓",
    ],
    backup: [
      "- Manifest: <BACKUP_MANIFEST_PATH>",
      "- Branches deleted: <BRANCH_DELETED>",
    ],
    closed_issue_outcomes: ["<CLOSED_ISSUE_OUTCOMES>"],
    post_merge: CATEGORIES.map((c) => `- ${c.label}: <${c.newKey}_DECISION>`),
    bugs_found: ["<BUGS_FOUND>"],
    related_tasks: ["<RELATED_TASKS>"],
    next_tasks: ["<NEXT_TASKS>"],
    supervisor_alert: ["<SUPERVISOR_ALERT_SUMMARY>"],
    supervisor_audit: ["<SUPERVISOR_AUDIT_SUMMARY>"],
    supervisor_findings: ["<SUPERVISOR_FINDINGS_DETAIL>"],
  };
  const blocks = SECTIONS.map((s) => {
    const heading = s.heading(sessionId);
    const lines = placeholders[s.id] || [];
    return lines.length === 0 ? heading : `${heading}\n${lines.join("\n")}`;
  });
  return `${blocks.join("\n\n")}\n`;
}

function fieldOrNone(env, key) {
  const v = env[key];
  if (v === undefined || v === null || v === "") return "(none)";
  return String(v);
}

function decisionValue(env, requiredKey, reasonKey) {
  if (env[requiredKey] === "required") {
    const reason = env[reasonKey];
    const reasonStr = reason === undefined || reason === null || reason === "" ? "" : String(reason);
    return reasonStr ? `required (${reasonStr})` : "required";
  }
  return "not_required";
}

function closedIssueOutcomeLines(outcome) {
  const issues = outcome && Array.isArray(outcome.issues) ? outcome.issues : [];
  if (issues.length === 0) return "- (outcome data not found — investigate)";
  return issues
    .map((it) => {
      const state = it.state === "skipped_wf_meta" ? "kept open (planning session)" : it.state;
      return `- #${it.number}: ${state} (history: ${it.historyEntry}, closed: ${it.issueClosed}, sentinels: ${it.sentinelsPosted}, wip: ${it.wipCleared})`;
    })
    .join("\n");
}

function supervisorAlertSummary(supervisorState) {
  if (!supervisorState) return "(not run)";
  const alert = supervisorState.alert || {};
  const findings = Array.isArray(alert.findings) ? alert.findings.length : 0;
  return `phase: ${alert.alert_phase || "none"}, severity: ${alert.cumulative_severity || "none"}, findings: ${findings}`;
}

function supervisorAuditSummary(supervisorState) {
  if (!supervisorState) return "(not run)";
  const audit = supervisorState.audit || {};
  return `phase: ${audit.audit_phase || "none"}, verdict: ${audit.audit_verdict || "none"}, cause: ${audit.audit_cause || "none"}`;
}

function supervisorFindingsDetail(sessionId, supervisorState) {
  if (!supervisorState || !supervisorState.alert) return "(no findings)";
  const findings = supervisorState.alert.findings || [];
  const { formatLayer2Findings } = require("./supervisor-findings-render");
  const out = formatLayer2Findings(findings, {
    sessionId,
    workflowSessionId: null,
    supervisorPath: null,
    stateFilePath: null,
    summaryOnly: true,
  });
  return out || "(no findings)";
}

function renderFinalReport(sessionId, inputs) {
  if (!/^[A-Za-z0-9_-]+$/.test(sessionId)) {
    throw new Error(`renderFinalReport: invalid sessionId "${sessionId}"`);
  }
  const { env, outcome, closesIssues, notesSections, supervisorState } = inputs;

  const closedIssuesList = Array.isArray(closesIssues) && closesIssues.length > 0
    ? closesIssues.map((n) => `- #${n}`).join("\n")
    : "- (none)";

  const substitutions = {
    "<PR_NUMBER>": fieldOrNone(env, "PR_NUMBER"),
    "<PR_TITLE>": fieldOrNone(env, "PR_TITLE"),
    "<PR_URL>": fieldOrNone(env, "PR_URL"),
    "<PR_STATE>": fieldOrNone(env, "PR_STATE"),
    "<BRANCH>": fieldOrNone(env, "BRANCH"),
    "<WORKTREE_PATH>": fieldOrNone(env, "WORKTREE_PATH"),
    "<CREATED_DATE>": fieldOrNone(env, "CREATED_DATE"),
    "<BACKUP_MANIFEST_PATH>": fieldOrNone(env, "BACKUP_MANIFEST_PATH"),
    "<BRANCH_DELETED>": fieldOrNone(env, "BRANCH_DELETED"),
    "<CLOSED_ISSUES_LIST>": closedIssuesList,
    "<CLOSED_ISSUE_OUTCOMES>": closedIssueOutcomeLines(outcome),
    "<CC_RESTART_REQUIRED_DECISION>": decisionValue(env, "CC_RESTART_REQUIRED", "CC_RESTART_REASON"),
    "<VSCODE_RELOAD_REQUIRED_DECISION>": decisionValue(env, "VSCODE_RELOAD_REQUIRED", "VSCODE_RELOAD_REASON"),
    "<INSTALLER_RERUN_REQUIRED_DECISION>": decisionValue(env, "INSTALLER_RERUN_REQUIRED", "INSTALLER_RERUN_REASON"),
    "<OS_REBOOT_REQUIRED_DECISION>": decisionValue(env, "OS_REBOOT_REQUIRED", "OS_REBOOT_REASON"),
    "<BUGS_FOUND>": notesSections.bugs,
    "<RELATED_TASKS>": notesSections.related,
    "<NEXT_TASKS>": notesSections.next,
    "<SUPERVISOR_ALERT_SUMMARY>": supervisorAlertSummary(supervisorState),
    "<SUPERVISOR_AUDIT_SUMMARY>": supervisorAuditSummary(supervisorState),
    "<SUPERVISOR_FINDINGS_DETAIL>": supervisorFindingsDetail(sessionId, supervisorState),
  };

  let out = renderSkeleton(sessionId);
  for (const [token, value] of Object.entries(substitutions)) {
    out = out.split(token).join(value);
  }
  return out;
}

module.exports = { CATEGORIES, SECTIONS, getSectionHeadings, getProbes, renderSkeleton, buildPostMergeLines, renderFinalReport };
