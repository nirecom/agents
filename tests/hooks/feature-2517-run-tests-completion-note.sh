#!/usr/bin/env bash
# tests/hooks/feature-2517-run-tests-completion-note.sh
# Tests: hooks/lib/run-tests-completion-note.js, bin/workflow/run-tests-completion-note, bin/render-final-report.js, skills/_shared/commit-push-dispatch.md
# Tags: TL1, TL2, run-tests, final-report, baseline, unrunnable, disclosure, table-driven, scope:issue-specific
# A run_tests completed by a user grant instead of a proof must say so in the Final Report and the
# PR body (#2517). The note module (renamed from run-tests-unrunnable-note, #2501) returns one line
# for unrunnable-accepted (unchanged) and for baseline-user-accepted (two kinds), and null otherwise.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH"; exit 77; }

T="$(make_tmp)"
readonly T
trap 'rm -rf "$T"' EXIT
harness_isolate "$T/iso"
export WORKFLOW_STATE_DIR="$(np "$T/iso/workflow-state")" WORKFLOW_PLANS_DIR="$(np "$T/iso/plans")"
unset CLAUDE_CODE_SESSION_ID
# ck <name> <want> <got> — named equality (harness assert_eq takes <actual> <expected> only).
ck() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=[$2] got=[$3]"; fi; }
mkdir -p "$T/transcripts"
export CLAUDE_TRANSCRIPT_BASE_DIR="$T/transcripts"

ROOT="$(np "$SCRIPT_CHECKOUT_ROOT")"
NOTE_JS="$SCRIPT_CHECKOUT_ROOT/hooks/lib/run-tests-completion-note.js"
NOTE_CLI="$SCRIPT_CHECKOUT_ROOT/bin/workflow/run-tests-completion-note"
OLD_JS="$SCRIPT_CHECKOUT_ROOT/hooks/lib/run-tests-unrunnable-note.js"
PRE='- Unverified tests:'

# cases.js <root> — one `name|value` line per case; a missing module prints MODULE_MISSING for all.
cat >"$T/cases.js" <<'EOF'
"use strict";
let M;
try { M = require(process.argv[2] + "/hooks/lib/run-tests-completion-note.js"); } catch (e) { M = null; }
const cls = (...e) => ({ base: "abc", entries: e.map(([p, c, d]) => ({ path: p, class: c, detail: d })) });
const done = (o) => Object.assign({ status: "complete", run_outcome: "pass" }, o);
const UA = done({ completion_basis: "unrunnable-accepted", unrunnable_count: 2,
  unrunnable_runtimes: "Pester>=5.0", unrunnable_accept_reason: "no Pester here" });
const UND = done({ completion_basis: "baseline-user-accepted",
  baseline_classification: cls(["t/a.sh", "undetermined", "home-claude-ref"], ["t/b.sh", "undetermined", "timeout-at-base"],
    ["t/c.sh", "preexisting", ""]),
  baseline_accept: { reason: "fails on main too", kind: "undetermined", run_seq: 4, outcome_source: null, accepted_run_outcome: "fail" } });
const DUP = Object.assign({}, UND, { baseline_classification: cls(["t/a.sh", "undetermined", "home-claude-ref"],
  ["t/b.sh", "undetermined", "home-claude-ref"]) });
const NOL = (aro) => done({ completion_basis: "baseline-user-accepted", failing_tests: null,
  baseline_accept: Object.assign({ reason: "flaky on main", kind: "failing-list-unrecorded", run_seq: 2, outcome_source: null },
    aro === undefined ? {} : { accepted_run_outcome: aro }) });
const n = (e) => { const v = M.completionNote(e); return v === null ? "null" : v; };
const C = {
  "exports-bases": () => `${M.UNRUNNABLE_ACCEPT_BASIS}:${M.BASELINE_ACCEPT_BASIS}`,
  "unrunnable-line-unchanged": () => n(UA),
  "undetermined-prefix": () => n(UND).startsWith("- Unverified tests: 2 failing test(s) accepted by the user as pre-existing without baseline proof (undetermined: "),
  "undetermined-names-every-detail": () => ["home-claude-ref", "timeout-at-base"].every((d) => n(UND).includes(d)),
  "undetermined-suffix": () => n(UND).endsWith("; reason: fails on main too)"),
  "undetermined-detail-is-a-set": () => n(DUP).split("home-claude-ref").length - 1,
  "undetermined-count-is-undetermined-only": () => n(DUP).startsWith("- Unverified tests: 2 failing test(s)"),
  "nolist-fail": () => n(NOL("fail")),
  "nolist-timeout-not-step-pass": () => n(NOL("timeout")),
  "nolist-missing-outcome": () => n(NOL(undefined)),
  "nolist-non-string-outcome": () => n(NOL(42)),
  "one-line-and-capped": () => {
    const v = n(Object.assign({}, UND, { baseline_accept: Object.assign({}, UND.baseline_accept, { reason: "r\n" + "x".repeat(400) }) }));
    return `${/[\r\n]/.test(v)}:${v.length < 200 + 200 + 150}`;
  },
  "null-baseline-preexisting": () => n(done({ completion_basis: "baseline-preexisting" })),
  "null-plain-pass": () => n(done({})),
  "null-pending-with-basis": () => n(Object.assign({}, UND, { status: "pending" })),
  "null-no-entry": () => `${n(null)}:${n(undefined)}`,
  "read-fail-open": () => String(M.readCompletionNote("no-such-session-2517")),
};
for (const [k, f] of Object.entries(C)) {
  let v;
  if (!M) v = "MODULE_MISSING";
  else { try { v = String(f()); } catch (e) { v = "THREW:" + e.message; } }
  process.stdout.write(k + "|" + v.replace(/\n/g, "~") + "\n");
}
EOF

# seed.js <root> <sid> [pre] — a session whose run_tests was completed by an undetermined grant;
# with `pre`, one completed as baseline-preexisting (proof, no grant).
cat >"$T/seed.js" <<'EOF'
"use strict";
const [root, sid, shape] = process.argv.slice(2);
const ev = (o) => Object.assign({ step: "run_tests", provenance: "observed", origin: "run-tests-baseline-evidence" }, o);
const a = (key, value) => ev({ kind: "step_annotation", key, value });
const { appendEvents } = require(root + "/hooks/workflow-state/state-io/events");
if (shape === "pre") {
  appendEvents(sid, [ev({ kind: "step_status", status: "pending" }),
    a("baseline_classification", { base: "abc", entries: [{ path: "t/a.sh", class: "preexisting", detail: "" }] }),
    a("run_outcome", "pass"), a("completion_basis", "baseline-preexisting"), ev({ kind: "step_status", status: "complete" })]);
  process.stdout.write("ok");
  process.exit(0);
}
appendEvents(sid, [
  ev({ kind: "step_status", status: "pending" }),
  a("baseline_classification", { base: "abc", entries: [{ path: "t/a.sh", class: "undetermined", detail: "budget-exhausted" }] }),
  Object.assign(a("baseline_accept", { reason: "seen red on main", kind: "undetermined", run_seq: 1, outcome_source: null,
    accepted_run_outcome: "fail" }), { provenance: "declared", origin: "workflow-mark-run-tests-baseline-accept" }),
  a("run_outcome", "pass"), a("completion_basis", "baseline-user-accepted"),
  ev({ kind: "step_status", status: "complete" }),
]);
process.stdout.write("ok");
EOF

case_begin "module-renamed" "hooks/lib/run-tests-completion-note.js"
[ -f "$NOTE_JS" ] && pass "present: hooks/lib/run-tests-completion-note.js" \
  || fail "present: hooks/lib/run-tests-completion-note.js" "missing"
[ -f "$NOTE_CLI" ] && pass "present: bin/workflow/run-tests-completion-note" \
  || fail "present: bin/workflow/run-tests-completion-note" "missing"
[ -f "$OLD_JS" ] && fail "old name removed: hooks/lib/run-tests-unrunnable-note.js" "still present (no shim, CPR-NRS)" \
  || pass "old name removed: hooks/lib/run-tests-unrunnable-note.js"
case_end

case_begin "completion-note-table" "hooks/lib/run-tests-completion-note.js"
OUT="$(run_with_timeout 30 node "$(np "$T/cases.js")" "$ROOT" 2>&1)"
while IFS='|' read -r name want; do
  [ -n "$name" ] || continue
  got="$(printf '%s\n' "$OUT" | grep -m1 "^$name|" | cut -d'|' -f2-)"
  ck "$name" "$want" "$got"
done <<TABLE
exports-bases|unrunnable-accepted:baseline-user-accepted
unrunnable-line-unchanged|$PRE 2 UNRUNNABLE accepted (missing runtimes: Pester>=5.0; reason: no Pester here)
undetermined-prefix|true
undetermined-names-every-detail|true
undetermined-suffix|true
undetermined-detail-is-a-set|1
undetermined-count-is-undetermined-only|true
nolist-fail|$PRE failing tests accepted by the user with no recorded failing list (run_outcome=fail; reason: flaky on main)
nolist-timeout-not-step-pass|$PRE failing tests accepted by the user with no recorded failing list (run_outcome=timeout; reason: flaky on main)
nolist-missing-outcome|$PRE failing tests accepted by the user with no recorded failing list (run_outcome=unknown; reason: flaky on main)
nolist-non-string-outcome|$PRE failing tests accepted by the user with no recorded failing list (run_outcome=unknown; reason: flaky on main)
one-line-and-capped|false:true
null-baseline-preexisting|null
null-plain-pass|null
null-pending-with-basis|null
null-no-entry|null:null
read-fail-open|null
TABLE
case_end

case_begin "completion-note-cli" "bin/workflow/run-tests-completion-note"
SID="cn2517-$$"
ck "fixture: completed-by-grant session seeded" "ok" \
  "$(run_with_timeout 20 node "$(np "$T/seed.js")" "$ROOT" "$SID" 2>/dev/null)"
WANT="$PRE 1 failing test(s) accepted by the user as pre-existing without baseline proof (undetermined: budget-exhausted; reason: seen red on main)"
CLI_OUT="$(run_with_timeout 20 node "$(np "$NOTE_CLI")" --session "$SID" 2>/dev/null)"
ck "CLI prints the grant line" "$WANT" "$CLI_OUT"
CLI_OUT="$(run_with_timeout 20 node "$(np "$NOTE_CLI")" --session "cn2517-none-$$" 2>/dev/null)"; rc=$?
ck "CLI prints nothing for an unknown session (exit 0)" "0:" "$rc:$CLI_OUT"
run_with_timeout 20 node "$(np "$NOTE_CLI")" >/dev/null 2>&1; rc=$?
ck "CLI usage error exits 2" "2" "$rc"
case_end

case_begin "final-report-carries-the-line" "bin/render-final-report.js"
mkdir -p "$WORKFLOW_STATE_DIR/$SID.control"
printf '{}' >"$WORKFLOW_STATE_DIR/$SID.control/final-report-env.json"
REPORT="$(run_with_timeout 30 node "$(np "$SCRIPT_CHECKOUT_ROOT/bin/render-final-report.js")" --session "$SID" 2>&1)"
if printf '%s\n' "$REPORT" | grep -qE '^- State: '; then pass "control: the report has the Merged PR State line"
else fail "control: the report has the Merged PR State line" "$(printf '%s' "$REPORT" | head -5)"; fi
NEXT="$(printf '%s\n' "$REPORT" | grep -A1 -E '^- State: ' | sed -n 2p)"
ck "the grant line follows the State line" "$WANT" "$NEXT"
case_end

case_begin "pr-body-disclosure" "skills/_shared/commit-push-dispatch.md"
# The PR body appends the non-empty stdout of the CLI that commit-push-dispatch.md names.
DISPATCH_MD="$SCRIPT_CHECKOUT_ROOT/skills/_shared/commit-push-dispatch.md"
grep -qE 'pr_body_template.*bin/workflow/run-tests-completion-note" --session' "$DISPATCH_MD" \
  && pass "commit-push-dispatch pr_body_template names bin/workflow/run-tests-completion-note" \
  || fail "commit-push-dispatch pr_body_template names bin/workflow/run-tests-completion-note" "no single line with pr_body_template and the CLI in $DISPATCH_MD"
grep -q 'run-tests-unrunnable-note' "$DISPATCH_MD" \
  && fail "commit-push-dispatch drops the old CLI name" "run-tests-unrunnable-note still named" \
  || pass "commit-push-dispatch drops the old CLI name"
PR_OUT="$(run_with_timeout 20 node "$(np "$NOTE_CLI")" --session "$SID" 2>/dev/null)"; rc=$?
ck "PR-body stdout for baseline-user-accepted is the grant line (exit 0)" "0:$WANT" "$rc:$PR_OUT"
PRE_SID="cn2517-pre-$$"
ck "fixture: baseline-preexisting session seeded" "ok" \
  "$(run_with_timeout 20 node "$(np "$T/seed.js")" "$ROOT" "$PRE_SID" pre 2>/dev/null)"
ck "fixture: baseline-preexisting session is complete" "complete" \
  "$(run_with_timeout 20 node -e 'process.stdout.write(String(require(process.argv[1] + "/hooks/workflow-state").readState(process.argv[2]).steps.run_tests.status))' "$ROOT" "$PRE_SID" 2>/dev/null)"
PR_OUT="$(run_with_timeout 20 node "$(np "$NOTE_CLI")" --session "$PRE_SID" 2>/dev/null)"; rc=$?
ck "PR-body stdout for baseline-preexisting is empty (exit 0)" "0:" "$rc:$PR_OUT"
case_end

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
