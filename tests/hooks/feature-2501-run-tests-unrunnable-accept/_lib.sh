# shellcheck shell=bash
# tests/hooks/feature-2501-run-tests-unrunnable-accept/_lib.sh
# Tests: hooks/workflow-mark/run-tests-accept-handler.js
# Tags: TL2, hooks, workflow-mark, run-tests, unrunnable, helpers, scope:issue-specific
# Shared helpers for tests/hooks/feature-2501-run-tests-unrunnable-accept.sh, sourced after the
# dispatcher's harness_isolate. Probes are files in $T, so no multi-line `node -e` precedes a marker.

AGENTS_N="$(np "$SCRIPT_CHECKOUT_ROOT")"
RUN_HOOK="$AGENTS_N/hooks/workflow-run-tests.js"
MARK_HOOK="$AGENTS_N/hooks/workflow-mark.js"
HANDLER_JS="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-mark/run-tests-accept-handler.js"
SP_JS="$AGENTS_N/hooks/lib/sentinel-patterns.js"
SENT="WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED"
# A real path in this repo, so provenance-identity.js's filesystem check verifies the emitter.
RUNALL_CMD="bash $AGENTS_N/tests/run-all.sh"
FIXTURE_REPO="$T/repo"
harness_git_init "$FIXTURE_REPO" >/dev/null 2>&1 || fail "fixture repo" "git init failed"
REASON_OK="Pester 5 cannot be installed on this CI host"

# payload.js run <command> <exit> <stdout> <sid> <cwd> | mark <command> <sid-or-empty> <cwd>
cat >"$T/payload.js" <<'EOF'
const [mode, ...a] = process.argv.slice(2);
let p;
if (mode === "run") {
  p = { tool_name: "Bash", session_id: a[3], tool_input: { command: a[0], cwd: a[4] },
    tool_response: { exit_code: parseInt(a[1], 10), stdout: a[2] } };
} else {
  p = { tool_name: "Bash", transcript_path: null, tool_input: { command: a[0], cwd: a[2] },
    tool_response: { exit_code: 0, stdout: "" } };
  if (a[1]) p.session_id = a[1];
}
process.stdout.write(JSON.stringify(p));
EOF

# st.js <agents> <mode> <sid> ... — state reads/writes through the real workflow-state module.
#   field <sid> <step> <key>          value | (absent)
#   seed <sid> <step> <status> [k v]… values parsed as JSON when they parse, else strings
#   seq <sid>                         workflow_init … write_code settled, as a real session leaves it
#   resume <sid>                      write_code's effective status and resolved_from
cat >"$T/st.js" <<'EOF'
const [agents, mode, sid, ...a] = process.argv.slice(2);
const S = require(agents + "/hooks/workflow-state");
const show = (v) => (v === undefined || v === null ? "(absent)" : String(v));
const val = (s) => { try { return JSON.parse(s); } catch (e) { return s; } };
if (mode === "field") {
  const s = S.readState(sid);
  const e = s && s.steps && s.steps[a[0]];
  process.stdout.write(show(e ? e[a[1]] : undefined));
} else if (mode === "seed") {
  const extra = {};
  for (let i = 2; i + 1 < a.length; i += 2) extra[a[i]] = val(a[i + 1]);
  S.markStep(sid, a[0], a[1], extra);
} else if (mode === "seq") {
  const seq = [["workflow_init", "complete"], ["clarify_intent", "complete"], ["research", "skipped"],
    ["outline", "skipped"], ["detail", "skipped"], ["branching_complete", "complete"],
    ["write_tests", "complete"], ["review_tests", "complete"], ["write_code", "complete"]];
  for (const [step, status] of seq) S.markStep(sid, step, status);
} else if (mode === "resume") {
  const { reconcileEffectiveState } = require(agents + "/hooks/workflow-state/effective-state");
  const eff = reconcileEffectiveState(S.readState(sid), sid, { resolveAll: true });
  const w = eff.steps.write_code || {};
  process.stdout.write(`write_code=${show(w.status)} from=${show(w.resolved_from)}`);
}
EOF

# st <mode> <sid> … — st.js's answer, or (error) when the module throws.
st() { run_with_timeout 30 node "$T/st.js" "$AGENTS_N" "$@" 2>/dev/null | tr -d '\r' || printf '(error)'; }

# snap <sid> — the run_tests fields an accept writes; equal before/after means "state unchanged".
snap() {
  printf 'status=%s basis=%s reason=%s runtimes=%s missing=%s' "$(st field "$1" run_tests status)" \
    "$(st field "$1" run_tests completion_basis)" "$(st field "$1" run_tests unrunnable_accept_reason)" \
    "$(st field "$1" run_tests unrunnable_runtimes)" "$(st field "$1" run_tests unrunnable_missing_files)"
}

# run_hook <sid> <exit> <stdout> [command] — the real workflow-run-tests.js on a run-all
# PostToolUse (or on [command], e.g. $WORKER_CMD for the worker-dispatch stdout route).
run_hook() {
  node "$T/payload.js" run "${4:-$RUNALL_CMD}" "$2" "$3" "$1" "$AGENTS_N" >"$T/in-run.json"
  run_with_timeout 30 node "$RUN_HOOK" <"$T/in-run.json" >/dev/null 2>&1 || true
}
WORKER_CMD="node $AGENTS_N/bin/worker-dispatch.js test-runner $AGENTS_N $T/s-worker.json"

# mark <sid-or-empty> <command> — the real workflow-mark.js; stdout and stderr together.
mark() {
  node "$T/payload.js" mark "$2" "$1" "$(np "$FIXTURE_REPO")" >"$T/in-mark.json"
  run_with_timeout 30 node "$MARK_HOOK" <"$T/in-mark.json" 2>&1 | tr -d '\r' || true
}

acc_cmd() { printf 'echo "<<%s: %s>>"' "$SENT" "$1"; }

# msg_has <label> <ERE> <text> — case-insensitive.
msg_has() {
  if printf '%s' "$3" | grep -Eiq -- "$2"; then pass "$1"; else fail "$1" "no /$2/i in: $3"; fi
}

OUT_UNRUN="Running tests/alpha.sh
PASS: alpha
UNRUNNABLE: tests/p.Tests.ps1 (missing: Pester>=5.0)
UNRUNNABLE: tests/q.Tests.ps1 (missing: Pester>=5.0)
Missing runtimes: Pester>=5.0 (2 files)

Results: PASS=3  FAIL=0  SKIP=0  UNRUNNABLE=2  TIMEOUT=0
RUN_CONTRACT: PASS=3 FAIL=0 SKIP=0 EXECUTED=3 UNRUNNABLE=2 TIMEOUT=0"

OUT_LEGACY="Running tests/alpha.sh
PASS: alpha

Results: PASS=5  FAIL=0  SKIP=0
RUN_CONTRACT: PASS=5 FAIL=0 SKIP=0 EXECUTED=5"

OUT_FAIL_UNRUN="Running tests/broken.sh
FAIL: tests/broken.sh (exit 1)
UNRUNNABLE: tests/p.Tests.ps1 (missing: Pester>=5.0)
Missing runtimes: Pester>=5.0 (1 files)

Results: PASS=2  FAIL=1  SKIP=0  UNRUNNABLE=1  TIMEOUT=0
RUN_CONTRACT: PASS=2 FAIL=1 SKIP=0 EXECUTED=3 UNRUNNABLE=1 TIMEOUT=0"

OUT_NOCONTRACT="Running tests/alpha.sh
PASS: alpha
UNRUNNABLE: tests/p.Tests.ps1 (missing: Pester>=5.0)"

OUT_GREEN="Running tests/alpha.sh
PASS: alpha

Results: PASS=5  FAIL=0  SKIP=0  UNRUNNABLE=0  TIMEOUT=0
RUN_CONTRACT: PASS=5 FAIL=0 SKIP=0 EXECUTED=5 UNRUNNABLE=0 TIMEOUT=0"

# #2646: every selected test is a file that no longer exists — run-all exits 77, nothing ran.
OUT_ALL_MISSING="UNRUNNABLE: tests/gone.sh (missing: test file)
UNRUNNABLE: tests/hooks/gone2.js (missing: test file)

Results: PASS=0  FAIL=0  SKIP=0  UNRUNNABLE=2  TIMEOUT=0
RUN_CONTRACT: PASS=0 FAIL=0 SKIP=0 EXECUTED=0 UNRUNNABLE=2 TIMEOUT=0"

# One missing runtime plus one missing test file; exit 77.
OUT_MIXED="UNRUNNABLE: tests/p.Tests.ps1 (missing: Pester>=5.0)
UNRUNNABLE: tests/gone.sh (missing: test file)
Missing runtimes: Pester>=5.0 (1 file)

Results: PASS=0  FAIL=0  SKIP=0  UNRUNNABLE=2  TIMEOUT=0
RUN_CONTRACT: PASS=0 FAIL=0 SKIP=0 EXECUTED=0 UNRUNNABLE=2 TIMEOUT=0"

# The worker-dispatch rendering of a run with two missing files and one missing runtime.
OUT_WORKER_MISSING="RUN_CONTRACT: PASS=0 FAIL=0 SKIP=0 EXECUTED=0 UNRUNNABLE=3 TIMEOUT=0
status: unrunnable
exit_code: 0
duration_seconds: 4
summary: 'Missing test files: 2; Missing runtimes: Pester>=5.0 (1 file); PASS=0 FAIL=0 SKIP=0 UNRUNNABLE=3'
failing_tests: []
log_tail: |
  UNRUNNABLE: tests/gone.sh (missing: test file)"

# setup_run <sid> <kind> — write_tests settled, then one real run. Kinds: unrun legacy fail
# nocontract green allmissing mixed worker-missing.
setup_run() {
  st seed "$1" write_tests complete >/dev/null
  case "$2" in
    unrun) run_hook "$1" 0 "$OUT_UNRUN" ;;
    legacy) run_hook "$1" 0 "$OUT_LEGACY" ;;
    fail) run_hook "$1" 1 "$OUT_FAIL_UNRUN" ;;
    nocontract) run_hook "$1" 0 "$OUT_NOCONTRACT" ;;
    green) run_hook "$1" 0 "$OUT_GREEN" ;;
    allmissing) run_hook "$1" 77 "$OUT_ALL_MISSING" ;;
    mixed) run_hook "$1" 77 "$OUT_MIXED" ;;
    worker-missing) run_hook "$1" 0 "$OUT_WORKER_MISSING" "$WORKER_CMD" ;;
  esac
}
