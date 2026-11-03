#!/usr/bin/env bash
# tests/hooks/feature-2517-run-tests-completion-note.sh
# Tests: hooks/lib/run-tests-completion-note.js, bin/render-final-report.js, skills/_shared/commit-push-dispatch.md
# Tags: TL1, TL2, run-tests, final-report, baseline, unrunnable, disclosure, table-driven, scope:issue-specific, auto-accept, legacy
# A run_tests completed without a baseline proof must say so in the Final Report and the PR body
# (#2517, #2688). The note module returns one line for unrunnable-accepted (unchanged), for
# baseline-auto-accepted (causes + note), and a fixed legacy line for pre-#2688 baseline-user-accepted.
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
OLD_JS="$SCRIPT_CHECKOUT_ROOT/hooks/lib/run-tests-unrunnable-note.js"
PRE='- Unverified tests:'
# #2688: a state completed by a pre-#2688 user grant gets this fixed line (the grant is not re-read).
LEGACY="$PRE failing tests accepted by the user before #2688 (legacy grant; details not re-read)"

# cases.js <root> — one `name|value` line per case; a missing module prints MODULE_MISSING for all.
cat >"$T/cases.js" <<'EOF'
"use strict";
let M;
try { M = require(process.argv[2] + "/hooks/lib/run-tests-completion-note.js"); } catch (e) { M = null; }
const cls = (...e) => ({ base: "abc", entries: e.map(([p, c, d]) => ({ path: p, class: c, detail: d })) });
const done = (o) => Object.assign({ status: "complete", run_outcome: "pass" }, o);
const UA = done({ completion_basis: "unrunnable-accepted", unrunnable_count: 2,
  unrunnable_runtimes: "Pester>=5.0", unrunnable_accept_reason: "no Pester here" });
// #2688: the user grant is gone. AUTO is the auto-accepted shape; LEG/NOL are legacy states
// completed by a pre-#2688 grant, which now get one fixed line whatever the grant held.
const AUTO = done({ completion_basis: "baseline-auto-accepted", baseline_note: "fails on main too",
  baseline_classification: cls(["t/a.sh", "undetermined", "home-claude-ref"], ["t/b.sh", "undetermined", "timeout-at-base"],
    ["t/c.sh", "preexisting", ""]) });
const DUP = Object.assign({}, AUTO, { baseline_classification: cls(["t/a.sh", "undetermined", "home-claude-ref"],
  ["t/b.sh", "undetermined", "home-claude-ref"]) });
const LEG = done({ completion_basis: "baseline-user-accepted",
  baseline_classification: cls(["t/a.sh", "undetermined", "home-claude-ref"]),
  baseline_accept: { reason: "fails on main too", kind: "undetermined", run_seq: 4, outcome_source: null, accepted_run_outcome: "fail" } });
const NOL = (aro) => done({ completion_basis: "baseline-user-accepted", failing_tests: null,
  baseline_accept: Object.assign({ reason: "flaky on main", kind: "failing-list-unrecorded", run_seq: 2, outcome_source: null },
    aro === undefined ? {} : { accepted_run_outcome: aro }) });
const n = (e) => { const v = M.completionNote(e); return v === null ? "null" : v; };
const C = {
  "exports-bases": () => `${M.UNRUNNABLE_ACCEPT_BASIS}:${M.BASELINE_AUTO_BASIS}:${M.BASELINE_ACCEPT_BASIS}`,
  "unrunnable-line-unchanged": () => n(UA),
  "auto-prefix": () => n(AUTO).startsWith("- Unverified tests: 2 failing test(s) auto-accepted without baseline proof (causes: "),
  "auto-names-every-detail": () => ["home-claude-ref", "timeout-at-base"].every((d) => n(AUTO).includes(d)),
  "auto-suffix": () => n(AUTO).endsWith("; note: `fails on main too`)"),
  "auto-detail-is-a-set": () => n(DUP).split("home-claude-ref").length - 1,
  "auto-count-is-auto-accepted-only": () => n(DUP).startsWith("- Unverified tests: 2 failing test(s)"),
  "auto-without-note": () => n(Object.assign({}, AUTO, { baseline_note: undefined })).endsWith("; note: (none))"),
  "legacy-undetermined": () => n(LEG),
  "legacy-nolist-fail": () => n(NOL("fail")),
  "legacy-nolist-timeout": () => n(NOL("timeout")),
  "legacy-nolist-missing-outcome": () => n(NOL(undefined)),
  "one-line-and-capped": () => {
    const v = n(Object.assign({}, AUTO, { baseline_note: "r\n" + "x".repeat(400) }));
    return `${/[\r\n]/.test(v)}:${v.length < 200 + 200 + 150}`;
  },
  "null-baseline-preexisting": () => n(done({ completion_basis: "baseline-preexisting" })),
  "null-plain-pass": () => n(done({})),
  "null-pending-with-basis": () => n(Object.assign({}, AUTO, { status: "pending" })),
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

# seed.js <root> <sid> — a session whose run_tests was completed by an auto-accepted baseline (#2688).
cat >"$T/seed.js" <<'EOF'
"use strict";
const [root, sid] = process.argv.slice(2);
const ev = (o) => Object.assign({ step: "run_tests", provenance: "observed", origin: "run-tests-baseline-evidence" }, o);
const a = (key, value) => ev({ kind: "step_annotation", key, value });
const { appendEvents } = require(root + "/hooks/workflow-state/state-io/events");
appendEvents(sid, [
  ev({ kind: "step_status", status: "pending" }),
  a("baseline_classification", { base: "abc", entries: [{ path: "t/a.sh", class: "undetermined", detail: "skip-at-base" }] }),
  a("baseline_note", "seen red on main"),
  a("run_outcome", "pass"), a("completion_basis", "baseline-auto-accepted"),
  ev({ kind: "step_status", status: "complete" }),
]);
process.stdout.write("ok");
EOF

case_begin "module-renamed" "hooks/lib/run-tests-completion-note.js"
[ -f "$NOTE_JS" ] && pass "present: hooks/lib/run-tests-completion-note.js" \
  || fail "present: hooks/lib/run-tests-completion-note.js" "missing"
# The CLI had no production caller (render-final-report and prBody require the module directly).
[ -e "$SCRIPT_CHECKOUT_ROOT/bin/workflow/run-tests-completion-note" ] \
  && fail "dead CLI absent: bin/workflow/run-tests-completion-note" "present (no production caller)" \
  || pass "dead CLI absent: bin/workflow/run-tests-completion-note"
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
exports-bases|unrunnable-accepted:baseline-auto-accepted:undefined
unrunnable-line-unchanged|$PRE 2 UNRUNNABLE accepted (missing runtimes: Pester>=5.0; reason: no Pester here)
auto-prefix|true
auto-names-every-detail|true
auto-suffix|true
auto-detail-is-a-set|1
auto-count-is-auto-accepted-only|true
auto-without-note|true
legacy-undetermined|$LEGACY
legacy-nolist-fail|$LEGACY
legacy-nolist-timeout|$LEGACY
legacy-nolist-missing-outcome|$LEGACY
one-line-and-capped|false:true
null-baseline-preexisting|null
null-plain-pass|null
null-pending-with-basis|null
null-no-entry|null:null
read-fail-open|null
TABLE
case_end

case_begin "final-report-carries-the-line" "bin/render-final-report.js"
SID="cn2517-$$"
ck "fixture: auto-accepted session seeded" "ok" \
  "$(run_with_timeout 20 node "$(np "$T/seed.js")" "$ROOT" "$SID" 2>/dev/null)"
WANT="$PRE 1 failing test(s) auto-accepted without baseline proof (causes: skip-at-base; note: \`seen red on main\`)"
mkdir -p "$WORKFLOW_STATE_DIR/$SID.control"
printf '{}' >"$WORKFLOW_STATE_DIR/$SID.control/final-report-env.json"
REPORT="$(run_with_timeout 30 node "$(np "$SCRIPT_CHECKOUT_ROOT/bin/render-final-report.js")" --session "$SID" 2>&1)"
if printf '%s\n' "$REPORT" | grep -qE '^- URL: '; then pass "control: the report has the Merged PR URL line"
else fail "control: the report has the Merged PR URL line" "$(printf '%s' "$REPORT" | head -5)"; fi
NEXT="$(printf '%s\n' "$REPORT" | grep -A1 -E '^- URL: ' | sed -n 2p)"
ck "the auto-accept line follows the URL line (#2904)" "$WANT" "$NEXT"
case_end

case_begin "pr-body-disclosure" "skills/_shared/commit-push-dispatch.md"
# The commit-push worker's prBody appends the note itself, so the dispatch doc must not tell the
# LLM to append a note to pr_body_template (an instruction that can silently vanish). prBody's
# own behavior: tests/bin/feature-2517-pr-body-completion-note.sh.
DISPATCH_MD="$SCRIPT_CHECKOUT_ROOT/skills/_shared/commit-push-dispatch.md"
grep -q 'pr_body_template' "$DISPATCH_MD" \
  && pass "control: commit-push-dispatch still names pr_body_template" \
  || fail "control: commit-push-dispatch still names pr_body_template" "no pr_body_template line in $DISPATCH_MD"
grep -E 'pr_body_template' "$DISPATCH_MD" | grep -q 'run-tests-completion-note' \
  && fail "commit-push-dispatch pr_body_template line has no LLM append instruction" "a pr_body_template line still names run-tests-completion-note" \
  || pass "commit-push-dispatch pr_body_template line has no LLM append instruction"
grep -q 'run-tests-unrunnable-note' "$DISPATCH_MD" \
  && fail "commit-push-dispatch drops the old CLI name" "run-tests-unrunnable-note still named" \
  || pass "commit-push-dispatch drops the old CLI name"
case_end

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
