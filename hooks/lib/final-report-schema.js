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

module.exports = { CATEGORIES, SECTIONS, getSectionHeadings, getProbes, renderSkeleton };
