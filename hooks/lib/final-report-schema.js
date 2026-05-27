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
];

function getSectionHeadings(sessionId) {
  return SECTIONS.map((s) => s.heading(sessionId));
}

function getProbes() {
  const pm = SECTIONS.find((s) => s.id === "post_merge");
  return pm ? pm.probes : [];
}

function renderCanonicalReport(envBag, sessionId, ctx) {
  const blocks = SECTIONS.map((s) => {
    const heading = s.heading(sessionId);
    const lines = s.renderLines(envBag, sessionId, ctx);
    if (lines.length === 0) return heading;
    return heading + "\n" + lines.join("\n");
  });
  return blocks.join("\n\n");
}

module.exports = { CATEGORIES, SECTIONS, getSectionHeadings, getProbes, renderCanonicalReport };
