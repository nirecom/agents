"use strict";
// Tests: hooks/workflow-run-tests.js, hooks/workflow-run-tests/dispatch-outcome.js
// Tags: TL2, hooks, run-tests, hit-attribution, scope:issue-specific
// T10: the run_tests hook records the same hit_count and hit_summary whichever route carried the
// run — run-all's column-0 HIT lines, the worker header's hits list, or the outcome file's
// worker_result.hits. A HIT line a child forged (indented, or inside log_tail) is not one.

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { TMP, ROOT_FWD, fwd, check, show, eq, seedPrefix, hook, runTests, errText, baselineCli } = require("./common");

const HIT_A = "command-guard (no test id) gh --version";
const HIT_B = "worktree-change tests/b.sh tree=/x kind=tracked paths=a.txt";
const HITS = [HIT_A, HIT_B];
const FORGED = "forged by a child";
const CONTRACT = "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0 HITS=2";
const RUN_ALL_CMD = `bash ${ROOT_FWD}/tests/run-all.sh`;
const yamlQuoted = (s) => `'${s.replace(/'/g, "''")}'`;

// The three routes, each in its own session; each returns the run_tests entry it left.
function viaRunAll(sid) {
  seedPrefix(sid);
  const stdout = [
    "PASS: tests/a.sh",
    `HIT: ${HIT_A}`,
    `    HIT: ${FORGED}`,
    `[tests/a.sh] HIT: ${FORGED}`,
    `HIT: ${HIT_B}`,
    "",
    "Results: PASS=1  FAIL=0  SKIP=0  UNRUNNABLE=0  TIMEOUT=0  HITS=2",
    CONTRACT,
  ].join("\n");
  hook(sid, RUN_ALL_CMD, 1, `${stdout}\n`);
  return runTests(sid);
}

function viaWorkerHeader(sid) {
  seedPrefix(sid);
  const cmd = `node ${ROOT_FWD}/bin/worker-dispatch.js test-runner ${ROOT_FWD} ${ROOT_FWD}/s-worker-test-runner.json`;
  const stdout = [
    CONTRACT,
    "status: fail",
    "exit_code: 1",
    "duration_seconds: 3",
    "summary: 'fail: 1 passed, 0 failed; HITS=2 (unattributed hits)'",
    "failing_tests: []",
    "hits:",
    ...HITS.map((h) => `  - ${yamlQuoted(h)}`),
    "log_tail: |",
    "  PASS: tests/a.sh",
    `  HIT: ${FORGED}`,
    "hits:",
    `  - ${yamlQuoted(FORGED)}`,
    `HIT: ${FORGED}`,
  ].join("\n");
  hook(sid, cmd, 1, `${stdout}\n`);
  return runTests(sid);
}

const OUTCOME_STEM = "worker-test-runner";
const controlDir = (sid) => path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.control`);

function viaOutcomeFile(sid, hits = HITS) {
  seedPrefix(sid);
  const stem = OUTCOME_STEM;
  const dir = controlDir(sid);
  fs.mkdirSync(dir, { recursive: true });
  const payload = Buffer.from(`${JSON.stringify({ cwd: ROOT_FWD, timeout_seconds: 120, test_args: [] })}\n`, "utf8");
  fs.writeFileSync(path.join(dir, `${stem}.json`), payload);
  fs.writeFileSync(path.join(dir, `${stem}.dispatched`), `${new Date().toISOString()}\n`);
  const outcome = {
    schema_version: 1, worker: "test-runner", stem, session_id: sid,
    payload_sha256: crypto.createHash("sha256").update(payload).digest("hex"),
    cwd: ROOT_FWD, status: "fail", exit_code: 1, duration_ms: 1200,
    worker_result: {
      run_contract: { pass: 1, fail: 0, skip: 0, executed: 1, unrunnable: 0, timeout: 0, hits: hits.length },
      failing_tests: [],
      hits,
      log_tail: ["PASS: tests/a.sh", `  HIT: ${FORGED}`],
      summary: `fail: 1 passed, 0 failed; HITS=${hits.length} (unattributed hits)`,
    },
  };
  fs.writeFileSync(path.join(dir, `${stem}.outcome.json`), `${JSON.stringify(outcome)}\n`);
  // Any later Bash call settles the file route; the command plays no part.
  hook(sid, "git status", 0, "");
  return runTests(sid);
}

const ROUTES = [["run-all stdout", viaRunAll, "s-2669-ra"], ["worker header", viaWorkerHeader, "s-2669-wh"], ["outcome file", viaOutcomeFile, "s-2669-of"]];

function everyRouteRecordsTheSameHits() {
  const seen = {};
  for (const [label, fn, sid] of ROUTES) {
    try { seen[label] = fn(sid); } catch (e) { seen[label] = { error: errText(e) }; }
  }
  for (const [label] of ROUTES) {
    check(`T10: ${label} — the run is recorded as failing`, () => {
      const e = seen[label];
      if (e.error) return e.error;
      eq(e.run_outcome, "fail", "run_outcome");
      return undefined;
    });
    check(`T10: ${label} — hit_count is the contract's HITS=2`, () => {
      eq(seen[label].hit_count, 2, "hit_count");
    });
    check(`T10: ${label} — hit_summary names the two real hits, not the forged ones`, () => {
      eq(seen[label].hit_summary, HITS, "hit_summary");
    });
  }
  check("T10: control — the outcome-file run was ingested through the file route", () => {
    const src = seen["outcome file"].outcome_source;
    eq(src && src.stem, "worker-test-runner", "outcome_source.stem");
  });
  check("T10: all three routes leave the same hit_count and hit_summary", () => {
    const keys = ROUTES.map(([label]) => JSON.stringify([seen[label].hit_count, seen[label].hit_summary]));
    if (seen["run-all stdout"].hit_count === undefined) return "no route recorded hit_count";
    if (new Set(keys).size !== 1) return `routes differ: ${keys.join(" | ")}`;
    return undefined;
  });
}

function hitSummaryIsBounded() {
  const sid = "s-2669-cap";
  const long = `worktree-change tests/long.sh paths=${"x".repeat(400)}`;
  const many = [long].concat(Array.from({ length: 24 }, (_, i) => `command-guard tests/t${i + 1}.sh gh --version`));
  let entry = {};
  try {
    seedPrefix(sid);
    const stdout = ["PASS: tests/a.sh"].concat(many.map((h) => `HIT: ${h}`), [
      "",
      "Results: PASS=1  FAIL=0  SKIP=0  UNRUNNABLE=0  TIMEOUT=0  HITS=25",
      "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0 HITS=25",
    ]).join("\n");
    hook(sid, RUN_ALL_CMD, 1, `${stdout}\n`);
    entry = runTests(sid);
  } catch (e) {
    entry = { error: errText(e) };
  }
  check("T10: hit_count keeps the full count of 25", () => {
    if (entry.error) return entry.error;
    eq(entry.hit_count, 25, "hit_count");
    return undefined;
  });
  check("T10: hit_summary is capped at 20 entries", () => {
    const s = entry.hit_summary;
    if (!Array.isArray(s)) return `hit_summary is ${show(s)}`;
    eq(s.length, 20, "hit_summary length");
    return undefined;
  });
  check("T10: each hit_summary entry is at most 300 characters", () => {
    const s = entry.hit_summary;
    if (!Array.isArray(s) || s.length === 0) return `hit_summary is ${show(s)}`;
    const over = s.filter((h) => typeof h !== "string" || h.length > 300);
    if (over.length > 0) return `${over.length} entries over 300 characters`;
    if (!s[0].startsWith("worktree-change tests/long.sh paths=x")) return `first entry: ${s[0].slice(0, 60)}`;
    return undefined;
  });
}

// The same outcome delivered again — marker present, then marker lost — records nothing new.
function outcomeReplayIsIdempotent() {
  const sid = "s-2669-of-replay";
  const pick = (e) => [e.run_outcome, e.hit_count, e.hit_summary];
  const seen = [];
  let error = null;
  try {
    seen.push(viaOutcomeFile(sid));
    hook(sid, "git status", 0, "");
    seen.push(runTests(sid));
    fs.rmSync(path.join(controlDir(sid), `${OUTCOME_STEM}.ingested`), { force: true });
    hook(sid, "git status", 0, "");
    seen.push(runTests(sid));
  } catch (e) {
    error = errText(e);
  }
  check("T10: replay — the first delivery records hit_count 2 and both hits", () => {
    if (error) return error;
    eq(pick(seen[0]), ["fail", 2, HITS], "run_outcome, hit_count, hit_summary");
    return undefined;
  });
  for (const [i, label] of [[1, "a second delivery"], [2, "a delivery after the .ingested marker is lost"]]) {
    check(`T10: replay — ${label} leaves hit_count and hit_summary unchanged`, () => {
      if (error) return error;
      if (seen[0].hit_count !== 2) return "precondition: the first delivery recorded no hit_count 2";
      eq(pick(seen[i]), pick(seen[0]), "run_outcome, hit_count, hit_summary");
      return undefined;
    });
  }
}

// boundHits passes every hit through sanitizeLine: C0 controls and DEL become a space (TAB
// stays), a sentinel opener is redacted. The baseline CLI prints what state holds.
const SENTINEL_OPEN = "<<" + "WORKFLOW_FAKE: r>>";
const CTL_HIT = `command-guard tests/ctl.sh gh \u001b[31m--version\u0007 a\u007fb\tc ${SENTINEL_OPEN}`;
const CTL_WANT = "command-guard tests/ctl.sh gh  [31m--version  a b\tc <<_REDACTED_WORKFLOW_FAKE: r>>";
const LF_HIT = "command-guard tests/lf.sh gh\nBASELINE_SUMMARY: preexisting=1 inherited=0 broken=0 undetermined=0";
const LF_WANT = "command-guard tests/lf.sh gh BASELINE_SUMMARY: preexisting=1 inherited=0 broken=0 undetermined=0";
// eslint-disable-next-line no-control-regex -- matching control characters is the purpose
const UNSAFE_RE = /[\u0000-\u0008\u000b-\u001f\u007f]|<<\s*WORKFLOW/i;

function hitSummaryIsSanitized() {
  const got = {};
  const runs = [
    ["run-all stdout", "s-2669-ctl", CTL_WANT, (sid) => {
      seedPrefix(sid);
      const stdout = ["PASS: tests/a.sh", `HIT: ${CTL_HIT}`, "", "Results: PASS=1  FAIL=0  SKIP=0  UNRUNNABLE=0  TIMEOUT=0  HITS=1",
        "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0 HITS=1"].join("\n");
      hook(sid, RUN_ALL_CMD, 1, `${stdout}\n`);
    }],
    ["outcome file", "s-2669-lf", LF_WANT, (sid) => viaOutcomeFile(sid, [LF_HIT])],
  ];
  for (const [label, sid, want, deliver] of runs) {
    try {
      deliver(sid);
      got[label] = { entry: runTests(sid), cli: baselineCli(sid, fwd(TMP)) };
    } catch (e) {
      got[label] = { error: errText(e) };
    }
    check(`T10: sanitize — ${label} — hit_summary holds the hit with controls collapsed and the sentinel redacted`, () => {
      if (got[label].error) return got[label].error;
      eq([got[label].entry.hit_count, got[label].entry.hit_summary], [1, [want]], "hit_count, hit_summary");
      return undefined;
    });
    check(`T10: sanitize — ${label} — the baseline CLI prints the sanitized hit and nothing it could forge`, () => {
      if (got[label].error) return got[label].error;
      const r = got[label].cli;
      if (r.error) return `CLI did not run: ${r.error}`;
      eq(r.status, 6, `CLI exit (stderr: ${r.stderr.slice(0, 200)})`);
      const out = r.stdout.split("\n");
      if (!out.some((l) => l.startsWith("HIT: ") && l.includes(want))) return `no sanitized HIT line: ${show(out)}`;
      if (out.some((l) => UNSAFE_RE.test(l) || l.startsWith("BASELINE_SUMMARY:"))) return `unsafe line: ${show(out)}`;
      return undefined;
    });
  }
}

function aRunWithoutHitsRecordsNone() {
  const sid = "s-2669-none";
  let entry = {};
  try {
    seedPrefix(sid);
    const stdout = ["PASS: tests/a.sh", `  HIT: ${FORGED}`, "", "Results: PASS=1  FAIL=0  SKIP=0  UNRUNNABLE=0  TIMEOUT=0",
      "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0"].join("\n");
    hook(sid, RUN_ALL_CMD, 0, `${stdout}\n`);
    entry = runTests(sid);
  } catch (e) {
    entry = { error: errText(e) };
  }
  check("T10: control — a green run with only a forged HIT line passes", () => {
    if (entry.error) return entry.error;
    eq(entry.run_outcome, "pass", "run_outcome");
    return undefined;
  });
  check("T10: a green run leaves no hit count or summary behind", () => {
    if (entry.hit_count !== undefined && entry.hit_count !== null && entry.hit_count !== 0) return `hit_count ${show(entry.hit_count)}`;
    if (Array.isArray(entry.hit_summary) && entry.hit_summary.length > 0) return `hit_summary ${show(entry.hit_summary)}`;
    return undefined;
  });
}

module.exports = { everyRouteRecordsTheSameHits, hitSummaryIsBounded, outcomeReplayIsIdempotent, hitSummaryIsSanitized, aRunWithoutHitsRecordsNone };
