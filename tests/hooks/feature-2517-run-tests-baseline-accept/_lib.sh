# shellcheck shell=bash
# tests/hooks/feature-2517-run-tests-baseline-accept/_lib.sh
# Tests: hooks/workflow-mark/run-tests-baseline-accept-handler.js
# Tags: TL2, hooks, workflow-mark, run-tests, baseline, helpers, scope:issue-specific
# Shared helpers for tests/hooks/feature-2517-run-tests-baseline-accept.sh, sourced after the
# dispatcher's harness_isolate. Probes are files in $T, so no multi-line `node -e` precedes a case.

AGENTS_N="$(np "$SCRIPT_CHECKOUT_ROOT")"
MARK_HOOK="$AGENTS_N/hooks/workflow-mark.js"
HANDLER_JS="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-mark/run-tests-baseline-accept-handler.js"
SP_JS="$AGENTS_N/hooks/lib/sentinel-patterns.js"
SENT="WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED"
UA_SENT="WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED"
FIXTURE_REPO="$T/repo"
harness_git_init "$FIXTURE_REPO" >/dev/null 2>&1 || fail "fixture repo" "git init failed"
REASON_OK="these failures predate the branch on main"

# payload.js <command> <sid-or-empty> <cwd> — a workflow-mark PostToolUse payload.
cat >"$T/payload.js" <<'EOF'
const [cmd, sid, cwd] = process.argv.slice(2);
const p = { tool_name: "Bash", transcript_path: null, tool_input: { command: cmd, cwd },
  tool_response: { exit_code: 0, stdout: "" } };
if (sid) p.session_id = sid;
process.stdout.write(JSON.stringify(p));
EOF

# st.js <agents> <mode> <sid> ... — state reads/writes through the real workflow-state module.
#   field <sid> <step> <key>          string as-is, other values as JSON, (absent)
#   path <sid> <step> <key> <a.b>     a value inside an object annotation, same rendering
#   seed <sid> <step> <status> [k v]… markStep; values parsed as JSON when they parse
#   ann <sid> <key> <json>            one run_tests annotation, no step_status (seq unchanged)
cat >"$T/st.js" <<'EOF'
const [agents, mode, sid, ...a] = process.argv.slice(2);
const S = require(agents + "/hooks/workflow-state");
const show = (v) => (v === undefined || v === null ? "(absent)" : typeof v === "string" ? v : JSON.stringify(v));
const val = (s) => { try { return JSON.parse(s); } catch (e) { return s; } };
const entry = (step) => { const s = S.readState(sid); return (s && s.steps && s.steps[step]) || {}; };
if (mode === "field") {
  process.stdout.write(show(entry(a[0])[a[1]]));
} else if (mode === "path") {
  let v = entry(a[0])[a[1]];
  for (const k of a[2].split(".")) v = v === undefined || v === null ? undefined : v[k];
  process.stdout.write(show(v));
} else if (mode === "seed") {
  const extra = {};
  for (let i = 2; i + 1 < a.length; i += 2) extra[a[i]] = val(a[i + 1]);
  S.markStep(sid, a[0], a[1], extra);
} else if (mode === "ann") {
  const { appendEvents } = require(agents + "/hooks/workflow-state/state-io/events");
  appendEvents(sid, [{ kind: "step_annotation", step: "run_tests", key: a[0], value: val(a[1]),
    provenance: "observed", origin: "run-tests-hook" }]);
}
EOF

# st <mode> <sid> … — st.js's answer, or (error) when the module throws.
st() { run_with_timeout 30 node "$T/st.js" "$AGENTS_N" "$@" 2>/dev/null | tr -d '\r' || printf '(error)'; }

# snap <sid> — the run_tests fields an accept could write; equal before/after means "unchanged".
snap() {
  printf 'status=%s seq=%s grant=%s basis=%s outcome=%s' "$(st field "$1" run_tests status)" \
    "$(st field "$1" run_tests updated_seq)" "$(st field "$1" run_tests baseline_accept)" \
    "$(st field "$1" run_tests completion_basis)" "$(st field "$1" run_tests run_outcome)"
}

# mark <sid-or-empty> <command> — the real workflow-mark.js; stdout and stderr together.
mark() {
  node "$T/payload.js" "$2" "$1" "$(np "$FIXTURE_REPO")" >"$T/in-mark.json"
  run_with_timeout 30 node "$MARK_HOOK" <"$T/in-mark.json" 2>&1 | tr -d '\r' || true
}

acc_cmd() { printf 'echo "<<%s: %s>>"' "$SENT" "$1"; }
ua_cmd() { printf 'echo "<<%s: %s>>"' "$UA_SENT" "$1"; }
# unpipe <text> — a table cell's %PIPE% back to `|` (tables use IFS='|', so a literal pipe is encoded).
unpipe() { local tok='%PIPE%'; printf '%s' "${1//"$tok"/|}"; }

# msg_has <label> <ERE> <text> — case-insensitive.
msg_has() {
  if printf '%s' "$3" | grep -Eiq -- "$2"; then pass "$1"; else fail "$1" "no /$2/i in: $3"; fi
}

CLS_UNDET='{"base":"abc123","entries":[{"path":"tests/a.sh","class":"undetermined","detail":"home-claude-ref"},{"path":"tests/b.sh","class":"preexisting","detail":""}]}'
CLS_BROKEN='{"base":"abc123","entries":[{"path":"tests/a.sh","class":"undetermined","detail":"timeout-at-base"},{"path":"tests/b.sh","class":"broken","detail":""}]}'

# setup_state <sid> <kind> — write_tests settled, then run_tests in the named shape.
#   undet:     fail run, two failing paths, an undetermined-only classification
#   nolist:    fail run, failing_tests null           (failing-list-unrecorded)
#   emptylist: fail run, failing_tests []             (failing-list-unrecorded)
#   timeout / runner-error: nolist with that run_outcome
#   noclass:   fail run, failing paths, no classification
#   broken:    fail run, classification with a broken entry
#   complete / pass / unrun / unrcount: the states the grant must refuse
setup_state() {
  local sid="$1"
  st seed "$sid" write_tests complete >/dev/null
  case "$2" in
    undet) st seed "$sid" run_tests pending run_outcome fail unrunnable_count 0 \
             failing_tests '["tests/a.sh","tests/b.sh"]' baseline_classification "$CLS_UNDET" >/dev/null ;;
    nolist) st seed "$sid" run_tests pending run_outcome fail unrunnable_count 0 failing_tests null >/dev/null ;;
    emptylist) st seed "$sid" run_tests pending run_outcome fail unrunnable_count 0 failing_tests '[]' >/dev/null ;;
    timeout|runner-error) st seed "$sid" run_tests pending run_outcome "$2" unrunnable_count 0 >/dev/null ;;
    noclass) st seed "$sid" run_tests pending run_outcome fail unrunnable_count 0 \
               failing_tests '["tests/a.sh"]' >/dev/null ;;
    broken) st seed "$sid" run_tests pending run_outcome fail unrunnable_count 0 \
              failing_tests '["tests/a.sh","tests/b.sh"]' baseline_classification "$CLS_BROKEN" >/dev/null ;;
    complete) st seed "$sid" run_tests complete run_outcome pass >/dev/null ;;
    pass) st seed "$sid" run_tests pending run_outcome pass >/dev/null ;;
    unrun) st seed "$sid" run_tests pending run_outcome unrunnable unrunnable_count 2 >/dev/null ;;
    unrcount) st seed "$sid" run_tests pending run_outcome fail unrunnable_count 1 \
                failing_tests '["tests/a.sh"]' >/dev/null ;;
  esac
}
