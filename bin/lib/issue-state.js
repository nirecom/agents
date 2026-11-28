"use strict";
// issueState(ref, homeRepo) -> "CLOSED" | "OPEN" | null: one `gh issue view` per ref (#3043).
// The repo is resolved through hooks/lib/issue-identity.js; a shorthand `r#N` without a home repo
// cannot be resolved and returns null without calling gh. Any gh failure or other answer is null.

const path = require("path");
const { spawnSync } = require("child_process");
const { normalizeHome, resolveRepo } = require(path.join(__dirname, "..", "..", "hooks", "lib", "issue-identity"));

const GH_TIMEOUT_MS = 15000;

function issueState(ref, homeRepo) {
  if (!ref || !Number.isInteger(Number(ref.number)) || Number(ref.number) <= 0) return null;
  const home = normalizeHome(homeRepo);
  const repo = resolveRepo(ref, home);
  if (repo && !repo.includes("/")) return null;
  const args = ["issue", "view", String(Number(ref.number))];
  if (repo) args.push("--repo", repo);
  args.push("--json", "state", "--jq", ".state");
  let r;
  try {
    r = spawnSync("gh", args, { encoding: "utf8", timeout: GH_TIMEOUT_MS, windowsHide: true });
  } catch (_) {
    return null;
  }
  if (!r || r.status !== 0 || typeof r.stdout !== "string") return null;
  const state = r.stdout.trim();
  return state === "CLOSED" || state === "OPEN" ? state : null;
}

module.exports = { issueState, GH_TIMEOUT_MS };
