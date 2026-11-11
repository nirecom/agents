"use strict";

// Judges whether a PR's changed rules/ paths include a rule expanded at session start (#1694).
// stdin: changed rules/ paths, one per line. argv[2]: the PR-side worktree path.
// stdout: "yes" (some path is in EXPECTED_UNCONDITIONAL), "no" (none is), or "unreadable"
// (policy missing/unparseable/empty, or no worktree given — the caller fails safe to "required").
// The policy is read AS DATA via rules-policy-reader (never require()d: it is PR-editable).
// Always exits 0.

const fs = require("fs");
const path = require("path");
const { loadPolicyAsData } = require(path.resolve(__dirname, "../../../hooks/lib/rules-policy-reader.js"));

function judge(worktree, stdinText) {
  if (!worktree) return "unreadable";
  const policy = loadPolicyAsData(path.join(worktree, "hooks", "lib", "rules-injection-policy.js"));
  const expanded = new Set(policy.EXPECTED_UNCONDITIONAL);
  if (expanded.size === 0) return "unreadable";
  const changed = stdinText.split("\n").map((l) => l.replace(/\r$/, "")).filter(Boolean);
  return changed.some((p) => expanded.has(p)) ? "yes" : "no";
}

let verdict;
try {
  verdict = judge(process.argv[2], fs.readFileSync(0, "utf8"));
} catch (_) {
  verdict = "unreadable";
}
process.stdout.write(verdict + "\n");
