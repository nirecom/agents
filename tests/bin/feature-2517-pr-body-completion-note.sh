#!/usr/bin/env bash
# tests/bin/feature-2517-pr-body-completion-note.sh
# Tests: bin/worker-dispatch/workers/commit-push/pr.js, hooks/lib/run-tests-completion-note.js
# Tags: TL2, commit-push, pr-body, run-tests, completion-note, baseline-accept, unrunnable, disclosure, idempotency, scope:issue-specific
# A run_tests completed by a user accept (baseline or UNRUNNABLE) must leave its one-line
# disclosure in the PR body (#2517). The commit-push worker's prBody(payload) appends
# readCompletionNote(payload.session_id) itself, the same completion pattern as `Closes #N`,
# so the line cannot vanish when an LLM forgets to append it to pr_body_template.
# TL3 gap (what this test does NOT catch):
# - the real `gh pr create --body-file -` / `glab mr create --description-file -` receiving the body;
#   ensurePullRequest and ensureMergeRequestGitlab both pass prBody(payload) unchanged to stdin.
set -euo pipefail

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
mkdir -p "$T/transcripts" "$T/cwd"
export CLAUDE_TRANSCRIPT_BASE_DIR="$T/transcripts"
cd "$T/cwd"

ROOT="$(np "$SCRIPT_CHECKOUT_ROOT")"
PRE='- Unverified tests:'

# ck <name> <want> <got> — named equality.
ck() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=[$2] got=[$3]"; fi; }

# drive.js <root> <case> <sid> — seeds the case's run_tests state for <sid>, calls prBody, and
# prints `key=value` lines (newlines in values become `~`).
cat >"$T/drive.js" <<'EOF'
"use strict";
const [root, name, sid] = process.argv.slice(2);
const { appendEvents } = require(root + "/hooks/workflow-state/state-io/events");
const { readState } = require(root + "/hooks/workflow-state");
const { completionNote } = require(root + "/hooks/lib/run-tests-completion-note.js");
const pr = require(root + "/bin/worker-dispatch/workers/commit-push/pr.js");
const PRE = "- Unverified tests:";
const NOSTATE_SID = "00000000-2517-4000-8000-0000000000ff";
const ev = (o) => Object.assign({ step: "run_tests", provenance: "observed", origin: "run-tests-baseline-evidence" }, o);
const a = (key, value) => ev({ kind: "step_annotation", key, value });
const st = (status) => ev({ kind: "step_status", status });
const grant = (g) => Object.assign(a("baseline_accept", Object.assign({ run_seq: 1, outcome_source: null }, g)),
  { provenance: "declared", origin: "workflow-mark-run-tests-baseline-accept" });
const SHAPES = {
  undetermined: [
    a("baseline_classification", { base: "abc", entries: [{ path: "t/a.sh", class: "undetermined", detail: "budget-exhausted" }] }),
    grant({ reason: "seen red on main", kind: "undetermined", accepted_run_outcome: "fail" }),
    a("run_outcome", "pass"), a("completion_basis", "baseline-user-accepted")],
  nolist: [
    grant({ reason: "flaky on main", kind: "failing-list-unrecorded", accepted_run_outcome: "fail" }),
    a("run_outcome", "pass"), a("completion_basis", "baseline-user-accepted")],
  unrunnable: [
    a("unrunnable_count", 2), a("unrunnable_runtimes", "Pester>=5.0"), a("unrunnable_accept_reason", "no Pester here"),
    a("run_outcome", "pass"), a("completion_basis", "unrunnable-accepted")],
  plain: [a("run_outcome", "pass")],
};
const seed = (shape, final) => appendEvents(sid, [st("pending"), ...SHAPES[shape], st(final)]);
const entryNote = () => { const s = readState(sid); return completionNote(s && s.steps && s.steps.run_tests); };
const TPL = "## Summary\n\nAdd the thing.\n";
const out = {};
const payload = { session_id: sid, branch: "feature/2517-x", commit_message: "feat(#2517): add the thing", pr_body_template: TPL };
switch (name) {
  case "undetermined": seed("undetermined", "complete"); break;
  case "nolist": seed("nolist", "complete"); break;
  case "unrunnable": seed("unrunnable", "complete"); break;
  case "template-has-note": seed("undetermined", "complete"); payload.pr_body_template = `${TPL}\n${entryNote()}\n`; break;
  case "empty-template": seed("undetermined", "complete"); payload.pr_body_template = ""; break;
  case "absent-template": seed("undetermined", "complete"); delete payload.pr_body_template; break;
  case "closes": seed("undetermined", "complete"); payload.closes_issues = [{ number: 2517 }]; break;
  case "neg-plain-pass": seed("plain", "complete"); break;
  case "neg-pending": seed("undetermined", "pending"); break;
  case "neg-no-state": break;
  case "neg-no-session-id": delete payload.session_id; break;
  case "tombstone":
    seed("undetermined", "complete");
    out.pre_note = String(entryNote());
    appendEvents(sid, [st("pending"), a("completion_basis", null), a("baseline_accept", null),
      a("baseline_classification", null), a("run_outcome", "pass"), st("complete")]);
    break;
  default: throw new Error("unknown case " + name);
}
const note = payload.session_id === undefined ? null : entryNote();
let body = "";
try { body = pr.prBody(payload); out.threw = "no"; } catch (e) { out.threw = "yes:" + e.message; }
const lines = body.split("\n");
out.note = note === null ? "null" : note;
out.note_count = note === null ? 0 : lines.filter((l) => l === note).length;
out.prefix_count = lines.filter((l) => l.startsWith(PRE)).length;
out.closes_count = lines.filter((l) => l === "Closes #2517").length;
out.marker = pr.markerFor({ number: 2517 });
out.marker_count = lines.filter((l) => l === out.marker).length;
out.plain_eq = String(body === `${String(payload.pr_body_template || "").replace(/\s+$/, "")}\n`);
out.nostate_eq = String(body === pr.prBody(Object.assign({}, payload, { session_id: NOSTATE_SID })));
for (const [k, v] of Object.entries(out)) process.stdout.write(`${k}=${String(v).replace(/\r?\n/g, "~")}\n`);
EOF

# drive <case> <sid-suffix> — runs drive.js; `OUT` holds its key=value lines.
drive() {
  OUT="$(run_with_timeout 30 node "$(np "$T/drive.js")" "$ROOT" "$1" "00000000-2517-4000-8000-0000000000$2" 2>&1 || true)"
}
# field <key> — the value of <key> in OUT (empty when absent).
field() { printf '%s\n' "$OUT" | sed -n "/^$1=/{s/^$1=//p;q;}"; }

# positive <label> — the note is real (non-null, prefixed) and present exactly once in the body.
positive() {
  local note
  note="$(field note)"
  if [[ "$note" == "$PRE"* ]]; then pass "$1: expected note is non-empty and starts with '$PRE'"
  else fail "$1: expected note is non-empty and starts with '$PRE'" "note=[$note] out=[$OUT]"; fi
  ck "$1: prBody does not throw" "no" "$(field threw)"
  ck "$1: the note line appears exactly once in the PR body" "1" "$(field note_count)"
  ck "$1: exactly one '$PRE' line in the PR body" "1" "$(field prefix_count)"
}

# negative <label> — no disclosure line, and the body is the plain no-state body.
negative() {
  ck "$1: prBody does not throw" "no" "$(field threw)"
  ck "$1: no '$PRE' line in the PR body" "0" "$(field prefix_count)"
  ck "$1: body is the template plus newline, unchanged" "true" "$(field plain_eq)"
  ck "$1: body equals prBody for the same payload with no state" "true" "$(field nostate_eq)"
}

case_begin "baseline-accept-undetermined-note" "bin/worker-dispatch/workers/commit-push/pr.js"
drive undetermined 01
positive "baseline-accept undetermined"
case_end

case_begin "baseline-accept-failing-list-unrecorded-note" "bin/worker-dispatch/workers/commit-push/pr.js"
drive nolist 02
positive "baseline-accept failing-list-unrecorded"
case_end

case_begin "unrunnable-accepted-note" "bin/worker-dispatch/workers/commit-push/pr.js"
drive unrunnable 03
positive "unrunnable-accepted"
case_end

case_begin "template-already-has-note-not-duplicated" "bin/worker-dispatch/workers/commit-push/pr.js"
drive template-has-note 04
positive "template already carries the note"
case_end

case_begin "empty-or-absent-template-gets-note" "bin/worker-dispatch/workers/commit-push/pr.js"
drive empty-template 05
positive "empty pr_body_template"
drive absent-template 06
positive "absent pr_body_template"
case_end

case_begin "note-coexists-with-closes-and-marker" "bin/worker-dispatch/workers/commit-push/pr.js"
drive closes 07
positive "closes_issues + accept"
ck "closes_issues + accept: 'Closes #2517' appears exactly once" "1" "$(field closes_count)"
ck "closes_issues + accept: issue-close marker appears exactly once" "1" "$(field marker_count)"
if [[ "$(field marker)" == "<!-- issue-close-pr-of: 2517 -->" ]]; then pass "closes_issues + accept: markerFor yields the repo-local marker"
else fail "closes_issues + accept: markerFor yields the repo-local marker" "marker=[$(field marker)]"; fi
case_end

case_begin "no-note-without-accept" "bin/worker-dispatch/workers/commit-push/pr.js"
drive neg-plain-pass 08
ck "plain pass: completionNote is null" "null" "$(field note)"
negative "plain pass"
drive neg-pending 09
ck "pending run_tests: completionNote is null" "null" "$(field note)"
negative "pending run_tests"
drive neg-no-state 10
ck "no state file: completionNote is null" "null" "$(field note)"
negative "no state file"
drive neg-no-session-id 11
negative "payload without session_id"
case_end

case_begin "later-run-tombstone-drops-note" "hooks/lib/run-tests-completion-note.js"
drive tombstone 12
if [[ "$(field pre_note)" == "$PRE"* ]]; then pass "tombstone: the accept state carried a note before the re-run"
else fail "tombstone: the accept state carried a note before the re-run" "pre_note=[$(field pre_note)] out=[$OUT]"; fi
ck "tombstone: completionNote is null after a green re-run" "null" "$(field note)"
negative "tombstoned accept"
case_end

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
