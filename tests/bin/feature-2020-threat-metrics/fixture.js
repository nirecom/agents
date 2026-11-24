"use strict";
// Private fixture of tests/bin/feature-2020-threat-metrics.js (#2020 layer 3). The caller runs
// isolate() first; every scenario gets its own WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR pair.
// Contract assumed of bin/review-threat-metrics <pre-boundary|post-boundary> --json [--seed N]
// [--plans-dir D]: stdout is one JSON object; ratios are fractions in [0,1]; `claude` is
// CLAUDE_BIN, `gh` is looked up on PATH; both are run through bash
// (bin/workflow/lib/workflow-init/spawn-env.js). REVIEW_THREAT_METRICS_BOUNDARY_AT stands in for
// the boundary introduction commit time, so the v0 period does not depend on the checkout's git log.
// Findings carry a `kw-<A>-<B>-<category>` token that fake-claude.js answers from.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const fwd = (p) => p.replace(/\\/g, "/");
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "tm2020-"));
const BIN = path.join(TMP, "bin");
fs.mkdirSync(BIN);
const shim = (name, js) => {
  const f = path.join(BIN, name);
  fs.writeFileSync(f, `#!/usr/bin/env bash\nexec node '${fwd(path.join(__dirname, js))}' "$@"\n`, { mode: 0o755 });
  return f;
};
shim("gh", "fake-gh.js");
const CLAUDE = shim("claude-stub", "fake-claude.js");

let n = 0;
// scenario() — a fresh state dir, stub logs and a gh fixture holder.
function scenario(name) {
  const dir = path.join(TMP, `${name}-${++n}`);
  fs.mkdirSync(path.join(dir, "state"), { recursive: true });
  fs.mkdirSync(path.join(dir, "plans"), { recursive: true });
  return {
    dir,
    state: path.join(dir, "state"),
    plans: path.join(dir, "plans"),
    ctl: (sid) => path.join(dir, "state", `${sid}.control`),
    claudeLog: path.join(dir, "claude.log"),
    ghLog: path.join(dir, "gh.log"),
    ghFixture: path.join(dir, "gh.json"),
  };
}

// The boundary introduction time every scenario runs under; V0_AT is a session before it, POST_AT after.
const BOUNDARY_AT = "2025-01-01T00:00:00Z";
const V0_AT = "2020-01-01T00:00:00Z";
const POST_AT = "2099-01-01T00:00:00Z";

// session(sc, sid, createdAt) — the session's state file (<state>/<sid>.json) with created_at.
function session(sc, sid, createdAt) {
  fs.writeFileSync(path.join(sc.state, `${sid}.json`), JSON.stringify({ session_id: sid, created_at: createdAt }));
}

const sevs = ["HIGH", "MEDIUM", "LOW"];
// carrier(sc, sid, fmt, texts, extraOpen, createdAt) — a carrier with one REJECTED line per text;
// the session gets a state file at createdAt (V0_AT by default) unless createdAt is null.
function carrier(sc, sid, fmt, texts, extraOpen = [], createdAt = V0_AT) {
  fs.mkdirSync(sc.ctl(sid), { recursive: true });
  if (createdAt !== null && !fs.existsSync(path.join(sc.state, `${sid}.json`))) session(sc, sid, createdAt);
  const lines = ["### Prior concerns (open + rejected — reference these; do NOT re-raise rejected ones)"];
  texts.forEach((t, i) => lines.push(`- d${String(i).padStart(7, "0")} [${sevs[i % 3]}] REJECTED ${t} — reason: settled`));
  extraOpen.forEach((t, i) => lines.push(`- o${String(i).padStart(7, "0")} [LOW] ${t}`));
  fs.writeFileSync(path.join(sc.ctl(sid), `${fmt}-concern-carrier.md`), `${lines.join("\n")}\n`);
}

// texts(count, A, B, cat, stem) — distinct finding texts of one class.
const texts = (count, A, B, cat, stem) =>
  Array.from({ length: count }, (_, i) => `${stem} number ${i} in bin/x${i}.sh kw-${A}-${B}-${cat}`);

// findingIssue(num, text | [text...], extra) — a filed issue carrying one finding line per text.
const findingIssue = (num, text, extra = {}) => ({
  number: num, title: `codex review finding ${num}`, state: "closed", created_at: "2020-02-01T00:00:00Z",
  body: `Filed from the codex review (detail-plan).\n\n## Concern Delta\n${[].concat(text).map((t, i) => `${i + 1}. [HIGH] ${t}`).join("\n")}\n`,
  ...extra,
});
const noiseIssue = (num) => ({ number: num, title: `Feature request ${num}`, state: "open", created_at: "2020-02-01T00:00:00Z",
  body: "Please add a dark theme." });
const originMarker = (sid) => `<!-- origin-session: ${sid} -->`;

// ghIssues(sc, items) — the gh fixture from raw issue objects (one page, no PR).
function ghIssues(sc, items) {
  fs.writeFileSync(sc.ghFixture, JSON.stringify({ pages: [items], repo: { full_name: "example/repo", open_issues_count: 7, issue_total: items.length } }));
}

// journalRows(sc, sid, fmt, rows) — j1 rows written straight into <CTL>/<fmt>-concern-journal.tsv:
// {discrim, round, reviewer, kind, category, axisA, axisB, text, version}; a row without `version`
// is the old 15-column form.
function journalRows(sc, sid, fmt, rows) {
  fs.mkdirSync(sc.ctl(sid), { recursive: true });
  const ls = rows.map((r) => {
    const c = ["j1", "2026-01-01T00:00:00Z", sid, fmt, String(r.round || 1), "review-plan-codex", r.reviewer || "codex",
      r.kind || "concern", r.category, r.axisA, r.axisB, r.discrim, "0123456789abcdef", "unknown", r.text];
    if (r.version !== undefined) c.push(r.version);
    return c.join("\t");
  });
  fs.appendFileSync(path.join(sc.ctl(sid), `${fmt}-concern-journal.tsv`), `${ls.join("\n")}\n`);
}

// ghPages(sc, findingTexts, noise, perPage) — finding issues + noise issues + one PR, paged.
function ghPages(sc, findingTexts, noise, perPage = 20) {
  const items = findingTexts.map((t, i) => findingIssue(1000 + i, t));
  for (let i = 0; i < noise; i++) items.push(noiseIssue(2000 + i));
  items.splice(3, 0, { ...findingIssue(3000, "a pull request kw-A2-B1-security"), pull_request: { url: "x" } });
  const pages = [];
  for (let i = 0; i < items.length; i += perPage) pages.push(items.slice(i, i + perPage));
  const issueTotal = items.length - 1;
  fs.writeFileSync(sc.ghFixture, JSON.stringify({ pages, repo: { full_name: "example/repo", open_issues_count: 7, issue_total: issueTotal } }));
  return { fetched: issueTotal, extracted: findingTexts.length };
}

function env(sc, extra = {}) {
  const e = { ...process.env, WORKFLOW_STATE_DIR: sc.state, WORKFLOW_PLANS_DIR: sc.plans,
    REVIEW_THREAT_METRICS_BOUNDARY_AT: BOUNDARY_AT, CLAUDE_BIN: fwd(CLAUDE), CLAUDECODE: "1",
    CLAUDE_STUB_LOG: sc.claudeLog, GH_STUB_LOG: sc.ghLog, GH_FIXTURE: sc.ghFixture, ...extra };
  const key = Object.keys(e).find((k) => k.toUpperCase() === "PATH") || "PATH";
  e[key] = `${BIN}${path.delimiter}${e[key]}`;
  for (const k of Object.keys(e)) if (e[k] === undefined) delete e[k];
  return e;
}

// metrics(sc, args, extra, ms) — bin/review-threat-metrics; {status, out, err, json}. An extra
// value of undefined removes that variable (TL3 drops CLAUDE_BIN to reach the real claude).
function metrics(sc, args, extra = {}, ms = 120000) {
  const r = spawnSync("bash", [fwd(path.join(ROOT, "bin", "review-threat-metrics")), ...args],
    { cwd: sc.dir, env: env(sc, extra), encoding: "utf8", timeout: ms });
  let json = null;
  try {
    json = JSON.parse(r.stdout);
  } catch {
    json = null;
  }
  return { status: r.status, out: r.stdout || "", err: `${r.stderr || ""}${r.error ? r.error.message : ""}`, json };
}

// run(sc, rel, args) — another CLI of the checkout under the scenario env.
function run(sc, rel, args) {
  const r = spawnSync("bash", [fwd(path.join(ROOT, rel)), ...args], { cwd: sc.dir, env: env(sc), encoding: "utf8", timeout: 60000 });
  return { status: r.status, out: r.stdout || "", err: r.stderr || "" };
}

const lines = (f) => (fs.existsSync(f) ? fs.readFileSync(f, "utf8").split("\n").filter(Boolean) : []);
const claudeCalls = (sc) => lines(sc.claudeLog).map((l) => JSON.parse(l));
const ghCalls = (sc) => lines(sc.ghLog).map((l) => JSON.parse(l));
const cleanup = () => fs.rmSync(TMP, { recursive: true, force: true });

// journal(sc, sid, fmt) — the j1 rows of <CTL>/<fmt>-concern-journal.tsv (columns 7, 8, 12, 15).
const journal = (sc, sid, fmt) => lines(path.join(sc.ctl(sid), `${fmt}-concern-journal.tsv`))
  .map((l) => l.split("\t")).map((c) => ({ reviewer: c[6], kind: c[7], discrim: c[11], text: c[14] }));

// rejectRows(sc, sid, fmt, rows) — a carrier whose REJECTED lines carry those journal rows' DISCRIMs.
function rejectRows(sc, sid, fmt, rows) {
  fs.mkdirSync(sc.ctl(sid), { recursive: true });
  const body = rows.map((r) => `- ${r.discrim} [LOW] REJECTED ${r.text} — reason: settled`);
  fs.writeFileSync(path.join(sc.ctl(sid), `${fmt}-concern-carrier.md`),
    `${["### Prior concerns (open + rejected — reference these; do NOT re-raise rejected ones)", ...body].join("\n")}\n`);
}

module.exports = { scenario, session, carrier, texts, ghPages, ghIssues, findingIssue, noiseIssue, originMarker,
  journalRows, metrics, run, claudeCalls, ghCalls, cleanup, journal, rejectRows, ROOT, BOUNDARY_AT, V0_AT, POST_AT };
