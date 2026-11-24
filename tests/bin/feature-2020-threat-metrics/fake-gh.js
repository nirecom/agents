"use strict";
// Stub of `gh api` for tests/bin/feature-2020-threat-metrics.js (#2020). GH_FIXTURE names a JSON
// file {pages: [[issue...], ...], repo: {...}}. An issues path prints every page back to back
// (as gh --paginate does) only when --paginate is passed; without it, only the first page.
// A bare repos/<o>/<r> path prints the repo object. Each call is logged to GH_STUB_LOG.
const fs = require("node:fs");

const args = process.argv.slice(2);
if (process.env.GH_STUB_LOG) fs.appendFileSync(process.env.GH_STUB_LOG, `${JSON.stringify(args)}\n`);
const fx = JSON.parse(fs.readFileSync(process.env.GH_FIXTURE, "utf8"));
const target = args.find((a) => /^\/?(repos|search)\//.test(a)) || "";
if (args[0] !== "api" || target === "") {
  process.stderr.write(`fake gh: unsupported call: ${args.join(" ")}\n`);
  process.exit(1);
}
if (/^\/?search\/issues/.test(target)) {
  process.stdout.write(`${JSON.stringify({ total_count: fx.repo.issue_total, items: [] })}\n`);
} else if (/\/issues(\?|$)/.test(target)) {
  const pages = args.includes("--paginate") ? fx.pages : fx.pages.slice(0, 1);
  for (const p of pages) process.stdout.write(JSON.stringify(p));
  process.stdout.write("\n");
} else if (/^\/?repos\/[^/]+\/[^/?]+$/.test(target)) {
  process.stdout.write(`${JSON.stringify(fx.repo)}\n`);
} else {
  process.stderr.write(`fake gh: unknown path ${target}\n`);
  process.exit(1);
}
