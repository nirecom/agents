"use strict";
// disposition.js — the #2688 allow-list: what `record` does with each classified failing test.
// proof: a base copy failed too; auto: a known cause that is no evidence against the change
// (completes, disclosed in the PR body); rerun: the classification itself did not finish
// (exit 8); pending: anything else, unknown details included (fail-closed).

const PROOF_CLASSES = ["preexisting", "preexisting-inherited"];
const AUTO_CLASSES = ["flaky-timeout-on-branch"];
const AUTO_UNDETERMINED = new Set([
  "ambiguous-exit-137",
  "ambiguous-exit-143",
  "skip-at-base",
  "unsupported-at-base",
  "base-launcher-predates-result-conversion",
  "timeout-at-base",
  "root-decoy-hit-at-base",
  "home-claude-ref",
]);
const RERUN_UNDETERMINED = new Set(["budget-exhausted", "worktree-create-failed", "exec-setup-failed"]);
const RERUN_STATE_RE = /^state-[A-Za-z0-9_]+-at-base$/;
// #2956 table 1: a file-level verdict (no case lines to compare) is auto for these details only;
// new-case-failure-on-branch is never in the allow-list, so it stays pending.
const FILE_VERDICT_CLASS = "file-verdict-preexisting";
const AUTO_FILE_VERDICT = new Set(["test-file-changed", "no-case-records"]);
const RENAME_SUFFIX_RE = /-via-rename:.*$/;

const BASIS = { PROOF: "baseline-preexisting", AUTO: "baseline-auto-accepted" };
const NOTE_MAX = 200;

// dispositionOf({ class, detail }) — "proof" | "auto" | "rerun" | "pending".
function dispositionOf(e) {
  if (PROOF_CLASSES.includes(e.class)) return "proof";
  if (AUTO_CLASSES.includes(e.class)) return "auto";
  if (e.class === FILE_VERDICT_CLASS) {
    return AUTO_FILE_VERDICT.has(String(e.detail).replace(RENAME_SUFFIX_RE, "")) ? "auto" : "pending";
  }
  if (e.class !== "undetermined") return "pending";
  if (AUTO_UNDETERMINED.has(e.detail)) return "auto";
  // A re-run request holds under a rename source too; auto stays exact so a suffixed auto detail is pending.
  const base = String(e.detail).replace(RENAME_SUFFIX_RE, "");
  if (RERUN_UNDETERMINED.has(base) || RERUN_STATE_RE.test(base)) return "rerun";
  return "pending";
}

// aggregate(entries) — { verdict: "pending"|"rerun"|"record", count, basis }.
// Any pending wins over any rerun request; a record is auto-accepted when any row is.
function aggregate(entries) {
  const by = { proof: [], auto: [], rerun: [], pending: [] };
  for (const e of entries) by[dispositionOf(e)].push(e);
  if (by.pending.length > 0) return { verdict: "pending", count: by.pending.length, basis: null };
  if (by.rerun.length > 0) return { verdict: "rerun", count: by.rerun.length, basis: null };
  return { verdict: "record", count: by.auto.length, basis: by.auto.length > 0 ? BASIS.AUTO : BASIS.PROOF };
}

// sanitizeNote(text) — one line of at most NOTE_MAX chars, or null when nothing is left.
function sanitizeNote(text) {
  if (typeof text !== "string") return null;
  const one = text.replace(/[\r\n]+/g, " ").trim().slice(0, NOTE_MAX);
  return one === "" ? null : one;
}

module.exports = { BASIS, NOTE_MAX, dispositionOf, aggregate, sanitizeNote };
