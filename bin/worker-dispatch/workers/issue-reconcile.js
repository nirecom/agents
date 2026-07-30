"use strict";
// bin/worker-dispatch/workers/issue-reconcile.js
//
// Stage 2 worker: replaces agents/issue-reconcile-worker.md.
//
// Read-only scan of CLOSED issues, classifying each as clean / history-only /
// needs-reconcile. The registry entry declares `gh` as the only external binary
// and `plans-dir` as the only write scope, so this worker cannot mutate an issue
// or touch the repository even if it tried.
//
// Paging: the agent this replaces instructed a per-page flag that gh has never
// had; the LLM quietly ignored it and the scan silently stopped at one page. A
// plain script cannot paper over that, so paging is expressed the way gh
// actually supports it — a single `--limit` bounded scan, with the cap surfaced
// in the summary when it is reached rather than being passed off as a full scan.
// tests/TL3-worker-dispatch-gh-contract.sh fences both directions against the
// real binary, including a source scan for the phantom flag — so do not name it
// here even in prose.

const fs = require("fs");
const path = require("path");

const { run: spawnRun } = require("../spawn");

const GH_TIMEOUT_MS = 300000;
const JSON_FIELDS = "number,title,comments";
const SENTINEL_PREFIX = "<!-- issue-close-sentinel: appended";
const MAX_HISTORY_FILES = 500;

function stamp() {
  // Compact UTC stamp; artifact names must sort chronologically and stay
  // filesystem-safe on Windows (no colons).
  return new Date().toISOString().replace(/[:.]/g, "-").replace(/Z$/, "Z");
}

// gh returns comments as an array of objects; older shapes and unexpected values
// must degrade to "no sentinel found", never throw mid-scan.
function hasSentinelComment(issue) {
  const comments = issue && Array.isArray(issue.comments) ? issue.comments : [];
  for (const c of comments) {
    const body = c && typeof c.body === "string" ? c.body : "";
    if (body.trimStart().startsWith(SENTINEL_PREFIX)) return true;
  }
  return false;
}

function readIfFile(p) {
  if (typeof p !== "string" || p === "") return null;
  try {
    if (!fs.statSync(p).isFile()) return null;
    return fs.readFileSync(p, "utf8");
  } catch (_e) {
    return null;
  }
}

// Concatenated text of every history source the payload named. Read once up
// front: a per-issue re-read would turn an O(issues) scan into O(issues x files)
// for no gain, and the corpus is small enough to hold.
function loadHistoryCorpus(payload) {
  const parts = [];
  const md = readIfFile(payload.history_md_path);
  if (md !== null) parts.push(md);

  const dir = payload.history_dir_path;
  if (typeof dir === "string" && dir !== "") {
    let names = [];
    try {
      names = fs.readdirSync(dir);
    } catch (_e) {
      names = [];
    }
    for (const name of names.slice(0, MAX_HISTORY_FILES)) {
      const text = readIfFile(path.join(dir, name));
      if (text !== null) parts.push(text);
    }
  }
  return parts.join("\n");
}

// A history entry references the issue as `#<N>:`. The trailing colon is what
// distinguishes an entry heading from a passing mention, and the leading
// non-digit boundary keeps `#164` from matching `#1643`.
function hasHistoryEntry(corpus, number) {
  if (corpus === "") return false;
  const needle = `#${number}:`;
  let from = 0;
  for (;;) {
    const at = corpus.indexOf(needle, from);
    if (at === -1) return false;
    const before = at === 0 ? "" : corpus[at - 1];
    if (!/[0-9]/.test(before)) return true;
    from = at + needle.length;
  }
}

function classify(issue, corpus) {
  if (hasSentinelComment(issue)) return "clean";
  return hasHistoryEntry(corpus, issue.number) ? "history-only" : "needs-reconcile";
}

function parseIssues(stdout) {
  let parsed = null;
  try {
    parsed = JSON.parse(stdout);
  } catch (_e) {
    return null;
  }
  if (!Array.isArray(parsed)) return null;
  return parsed.filter(
    (i) => i && typeof i === "object" && Number.isInteger(i.number) && i.number > 0
  );
}

function run(payload, ctx) {
  const { anchors, fsguard } = ctx;
  const limit = typeof payload.limit === "number" ? payload.limit : 1000;

  let res = null;
  try {
    res = spawnRun(ctx.entry, {
      anchors,
      command: "gh",
      args: [
        "issue", "list",
        "--repo", payload.owner_repo,
        "--state", "closed",
        "--limit", String(limit),
        "--json", JSON_FIELDS,
      ],
      cwd: anchors.mainRoot,
      timeoutMs: GH_TIMEOUT_MS,
    });
  } catch (e) {
    return {
      status: "failed",
      summary: `could not start gh: ${e && e.message ? e.message : "unknown error"}`,
      artifactPath: "(none)",
    };
  }

  if (res.timedOut) {
    return {
      status: "failed",
      summary: `gh issue list exceeded its ${Math.round(GH_TIMEOUT_MS / 1000)}s budget`,
      artifactPath: "(none)",
    };
  }
  if (res.spawnError !== null) {
    return { status: "failed", summary: `gh could not run: ${res.spawnError}`, artifactPath: "(none)" };
  }
  if (res.status !== 0) {
    const detail = (res.stderr || res.stdout || "").split("\n").find((l) => l.trim() !== "") || "";
    return {
      status: "failed",
      summary: `gh issue list exited ${res.status}: ${detail}`,
      artifactPath: "(none)",
    };
  }

  const issues = parseIssues(res.stdout);
  if (issues === null) {
    return { status: "failed", summary: "gh issue list did not return a JSON array", artifactPath: "(none)" };
  }

  const corpus = loadHistoryCorpus(payload);
  const counts = { clean: 0, "history-only": 0, "needs-reconcile": 0 };
  const jsonl = [];
  for (const issue of issues) {
    const classification = classify(issue, corpus);
    counts[classification] += 1;
    // Only needs-reconcile rows are emitted; clean and history-only are counted
    // for the summary but deliberately withheld from the artifact so the caller
    // reads a worklist, not a census.
    if (classification !== "needs-reconcile") continue;
    jsonl.push(
      JSON.stringify({
        number: issue.number,
        title: typeof issue.title === "string" ? issue.title : "",
        state: "closed",
        classification,
      })
    );
  }

  const base = `${stamp()}-issue-reconcile-worker`;
  const dir = payload.artifact_dir || anchors.plansDir;
  const jsonlPath = path.join(dir, `${base}.jsonl`);
  const logPath = path.join(dir, `${base}.log`);

  let written = null;
  try {
    written = fsguard.writeFile(jsonlPath, jsonl.length === 0 ? "" : `${jsonl.join("\n")}\n`);
  } catch (e) {
    return {
      status: "failed",
      summary: `artifact write refused: ${e && e.message ? e.message : "unknown error"}`,
      artifactPath: "(none)",
    };
  }

  const capped = issues.length >= limit;
  const summary =
    `${issues.length} scanned; ${counts["needs-reconcile"]} to reconcile` +
    ` (${counts.clean} clean, ${counts["history-only"]} history-only)` +
    (capped ? `; --limit ${limit} reached — scan may be incomplete` : "");

  // The log is best-effort: losing it must not turn a completed scan into a
  // reported failure, since the JSONL worklist is the actual deliverable.
  try {
    fsguard.writeFile(
      logPath,
      [
        `repo: ${payload.owner_repo}`,
        `limit: ${limit}`,
        `scanned: ${issues.length}`,
        `clean: ${counts.clean}`,
        `history-only: ${counts["history-only"]}`,
        `needs-reconcile: ${counts["needs-reconcile"]}`,
        `limit-reached: ${capped ? "yes" : "no"}`,
        `artifact: ${written}`,
        "",
      ].join("\n")
    );
  } catch (_e) {
    // ignore
  }

  return { status: "complete", summary, artifactPath: written };
}

module.exports = { run, classify, hasSentinelComment, hasHistoryEntry, parseIssues };
