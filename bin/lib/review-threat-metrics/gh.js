"use strict";
// bin/lib/review-threat-metrics/gh.js — filed issues through `gh api` (#2020): every page of
// state=all (PRs excluded), the repo-wide issue total, and the finding lines each issue carries.
const { spawnSync } = require("node:child_process");
const { buildGhSpawn } = require("../../workflow/lib/workflow-init/spawn-env");
const { ROOT, bodyOf } = require("./common");

// gh(args) — runs in this repo, so a {owner}/{repo} endpoint resolves whatever the caller's cwd is.
function gh(args) {
  const [cmd, a, opts] = buildGhSpawn(["api", ...args]);
  const r = spawnSync(cmd, a, { ...opts, cwd: ROOT, maxBuffer: 256 * 1024 * 1024 });
  if (r.status !== 0) throw new Error(`gh api ${args.join(" ")} failed: ${(r.stderr || r.error || "").toString().slice(0, 300)}`);
  return r.stdout || "";
}

// parseConcat(s) — the JSON values gh --paginate prints back to back.
function parseConcat(s) {
  const out = [];
  let depth = 0, start = -1, inStr = false, esc = false;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (inStr) {
      if (esc) esc = false;
      else if (ch === "\\") esc = true;
      else if (ch === "\"") inStr = false;
      continue;
    }
    if (ch === "\"") inStr = true;
    else if (ch === "[" || ch === "{") {
      if (depth === 0) start = i;
      depth += 1;
    } else if (ch === "]" || ch === "}") {
      depth -= 1;
      if (depth === 0) out.push(JSON.parse(s.slice(start, i + 1)));
    }
  }
  return out;
}

const FINDING_RES = [/^\s*(?:C?\d+)\.\s+\[(?:HIGH|MEDIUM|LOW)\]\s+(.+)$/,
  /^\s*(?:[-*]\s+)?\[(?:HIGH|MEDIUM|LOW)\]\s+\S+\s*\|[^|]*\|[^|]*\|\s*(.+)$/];

// findingLines(body) — [{text, raw}] per finding line of one issue body: text has its tags stripped
// (what the classifier sees), raw keeps them (what the journal's DISCRIM was computed from).
function findingLines(body) {
  const out = [];
  for (const l of String(body || "").split(/\r?\n/)) {
    for (const re of FINDING_RES) {
      const m = l.match(re);
      if (m) {
        const t = bodyOf(m[1]);
        if (t) out.push({ text: t, raw: m[1].trim() });
        break;
      }
    }
  }
  return out;
}

// findingsOf(body) — the finding texts (tags stripped) of one issue body.
const findingsOf = (body) => findingLines(body).map((f) => f.text);

// issues(repo) — {fetched, repo_total, items: [{number, created_at, body, findings: [text], raws: [raw]}]}.
function issues(repo) {
  const items = parseConcat(gh(["--paginate", `repos/${repo}/issues?state=all&per_page=100`]))
    .flatMap((v) => (Array.isArray(v) ? v : [v])).filter((i) => i && typeof i === "object" && !i.pull_request)
    .map((i) => {
      const f = findingLines(i.body);
      return { number: i.number, created_at: i.created_at, body: String(i.body || ""),
        findings: f.map((x) => x.text), raws: f.map((x) => x.raw) };
    });
  let total = items.length;
  try {
    const full = JSON.parse(gh([`repos/${repo}`])).full_name;
    const t = JSON.parse(gh([`search/issues?q=repo:${full}+type:issue&per_page=1`])).total_count;
    if (Number.isInteger(t)) total = t;
  } catch {
    // the repo total is informative only; fall back to the fetched count
  }
  return { fetched: items.length, repo_total: total, items };
}

module.exports = { issues, findingsOf, parseConcat };
