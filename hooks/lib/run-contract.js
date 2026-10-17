// hooks/lib/run-contract.js — the one RUN_CONTRACT parser and formatter (#2501).
// Shapes: "current" (6 fields) and "legacy" (4 fields; unrunnable/timeout null, never 0, because a
// pre-#2501 run-all counted a missing runtime as SKIP). Only "current" may complete run_tests.
// Format SSOT: docs/architecture/claude-code/test-result-contract.md; run-all-report.sh prints it
// (and the `Missing runtimes:` line runtimeLabels reads) too.

"use strict";

// Loose: what counts as a contract line at all (counting, stripping, neutralizing).
const CONTRACT_PREFIX_RE = /^[ \t]*RUN_CONTRACT:/;
const CONTRACT_LINE_RE =
  /^[ \t]*RUN_CONTRACT: PASS=(\d+) FAIL=(\d+) SKIP=(\d+) EXECUTED=(\d+)(?: UNRUNNABLE=(\d+) TIMEOUT=(\d+)(?: HITS=(\d+))?)?[ \t]*\r?$/;

// parseContractLine(line) — the contract, or null for anything not exactly one well-formed,
// self-consistent line (EXECUTED = PASS+FAIL+SKIP; TIMEOUT <= FAIL in the current shape).
function parseContractLine(line) {
  if (typeof line !== "string") return null;
  const m = CONTRACT_LINE_RE.exec(line);
  if (m === null) return null;
  const nums = m.slice(1, 5).map((v) => Number(v));
  const current = m[5] !== undefined;
  const extra = current ? [Number(m[5]), Number(m[6]), m[7] === undefined ? 0 : Number(m[7])] : [];
  if ([...nums, ...extra].some((n) => !Number.isSafeInteger(n))) return null;
  const [pass, fail, skip, executed] = nums;
  if (executed !== pass + fail + skip) return null;
  const unrunnable = current ? extra[0] : null;
  const timeout = current ? extra[1] : null;
  if (current && timeout > fail) return null;
  // hits: unattributed guard/decoy/worktree hits (#2669); an absent HITS= and HITS=0 are one value.
  const hits = current ? extra[2] : 0;
  return { shape: current ? "current" : "legacy", pass, fail, skip, executed, unrunnable, timeout, hits };
}

// findSingleContract(lines) — the contract when exactly one line matches the loose prefix and
// that line parses strictly; otherwise {reason: "absent" | "ambiguous" | "invalid"}.
function findSingleContract(lines) {
  const hits = (Array.isArray(lines) ? lines : []).filter(
    (l) => typeof l === "string" && CONTRACT_PREFIX_RE.test(l));
  if (hits.length === 0) return { reason: "absent" };
  if (hits.length > 1) return { reason: "ambiguous" };
  const c = parseContractLine(hits[0]);
  return c === null ? { reason: "invalid" } : c;
}

// formatContract(contract) — the line for a parsed contract, in its own shape.
function formatContract(c) {
  const head = `RUN_CONTRACT: PASS=${c.pass} FAIL=${c.fail} SKIP=${c.skip} EXECUTED=${c.executed}`;
  if (c.shape === "legacy") return head;
  const hits = Number.isSafeInteger(c.hits) && c.hits > 0 ? ` HITS=${c.hits}` : "";
  return `${head} UNRUNNABLE=${c.unrunnable} TIMEOUT=${c.timeout}${hits}`;
}

// runtimeLabels(list) — the labels of a `Missing runtimes: <label> (<n> files), ...` list, in
// line order, as "a,b"; null when none parses. A label outside the registry's label charset is
// dropped: the text is suite output, and the accept handler echoes what is recorded.
const RUNTIME_ITEM_RE = /^([A-Za-z0-9._+~^<>=!-]{1,64}) \(\d+ files?\)$/;
function runtimeLabels(list) {
  if (typeof list !== "string") return null;
  const labels = list.split(", ").map((s) => RUNTIME_ITEM_RE.exec(s.trim())).filter((m) => m !== null).map((m) => m[1]);
  return labels.length > 0 ? labels.join(",") : null;
}

module.exports = {
  CONTRACT_PREFIX_RE, CONTRACT_LINE_RE, parseContractLine, findSingleContract, formatContract, runtimeLabels,
};
