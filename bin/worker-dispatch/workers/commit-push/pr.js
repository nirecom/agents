"use strict";
// bin/worker-dispatch/workers/commit-push/pr.js
//
// Step 9 of the commit-push procedure: the idempotent PR step, plus the title
// and body derivations it needs. Split out of the parent module because the
// parent owns the D1 gate seam and must stay readable as one procedure
// (rules/coding/file-split.md Pattern A, entrypoint-private sibling folder).
//
// Nothing here decides WHETHER a PR is wanted — steps 8's enforce_worktree and
// non-GitHub-remote checks answer that before this module is reached.

const { run: spawnRun } = require("../../spawn");
// In-process forge resolution (C1): the worker is Node, so it requires the pure
// resolver directly — runScript is bash-fixed and cannot launch a Node shebang.
// No cycle: these modules do not require this file; readGitlabHostConfig only
// reads .env (readEffectiveEnvFile), a side-effect-free call.
const { resolveForgeTarget } = require("../../../../hooks/lib/parse-remote-url");
const { readGitlabHostConfig } = require("../../../../hooks/lib/forge-router");

const GH_TIMEOUT_MS = 120000;

// glab api project endpoints take the path URL-encoded (`/` -> `%2F`) so a nested
// namespace (group/subgroup/project) addresses correctly.
function encodePath(p) {
  return String(p).split("/").map(encodeURIComponent).join("%2F");
}

// GitHub renders a PR title of ~72 characters without truncating it in the list
// view; the same first-line-of-the-commit rule `gh pr create --fill` follows.
const TITLE_MAX = 72;
const TITLE_CUT = 69;

const PR_URL_RE = /(https?:\/\/github\.com\/[^/\s]+\/[^/\s]+\/pull\/\d+)/;

function firstLine(text) {
  return String(text === null || text === undefined ? "" : text).split(/\r?\n/, 1)[0].trim();
}

// (a) the commit message's first line, truncated. Only when that yields nothing
// does the fallback chain run, so the common path costs no extra process.
function titleFromCommitMessage(commitMessage) {
  const line = firstLine(commitMessage);
  if (line === "") return "";
  return line.length > TITLE_MAX ? `${line.slice(0, TITLE_CUT)}...` : line;
}

// `closes_issues` elements are { number, repo? } records — the shape
// hooks/lib/parse-closes-issues.js returns and the registry's `issue-ref[]` type
// validates. The repo half is part of the issue's identity and must reach both
// the closing keyword and the marker: dropping it makes #42 in two repositories
// indistinguishable.

// GitHub's cross-repo closing-keyword form is `owner/repo#N`; a local issue is
// plain `#N`. Nothing else closes an issue in another repository.
function escapeRe(s) {
  return String(s).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function refToken(ref) {
  return ref.repo ? `${ref.repo}#${ref.number}` : `#${ref.number}`;
}

// The marker `bin/github-issues/find-pr-by-marker.sh` searches for is repo-local
// by construction: it queries one repository's PRs for the bare number. A local
// entry therefore keeps that exact literal, while a cross-repo entry is qualified
// so it cannot be mistaken for the local issue of the same number.
function markerFor(ref) {
  return `<!-- issue-close-pr-of: ${ref.repo ? `${ref.repo}#${ref.number}` : ref.number} -->`;
}

function closesList(payload) {
  const raw = Array.isArray(payload.closes_issues) ? payload.closes_issues : [];
  return raw.filter((r) => r !== null && typeof r === "object" && Number.isInteger(r.number));
}

// (b) the first closing issue's own title, then the branch name. `gh` failing
// here is not an error: a PR with a branch-name title is strictly better than no
// PR at all.
function prTitle(payload, ctx) {
  const fromMessage = titleFromCommitMessage(payload.commit_message);
  if (fromMessage !== "") return fromMessage;

  const closes = closesList(payload);
  if (closes.length > 0) {
    const first = closes[0];
    // `--repo` only when the record carries a qualified owner/repo: `gh` resolves
    // a bare repo name against no owner, and a wrong lookup here would title the
    // PR after somebody else's issue. Unqualified cross-repo entries fall through
    // to the branch-name title instead.
    const args = ["issue", "view", String(first.number), "--json", "title", "--jq", ".title"];
    if (typeof first.repo === "string" && first.repo.includes("/")) {
      args.push("--repo", first.repo);
    }
    let res = null;
    try {
      res = spawnRun(ctx.entry, {
        anchors: ctx.anchors,
        command: "gh",
        args,
      envScope: ["GH_TOKEN", "GITHUB_TOKEN"],
        cwd: payload.worktree_path,
        timeoutMs: GH_TIMEOUT_MS,
      });
    } catch (_e) {
      res = null;
    }
    if (res && res.status === 0) {
      const title = titleFromCommitMessage(res.stdout);
      if (title !== "") return title;
    }
  }
  return payload.branch;
}

// The two strings GitHub and /issue-close-finalize act on. A caller-supplied
// template that omits either one is COMPLETED rather than rejected: the marker is
// how find-pr-by-marker.sh resolves the merge SHA later, and silently shipping a
// PR without it breaks the close path long after this worker has exited.
function prBody(payload) {
  const closes = closesList(payload);
  const supplied = typeof payload.pr_body_template === "string" ? payload.pr_body_template : "";

  const parts = [];
  if (supplied.trim() !== "") {
    parts.push(supplied.replace(/\s+$/, ""));
  } else {
    const summary = firstLine(payload.commit_message);
    parts.push("## Summary", "", summary === "" ? payload.branch : summary);
  }

  const missing = [];
  for (const ref of closes) {
    const closesLine = `Closes ${refToken(ref)}`;
    // The token is ESCAPED before it becomes a pattern — `.` is both a legal
    // repo-name character and a regex metacharacter — and the trailing
    // digit-boundary is kept: without it `Closes #4` matches inside `Closes #42`
    // and issue 4 is reported as already covered by a body that only closes 42.
    if (!new RegExp(`${escapeRe(closesLine)}(?![0-9])`).test(supplied)) missing.push(closesLine);
    const marker = markerFor(ref);
    if (supplied.indexOf(marker) === -1) missing.push(marker);
  }
  if (missing.length > 0) parts.push("", ...missing);

  return `${parts.join("\n")}\n`;
}

function urlFrom(text) {
  const m = PR_URL_RE.exec(String(text === null || text === undefined ? "" : text));
  return m ? m[1] : "";
}

// --- outbound scan ---------------------------------------------------------
// A spawned child is not a Bash-tool command, so hooks/scan-outbound.js never
// sees this PR text; the worker runs bin/scan-outbound.sh itself, same scanner
// and `--stdin <label>` contract as bin/lib/gh-outbound-guard.sh. FAIL CLOSED:
// only rc 0 is clean (1 violation, 2 warn-tier with no confirm channel, 3 usage,
// unstartable scanner all block). Content on stdin, never argv (see spawn.js).
// Why: docs/architecture/claude-code/worker-dispatch/commit-push.md.
const SCAN_LABEL = "pr-title-and-body";

function scanOutbound(payload, ctx, content, log) {
  let res = null;
  try {
    res = spawnRun(ctx.entry, {
      anchors: ctx.anchors,
      command: "bash",
      script: "scanOutbound",
      args: ["--stdin", SCAN_LABEL],
      envScope: [],
      cwd: payload.worktree_path,
      timeoutMs: GH_TIMEOUT_MS,
      input: content,
    });
  } catch (e) {
    const msg = e && e.message ? e.message : "unknown error";
    log.push(`scan-outbound could not start: ${msg}`);
    return `outbound scan could not be run (${msg})`;
  }
  log.push(`scan-outbound -> status=${res.status}`, res.stdout, res.stderr);
  if (res.timedOut) return "outbound scan timed out";
  if (res.spawnError !== null) return `outbound scan could not be run (${res.spawnError})`;
  if (res.status === 0) return null;
  const detail = `${res.stdout || ""}\n${res.stderr || ""}`
    .split(/\r?\n/)
    .map((l) => l.trim())
    .find((l) => l !== "") || "";
  return `outbound scan rejected the PR text (rc=${res.status})${detail === "" ? "" : `: ${detail}`}`;
}

// Shared in-process forge gate (C1): procedure.js's Step 8 and ensurePullRequest
// both read origin through this one helper, so their forge verdicts cannot
// diverge. Reads origin once via `git` (allowlisted; no credentials), then the
// pure resolver + readGitlabHostConfig. Fail-safe { type: "unknown", project:
// null } on any failure — the caller then skips the PR rather than guessing.
function resolveForgeForWorktree(payload, ctx, log) {
  let originUrl = "";
  try {
    const res = spawnRun(ctx.entry, {
      anchors: ctx.anchors,
      command: "git",
      args: ["remote", "get-url", "origin"],
      envScope: [],
      cwd: payload.worktree_path,
      timeoutMs: GH_TIMEOUT_MS,
    });
    if (res && res.status === 0) originUrl = String(res.stdout || "").trim();
  } catch (e) {
    if (log) log.push(`resolveForgeForWorktree: git could not start: ${e && e.message ? e.message : "unknown error"}`);
    return { type: "unknown", project: null };
  }
  if (originUrl === "") return { type: "unknown", project: null };
  const gitlabHost = readGitlabHostConfig(payload.worktree_path);
  const { type, project } = resolveForgeTarget(originUrl, { gitlabHost });
  return { type, project };
}

// GitLab MR path (mirrors the gh path below). Uses glab mr view/create subcommands
// (CPR-ORTH with gh pr view/create); body travels on stdin (--description-file -)
// for the same Windows cmdline-cap reason as gh's --body-file -.
function ensureMergeRequestGitlab(payload, ctx, log, project) {
  if (!project) {
    return { status: "pushed", summary: `${payload.branch} pushed; PR skipped (GitLab project path unresolved)`, url: "" };
  }
  const enc = encodePath(project);
  const glab = (args, input) =>
    spawnRun(ctx.entry, {
      anchors: ctx.anchors,
      command: "glab",
      args,
      envScope: ["GITLAB_TOKEN", "GITLAB_HOST"],
      cwd: payload.worktree_path,
      timeoutMs: GH_TIMEOUT_MS,
      input,
    });

  // Reuse an already-open MR for this source branch.
  let existing = null;
  try {
    existing = glab(["mr", "view", "--source-branch", payload.branch, "--output", "json"]);
  } catch (e) {
    log.push(`glab mr view could not start: ${e && e.message ? e.message : "unknown error"}`);
    return { status: "pushed", summary: `${payload.branch} pushed; PR step skipped (glab unavailable)`, url: "" };
  }
  log.push(`glab mr view -> status=${existing.status}`, existing.stdout, existing.stderr);
  if (existing.status === 0) {
    let parsed = null;
    try { parsed = JSON.parse(existing.stdout); } catch (_e) {}
    if (parsed && parsed.state === "opened" && typeof parsed.web_url === "string" && parsed.web_url !== "") {
      return { status: "pr_reused", summary: `${payload.branch} pushed; PR reused at ${JSON.stringify(parsed)}`, url: parsed.web_url };
    }
  }

  const title = prTitle(payload, ctx);
  const body = prBody(payload);

  const blocked = scanOutbound(payload, ctx, `${title}\n\n${body}`, log);
  if (blocked !== null) {
    return { status: "pushed", summary: `${payload.branch} pushed; PR withheld: ${blocked}`, url: "" };
  }

  // Resolve the target (default) branch via REST; fall back to main.
  let target = "main";
  try {
    const def = glab(["api", `projects/${enc}`, "--jq", ".default_branch"]);
    log.push(`glab default_branch -> status=${def.status}`, def.stdout, def.stderr);
    if (def.status === 0) {
      const d = String(def.stdout || "").trim();
      if (d !== "" && !d.startsWith("{")) target = d;
    }
  } catch (_e) {
    target = "main";
  }

  let create = null;
  try {
    create = glab(
      ["mr", "create",
       "--source-branch", payload.branch,
       "--target-branch", target,
       "--title", title,
       "--description-file", "-",
       "--yes"],
      body,
    );
  } catch (e) {
    log.push(`glab mr create could not start: ${e && e.message ? e.message : "unknown error"}`);
    return { status: "pushed", summary: "pushed; PR creation could not start", url: "" };
  }
  log.push(`glab mr create -> status=${create.status}`, create.stdout, create.stderr);

  const url = String(create.stdout || "").trim();
  if (create.status !== 0 || url === "") {
    const detail = (create.stderr || create.stdout || "").split("\n").find((l) => l.trim() !== "") || "";
    return { status: "pushed", summary: `${payload.branch} pushed; PR creation failed: ${detail}`, url: "" };
  }
  return { status: "pr_created", summary: `${payload.branch} pushed; PR created at ${url}`, url };
}

// Step 9. Returns { status, summary, url, log } — never throws: a spawn refusal
// is reported as a failed PR step over a push that already succeeded. Forge is
// resolved through the shared in-process gate; gitlab routes to the MR path.
function ensurePullRequest(payload, ctx, log) {
  const { type: forge, project } = resolveForgeForWorktree(payload, ctx, log);
  if (forge === "gitlab") return ensureMergeRequestGitlab(payload, ctx, log, project);

  let view = null;
  try {
    view = spawnRun(ctx.entry, {
      anchors: ctx.anchors,
      command: "gh",
      args: ["pr", "view", "--json", "state,url"],
      envScope: ["GH_TOKEN", "GITHUB_TOKEN"],
      cwd: payload.worktree_path,
      timeoutMs: GH_TIMEOUT_MS,
    });
  } catch (e) {
    log.push(`gh pr view could not start: ${e && e.message ? e.message : "unknown error"}`);
    return { status: "pushed", summary: "pushed; PR step skipped (gh unavailable)", url: "" };
  }
  log.push(`gh pr view -> status=${view.status}`, view.stdout, view.stderr);

  if (view.status === 0) {
    let parsed = null;
    try {
      parsed = JSON.parse(view.stdout);
    } catch (_e) {
      parsed = null;
    }
    if (parsed && parsed.state === "OPEN" && typeof parsed.url === "string" && parsed.url !== "") {
      return {
        status: "pr_reused",
        summary: `${payload.branch} pushed; PR reused at ${parsed.url}`,
        url: parsed.url,
      };
    }
  }

  const title = prTitle(payload, ctx);
  const body = prBody(payload);

  // Both strings in one pass — they land in the same outbound document, and the
  // scanner is line-oriented so a title on its own line is judged exactly as it
  // would be inside the body.
  const blocked = scanOutbound(payload, ctx, `${title}\n\n${body}`, log);
  if (blocked !== null) {
    // The push already succeeded, so this is not a hard failure — the same
    // treatment a failed `gh pr create` gets below. The PR is simply withheld:
    // redact the offending text and re-run /commit-push to create it.
    return {
      status: "pushed",
      summary: `${payload.branch} pushed; PR withheld: ${blocked}`,
      url: "",
    };
  }

  let create = null;
  try {
    // `--body-file -`, never `--body <text>`. pr_body_template is caller free text
    // bounded at 60000 characters by the registry schema, and Windows CreateProcess
    // caps a whole command line at 32767 — so a large template fails the SPAWN,
    // after commit and push have already landed and with no way to retry the PR
    // step idempotently. The body travels on stdin instead, the same channel
    // `git commit -F -` uses for the commit message, and the same `--body-file -`
    // convention bin/github-issues/issue-body-append.sh already follows.
    create = spawnRun(ctx.entry, {
      anchors: ctx.anchors,
      command: "gh",
      args: ["pr", "create", "--head", payload.branch, "--title", title, "--body-file", "-"],
      envScope: ["GH_TOKEN", "GITHUB_TOKEN"],
      cwd: payload.worktree_path,
      timeoutMs: GH_TIMEOUT_MS,
      input: body,
    });
  } catch (e) {
    log.push(`gh pr create could not start: ${e && e.message ? e.message : "unknown error"}`);
    return { status: "pushed", summary: "pushed; PR creation could not start", url: "" };
  }
  log.push(`gh pr create -> status=${create.status}`, create.stdout, create.stderr);

  const url = urlFrom(create.stdout) || urlFrom(create.stderr);
  if (create.status !== 0 || url === "") {
    const detail =
      (create.stderr || create.stdout || "").split("\n").find((l) => l.trim() !== "") || "";
    return {
      status: "pushed",
      summary: `${payload.branch} pushed; PR creation failed: ${detail}`,
      url: "",
    };
  }
  return {
    status: "pr_created",
    summary: `${payload.branch} pushed; PR created at ${url}`,
    url,
  };
}

module.exports = {
  ensurePullRequest,
  resolveForgeForWorktree,
  prTitle,
  prBody,
  titleFromCommitMessage,
  urlFrom,
  refToken,
  markerFor,
};
