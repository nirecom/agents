"use strict";

const { spawnSync } = require("child_process");
const { buildGhSpawn, buildGitSpawn } = require("../spawn-env");
const { parseOriginOwnerRepo } = require("../../../../../hooks/lib/parse-remote-url");
const { sanitizeLine } = require("../../../../../hooks/lib/output-sanitize");

/**
 * Phase: meta-classify (#2087)
 *
 * Runs BEFORE wip-check so issues about to be stripped (mixed) or replaced by a
 * sub-issue selection (all-meta) never reach wip-state.sh — that raised a
 * spurious wip_conflict ask and could override another session's WIP ownership.
 * All-meta → open sub-issues ask meta_select, else path_decision=META; mixed →
 * strip the meta issues. Path A/B/C selection belongs to route-decision.
 */
function metaClassify(state) {
  const issues = state.issues;

  // meta_select resumes at fetch-issues, so this phase can re-run over a
  // different issue set. A META verdict from the earlier pass must not survive
  // a re-classification that no longer supports it.
  if (state.path_decision === "META") state.path_decision = null;

  // 0 meta of 0 issues is not "all meta": without this guard the all-meta
  // branch below fires on an empty set. route-decision owns zero-issues → C.
  if (issues.length === 0) return { done: false };

  const metaIssues = issues.filter((n) => (state.label_sets[n] || []).includes("meta"));

  if (metaIssues.length === issues.length) {
    // Repository identity is resolved once, from the checkout's origin remote,
    // and never per issue (#1899).
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
        // Fail CLOSED: a failed sub-issue lookup is indistinguishable from "no
        // open sub-issues" only if we let it be. Authorizing path_decision=META
        // on an API/auth/parse failure silently misroutes the session, so stop
        // and let the user fix the cause instead.
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
        // Security review MUST (F1): sub-issue titles are untrusted third-party
        // content from the gh sub_issues API, on par with the issue body/title
        // write-context.js strips under its CWE-77 contract. sanitizeLine is the
        // SSOT for that strip; the "|" replace additionally stops a title from
        // forging an extra selectable option in OPTIONS_DISPLAY's pipe-delimited
        // wire format (a plain sentinel strip would not catch that).
        const describe = (s) => `#${s.number}: ${sanitizeLine(s.title || "").replace(/\|/g, "/")}`;
        const listText = openSubs.map(describe).join(" | ");
        const optionsDisplay = openSubs.map(describe).concat(["abort"]).join("|");
        // Identity, not just number: a sub-issue may live in another repository,
        // and #N alone would later resolve against the checkout's own origin —
        // a different, unrelated issue that happens to share the number.
        state.meta_select_offered = openSubs.map((s) => ({
          number: s.number,
          ownerRepo: parseOwnerRepoFromApiUrl(s.repository_url) || origin.ownerRepo,
        }));
        // First-parent-wins would otherwise drop the sibling meta parents: the
        // meta_select answer replaces state.issues wholesale. Carry them so the
        // driver can re-append them and let the fetch-issues re-entry
        // re-classify each one instead of silently losing it.
        state.meta_select_pending = metaIssues.filter((m) => m !== n);
        return {
          ask: true,
          askId: "meta_select",
          question: `Issue #${n} is a meta issue with open sub-issues. Select one to work on: ${listText}`,
          options: optionsDisplay,
        };
      }
    }
    // state.issues is intentionally left as-is — for an all-meta session the
    // meta issue IS the session's subject, so write-context and Path-META
    // consumers still need it. wip-check.js filters meta-labelled issues out of
    // its own ownership check via state.label_sets, so it never reaches
    // wip-state.sh even though it stays in state.issues.
    state.path_decision = "META";
    return { done: false };
  }

  if (metaIssues.length > 0) {
    process.stderr.write(
      `[workflow-init] Stripping ${metaIssues.length} meta issue(s) from session: #${metaIssues.join(", #")}\n`
    );
    state.issues = issues.filter((n) => !(state.label_sets[n] || []).includes("meta"));
  }

  return { done: false };
}

// Repository identity comes from the ORIGIN remote alone — no fallback (#1899).
function resolveOwnerRepoFromOrigin() {
  const [cmd, args, opts] = buildGitSpawn(["remote", "get-url", "origin"]);
  const result = spawnSync(cmd, args, opts);
  if (result.status !== 0 || !result.stdout) {
    return { ok: false, message: "no 'origin' remote is configured" };
  }
  const url = String(result.stdout).split(/\r?\n/)[0].trim();
  const parsed = parseOriginOwnerRepo(url);
  if (!parsed.ok) return { ok: false, message: parsed.message };
  return { ok: true, ownerRepo: parsed.ownerRepo };
}

// gh's sub_issues items carry repository identity as an API URL
// ("https://api.github.com/repos/OWNER/REPO"). Returns "OWNER/REPO", or null
// when the field is absent or does not have that shape — the caller then falls
// back to the origin repo, the only identity already proven valid here.
const API_REPOS_PREFIX = "https://api.github.com/repos/";

function parseOwnerRepoFromApiUrl(repositoryUrl) {
  if (typeof repositoryUrl !== "string") return null;
  if (!repositoryUrl.startsWith(API_REPOS_PREFIX)) return null;
  const rest = repositoryUrl.slice(API_REPOS_PREFIX.length).replace(/\/+$/, "");
  return /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/.test(rest) ? rest : null;
}

/**
 * Returns { ok: true, subIssues: [...] } or { ok: false, reason }.
 * Fail CLOSED: every failure is distinguishable from an empty sub-issue list,
 * because the caller routes the session differently for each.
 */
function fetchSubIssues(ownerRepo, issueN) {
  // Security review LOW (F3), defense-in-depth: issueN reaches an authenticated
  // gh api path with no shape assertion at this sink, while ownerRepo is
  // charset-validated by parseOriginOwnerRepo above. Unreachable from CLI input
  // today (detect-issues types it as a number), but readCheckpoint validates
  // only the version field, so a tampered/corrupted checkpoint could otherwise
  // put an arbitrary string here. Reject before the endpoint string is even
  // built; reported as a failure, like the paths below.
  if (!Number.isInteger(issueN) || issueN <= 0) return { ok: false, reason: "invalid_issue_number" };
  // #2085: without per_page, gh answers with GitHub's default page size (30)
  // and the sub-issue list is silently truncated; 100 is the REST maximum.
  // Deliberately NOT `--paginate`: gh emits one JSON document PER PAGE (see
  // bin/github-issues/parent-all-closed-check.sh:32 and bin/issue-close-gate.sh:10,41,
  // which both work around it with line-oriented awk/jq summation), so a second
  // page would make the single JSON.parse below throw and block the session as
  // parse_failed. A parent with >100 sub-issues is not a practical shape; that
  // residual truncation risk is accepted.
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
