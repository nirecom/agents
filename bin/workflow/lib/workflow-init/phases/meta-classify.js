"use strict";

const { spawnSync } = require("child_process");
const { buildGhSpawn } = require("../spawn-env");
const { resolveOwnerRepoFromOrigin, parseOwnerRepoFromApiUrl, META_LABEL } = require("../../../../lib/forge-issue-links");
const { sanitizeLine } = require("../../../../../hooks/lib/output-sanitize");

// Phase: meta-classify (#2087). Runs before wip-check so meta issues never
// reach wip-state.sh. All-meta -> ask meta_select or set path_decision=META;
// mixed -> strip meta issues. Path A/B/C selection belongs to route-decision.
function metaClassify(state) {
  const issues = state.issues;

  // Re-classification must not keep a stale META verdict.
  if (state.path_decision === "META") state.path_decision = null;

  if (issues.length === 0) return { done: false };

  const metaIssues = issues.filter((n) => (state.label_sets[n] || []).includes(META_LABEL));

  if (metaIssues.length === issues.length) {
    // Resolved once from origin, not per issue (#1899).
    const origin = resolveOwnerRepoFromOrigin();
    if (!origin.ok) {
      return {
        blocked: true,
        reason: "origin_repo_unresolved",
        nextHint:
          "could not resolve the repository from the 'origin' remote: " +
          origin.message +
          ". Run workflow-init from a checkout whose 'origin' remote points at the github.com repository you mean.",
      };
    }
    for (const n of metaIssues) {
      const fetched = fetchSubIssues(origin.ownerRepo, n);
      if (!fetched.ok) {
        // Fail closed: don't authorize META on a fetch failure.
        return {
          blocked: true,
          reason: "sub_issues_fetch_failed",
          nextHint:
            `could not list sub-issues of #${n} in ${origin.ownerRepo} (${fetched.reason}). ` +
            "Verify the issue number and that `gh auth status` reports an authenticated account " +
            "with read access to that repository, then re-run workflow-init.",
        };
      }
      const openSubs = fetched.subIssues.filter((s) => (s.state || "").toLowerCase() === "open");
      if (openSubs.length > 0) {
        // sanitizeLine + "|" strip: untrusted title, and blocks OPTIONS_DISPLAY injection.
        const describe = (s) => `#${s.number}: ${sanitizeLine(s.title || "").replace(/\|/g, "/")}`;
        const listText = openSubs.map(describe).join(" | ");
        const optionsDisplay = openSubs.map(describe).concat(["abort"]).join("|");
        // Track repo identity, not just number — a sub-issue may live elsewhere.
        state.meta_select_offered = openSubs.map((s) => ({
          number: s.number,
          ownerRepo: parseOwnerRepoFromApiUrl(s.repository_url) || origin.ownerRepo,
        }));
        // Carry sibling meta parents so they get re-classified, not dropped.
        state.meta_select_pending = metaIssues.filter((m) => m !== n);
        return {
          ask: true,
          askId: "meta_select",
          question: `Issue #${n} is a meta issue with open sub-issues. Select one to work on: ${listText}`,
          options: optionsDisplay,
        };
      }
    }
    // state.issues stays as-is; wip-check.js filters meta issues via label_sets.
    state.path_decision = "META";
    return { done: false };
  }

  if (metaIssues.length > 0) {
    process.stderr.write(
      `[workflow-init] Stripping ${metaIssues.length} meta issue(s) from session: #${metaIssues.join(", #")}\n`
    );
    state.issues = issues.filter((n) => !(state.label_sets[n] || []).includes(META_LABEL));
  }

  return { done: false };
}

// Returns { ok: true, subIssues: [...] } or { ok: false, reason }, never a
// bare empty list — the caller routes success/failure differently.
function fetchSubIssues(ownerRepo, issueN) {
  // Defense-in-depth: checkpoint tampering could put a non-number here.
  if (!Number.isInteger(issueN) || issueN <= 0) return { ok: false, reason: "invalid_issue_number" };
  // per_page=100 (#2085): default page size 30 silently truncated the list.
  // Not --paginate: gh emits one JSON doc per page, breaking the JSON.parse below.
  const endpoint = `repos/${ownerRepo}/issues/${issueN}/sub_issues?per_page=100`;
  const [cmd, args, opts] = buildGhSpawn(["api", endpoint]);
  const result = spawnSync(cmd, args, opts);
  if (result.status !== 0 || !result.stdout) return { ok: false, reason: "gh_exec_failed" };
  try {
    const parsed = JSON.parse(result.stdout.trim());
    if (!Array.isArray(parsed)) return { ok: false, reason: "parse_failed" };
    return { ok: true, subIssues: parsed };
  } catch (_e) {
    return { ok: false, reason: "parse_failed" };
  }
}

module.exports = { metaClassify };
