// usage-stats.js — how often sessions reach for codegraph_explore versus the
// Grep/Glob/Read calls it replaces, counted from local Claude Code transcripts.
//
// usage: node bin/codegraph/usage-stats.js [--cutoff <ISO time>] [--since <YYYY-MM-DD>] [--root <dir>] [--by-day]
//   --cutoff  before/after boundary (omitted: everything is "before")
//   --since   ignore activity before this local date
//   --root    projects root (default: ~/.claude/projects)
//   --by-day  also print a per-day table
// exploreShare is a lower bound: Read also counts non-code reads (plans, docs).
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const readline = require("readline");

const EXPLORE = "mcp__codegraph__codegraph_explore";
const FILE_TOOLS = ["Grep", "Glob", "Read"];

function parseArgs(argv) {
  const opts = { cutoff: null, since: null, root: path.join(os.homedir(), ".claude", "projects"), byDay: false };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--cutoff") opts.cutoff = new Date(argv[++i]);
    else if (argv[i] === "--since") opts.since = argv[++i];
    else if (argv[i] === "--root") opts.root = argv[++i];
    else if (argv[i] === "--by-day") opts.byDay = true;
    else throw new Error("unknown argument: " + argv[i]);
  }
  if (opts.cutoff && Number.isNaN(opts.cutoff.getTime())) throw new Error("--cutoff is not a valid date");
  return opts;
}

// Main transcripts sit at <root>/<project>/<session>.jsonl; subagent ones under
// <root>/<project>/<session>/subagents/*.jsonl.
function listTranscripts(root) {
  const out = [];
  for (const project of fs.readdirSync(root, { withFileTypes: true })) {
    if (!project.isDirectory()) continue;
    const projectDir = path.join(root, project.name);
    for (const entry of fs.readdirSync(projectDir, { withFileTypes: true })) {
      if (entry.isFile() && entry.name.endsWith(".jsonl")) {
        out.push({ file: path.join(projectDir, entry.name), project: project.name, kind: "main" });
      } else if (entry.isDirectory()) {
        const subDir = path.join(projectDir, entry.name, "subagents");
        if (!fs.existsSync(subDir)) continue;
        for (const sub of fs.readdirSync(subDir)) {
          if (sub.endsWith(".jsonl")) out.push({ file: path.join(subDir, sub), project: project.name, kind: "sub" });
        }
      }
    }
  }
  return out;
}

function localDay(date) {
  return date.toLocaleDateString("sv-SE");
}

function emptyBucket() {
  return { transcripts: 0, withExplore: 0, withFileTools: 0, explore: 0, Grep: 0, Glob: 0, Read: 0, toolSearchCodegraph: 0 };
}

// One transcript → per-period counts. A transcript straddling the cutoff
// contributes to both periods, each with only its own calls.
async function scanTranscript(file, opts) {
  const perPeriod = new Map();
  const rl = readline.createInterface({ input: fs.createReadStream(file, "utf8"), crlfDelay: Infinity });
  for await (const line of rl) {
    if (!line.includes('"tool_use"')) continue;
    let rec;
    try {
      rec = JSON.parse(line);
    } catch (_) {
      continue;
    }
    if (rec.type !== "assistant" || !rec.message || !Array.isArray(rec.message.content)) continue;
    const at = new Date(rec.timestamp);
    if (Number.isNaN(at.getTime())) continue;
    const day = localDay(at);
    if (opts.since && day < opts.since) continue;
    const period = opts.cutoff && at >= opts.cutoff ? "after" : "before";
    for (const block of rec.message.content) {
      if (!block || block.type !== "tool_use") continue;
      const key = period + "|" + day;
      if (!perPeriod.has(key)) perPeriod.set(key, emptyBucket());
      const b = perPeriod.get(key);
      if (block.name === EXPLORE) b.explore += 1;
      else if (FILE_TOOLS.includes(block.name)) b[block.name] += 1;
      else if (block.name === "ToolSearch" && /codegraph/i.test(JSON.stringify(block.input || {}))) b.toolSearchCodegraph += 1;
    }
  }
  return perPeriod;
}

function add(into, from) {
  for (const k of Object.keys(from)) into[k] += from[k];
}

function share(b) {
  const total = b.explore + b.Grep + b.Glob + b.Read;
  return total === 0 ? "-" : ((100 * b.explore) / total).toFixed(1) + "%";
}

function row(label, b) {
  return [label, b.transcripts, b.withExplore, b.withFileTools, b.explore, b.Grep, b.Glob, b.Read, share(b), b.toolSearchCodegraph].join("\t");
}

const HEADER = ["bucket", "transcripts", "w/explore", "w/fileTools", "explore", "Grep", "Glob", "Read", "exploreShare", "ToolSearch(cg)"].join("\t");

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const summary = new Map(); // "<period>|<kind>" -> bucket
  const byDay = new Map(); // "<day>|<kind>" -> bucket
  for (const t of listTranscripts(opts.root)) {
    const perPeriod = await scanTranscript(t.file, opts);
    const seen = new Set();
    for (const [key, b] of perPeriod) {
      const [period, day] = key.split("|");
      for (const [map, k] of [[summary, period + "|" + t.kind], [byDay, day + "|" + t.kind]]) {
        if (!map.has(k)) map.set(k, emptyBucket());
        const agg = map.get(k);
        add(agg, b);
        // Count each transcript once per bucket, whatever its number of days.
        const once = k + "|" + (map === summary ? "s" : "d");
        if (!seen.has(once)) {
          seen.add(once);
          agg.transcripts += 1;
        }
      }
    }
    // "w/explore" / "w/fileTools" are per transcript and per period.
    for (const period of ["before", "after"]) {
      const parts = [...perPeriod].filter(([k]) => k.startsWith(period + "|")).map(([, v]) => v);
      if (parts.length === 0) continue;
      const agg = summary.get(period + "|" + t.kind);
      if (parts.some((p) => p.explore > 0)) agg.withExplore += 1;
      if (parts.some((p) => p.Grep + p.Glob + p.Read > 0)) agg.withFileTools += 1;
    }
  }

  console.log("cutoff: " + (opts.cutoff ? opts.cutoff.toISOString() : "(none)") + (opts.since ? "  since: " + opts.since : ""));
  console.log(HEADER);
  for (const period of ["before", "after"]) {
    for (const kind of ["main", "sub"]) {
      const b = summary.get(period + "|" + kind);
      if (b) console.log(row(period + "/" + kind, b));
    }
  }
  if (opts.byDay) {
    console.log("\n" + HEADER.replace("w/explore\tw/fileTools\t", "-\t-\t"));
    for (const key of [...byDay.keys()].sort()) {
      const [day, kind] = key.split("|");
      const b = byDay.get(key);
      console.log(row(day + "/" + kind, { ...b, withExplore: "-", withFileTools: "-" }));
    }
  }
}

main().catch((err) => {
  process.stderr.write(String(err && err.stack ? err.stack : err) + "\n");
  process.exit(1);
});
