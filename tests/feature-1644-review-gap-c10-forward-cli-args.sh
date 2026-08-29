#!/usr/bin/env bash
# Tests: bin/workflow/next-step, bin/workflow/lib/next-step/cli.js, bin/workflow/lib/next-step/advance-shared.js, bin/workflow/record-skip-judgment, bin/workflow/set-workflow-type, bin/workflow/record-complexity-and-skip, hooks/workflow-state/record-step-verdict.js
# Tags: tl2, workflow, advance, forward-cli, argument-validation, error-cases, edge-cases, scope:issue-specific, pwsh-not-required

# #1644 review gap C10 (MEDIUM) — argument handling on all four advance-class CLIs:
# malformed flags, boundary values, hostile session ids. Every rejected call asserts
# BOTH the exact exit code and a byte-identical workflow dir afterwards — a CLI that
# validates late can exit nonzero and still have written.

# TL3 gap: settings.json allow/deny classification of these argv forms, and pwsh
# quoting (asserted under bash only). Mitigation: bin/check-verification-gate.sh
# category skill-orchestration, at WORKFLOW_USER_VERIFIED preflight.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"
NS="$AGENTS_DIR_N/bin/workflow/next-step"
RSJ="$AGENTS_DIR_N/bin/workflow/record-skip-judgment"
SWT="$AGENTS_DIR_N/bin/workflow/set-workflow-type"
RCAS="$AGENTS_DIR/bin/workflow/record-complexity-and-skip"
WFSTATE_MODULE="$AGENTS_DIR_N/hooks/workflow-state"; export WFSTATE_MODULE
PROBE="$AGENTS_DIR_N/tests/feature-1644-advance-transaction/state-probe.js"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
WORKFLOW_DIR="$TMPDIR_BASE/wf"; PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"
# Pinned as a PAIR (#1799) so supervisor-emit never appends to the real ~/.workflow-plans.
export CLAUDE_WORKFLOW_DIR="$(nrm "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

CONFIG_EMPTY="$TMPDIR_BASE/cfg-empty"; mkdir -p "$CONFIG_EMPTY"; : > "$CONFIG_EMPTY/.env"
export AGENTS_CONFIG_DIR="$(nrm "$CONFIG_EMPTY")"

FIXTURE_REPO="$TMPDIR_BASE/repo"; mkdir -p "$FIXTURE_REPO"
git init -q "$FIXTURE_REPO" >/dev/null 2>&1
git -C "$FIXTURE_REPO" config core.hooksPath /dev/null
export CLAUDE_PROJECT_DIR="$(nrm "$FIXTURE_REPO")"
cd "$FIXTURE_REPO" || exit 1

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- expected [$2] got [$3]"; fi; }
check_contains() {
  if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1 -- expected [$2] in: $3"; fi
}
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
  else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

STEPS_ALL="workflow_init clarify_intent research outline detail branching_complete write_tests review_tests write_code run_tests review_security docs user_verification cleanup pre_final_report_gate final_report"
make_state() {
  local sid="$1" complete="$2" json='{"steps":{' first=1 s st
  for s in $STEPS_ALL; do
    st="pending"; case " $complete " in *" $s "*) st="complete" ;; esac
    [ $first -eq 1 ] || json="$json,"; first=0
    json="$json\"$s\":{\"status\":\"$st\"}"
  done
  printf '%s' "$json},\"closes_issues\":[1644]}" > "$WORKFLOW_DIR/${sid}.json"
}

OUT=""; ERR=""; RC=0
run_cli() {
  local errf="$TMPDIR_BASE/cli.err"
  RC=0
  OUT="$(run_with_timeout "$@" 2>"$errf")" || RC=$?
  ERR="$(cat "$errf" 2>/dev/null || echo "")"
}
# Whole-directory snapshot: entry names plus size+bytes for regular files. A
# lock directory or a newly minted state file both change this string.
wf_snapshot() {
  local f
  for f in $(ls -1 "$WORKFLOW_DIR" 2>/dev/null | sort); do
    if [ -f "$WORKFLOW_DIR/$f" ]; then
      printf '%s|%s|' "$f" "$(wc -c < "$WORKFLOW_DIR/$f" | tr -d ' ')"
      cat "$WORKFLOW_DIR/$f"
      printf '\n'
    else
      printf '%s|DIR\n' "$f"
    fi
  done
}
step_status() {
  PROBE_SID="$1" PROBE_STEP="$2" PROBE_FIELD=status \
    run_with_timeout node "$PROBE" field 2>/dev/null || echo "PROBE_FAIL"
}

# expect_reject <desc> <expected-rc> -- <argv...>
# The one assertion shape every C10 case uses: exact exit code AND an untouched
# workflow directory. Snapshotting inside the helper is what makes the second
# half impossible to forget on a new case.
expect_reject() {
  local desc="$1" want="$2" before after
  shift 3   # drop desc, want, and the literal --
  before="$(wf_snapshot)"
  run_cli "$@"
  after="$(wf_snapshot)"
  check "$desc: exit $want" "$want" "$RC"
  check "$desc: the workflow dir is untouched" "$before" "$after"
}

# A pre-existing session, so "untouched" is a statement about REAL content and
# not merely about an empty directory.
make_state guard "workflow_init clarify_intent research"

echo "=== C10-1: next-step — missing flag values and malformed sessions ==="
expect_reject "C10-1a: --session with no value" 1 -- \
  node "$NS" --advance --step research --status complete --session
expect_reject "C10-1b: --step with no value" 1 -- \
  node "$NS" --session guard --advance --status complete --step
expect_reject "C10-1c: --status with no value" 1 -- \
  node "$NS" --session guard --advance --step research --status
expect_reject "C10-1d: --skip-reason with no value" 1 -- \
  node "$NS" --session guard --advance --step research --status skipped --skip-reason
expect_reject "C10-1e: empty --session" 1 -- \
  node "$NS" --session "" --advance --step research --status complete
check_contains "C10-1e: the diagnostic is a session-resolution failure" \
  "could not resolve session id" "$ERR"
expect_reject "C10-1f: path-traversal --session" 1 -- \
  node "$NS" --session "../evil" --advance --step research --status complete
check_contains "C10-1f: the diagnostic names the session charset" \
  "must match [A-Za-z0-9_-]+" "$ERR"
expect_reject "C10-1g: --session containing a space" 1 -- \
  node "$NS" --session "a b" --advance --step research --status complete

echo ""
echo "=== C10-2: next-step — unknown names and non-forward statuses ==="
expect_reject "C10-2a: unknown step name" 1 -- \
  node "$NS" --session guard --advance --step no_such_step --status complete
expect_reject "C10-2b: unknown status" 1 -- \
  node "$NS" --session guard --advance --step research --status finished
expect_reject "C10-2c: --status in_progress is not a forward operation" 1 -- \
  node "$NS" --session guard --advance --step research --status in_progress
check_contains "C10-2c: the refusal reads as a status rejection" \
  "is not a forward operation" "$ERR"
expect_reject "C10-2d: --next without --advance" 1 -- \
  node "$NS" --session guard --next
check_contains "C10-2d: the diagnostic names the dependency" \
  "--next is only meaningful with --advance" "$ERR"
# --target belongs to record-skip-judgment, not to next-step. Sending it here is
# the most likely real-world slip once four CLIs share a flag vocabulary.
expect_reject "C10-2e: a sibling's flag is an unknown option here" 1 -- \
  node "$NS" --session guard --target outline
expect_reject "C10-2f: --advance --status skipped with an empty reason" 1 -- \
  node "$NS" --session guard --advance --step research --status skipped --skip-reason ""
expect_reject "C10-2g: --advance --status skipped with no --skip-reason at all" 1 -- \
  node "$NS" --session guard --advance --step research --status skipped

echo ""
echo "=== C10-3: record-skip-judgment argument handling ==="
expect_reject "C10-3a: invalid boolean for --c1" 1 -- \
  node "$RSJ" --session guard --target outline --c1 maybe --c2 true
check_contains "C10-3a: the diagnostic names the offending flag and value" \
  "invalid boolean for --c1: maybe" "$ERR"
expect_reject "C10-3b: --session with no value" 1 -- \
  node "$RSJ" --target outline --c1 true --c2 true --session
expect_reject "C10-3c: empty --session" 1 -- \
  node "$RSJ" --session "" --target outline --c1 true --c2 true
expect_reject "C10-3d: unknown --target" 1 -- \
  node "$RSJ" --session guard --target roadmap --c1 true --c2 true
expect_reject "C10-3e: --next without --advance" 1 -- \
  node "$RSJ" --session guard --target outline --c1 true --c2 true --next
expect_reject "C10-3f: a flag this CLI does not own" 1 -- \
  node "$RSJ" --session guard --target outline --c1 true --c2 true --step research
# CURRENT BEHAVIOR, deliberately pinned as-is: unlike next-step and
# set-workflow-type, record-skip-judgment does NOT validate the session-id
# charset up front. A traversal-shaped id is only stopped later, by the
# write-back verification — so the code is the record-failure code for the path
# taken (1 without --advance, 2 with it), not the argument error its two sibling
# CLIs return. Reported as a CPR-ORTH gap; pinned so a fix updates it knowingly.
expect_reject "C10-3g: path-traversal --session is stopped by write-back verification" 1 -- \
  node "$RSJ" --session "../evil" --target outline --c1 true --c2 true
check_contains "C10-3g: the diagnostic is the verification failure, not a charset error" \
  "write verification failed" "$ERR"
expect_reject "C10-3h: the same id on the --advance path carries the record-failure code" 2 -- \
  node "$RSJ" --session "../evil" --target outline --c1 true --c2 true --advance

echo ""
echo "=== C10-4: set-workflow-type argument handling ==="
expect_reject "C10-4a: --type with no value" 1 -- \
  node "$SWT" --session guard --type
expect_reject "C10-4b: unknown type" 1 -- \
  node "$SWT" --session guard --type wf-hybrid
expect_reject "C10-4c: --session containing a space (positional form)" 1 -- \
  node "$SWT" "a b" wf-code
expect_reject "C10-4d: path-traversal session (positional form)" 1 -- \
  node "$SWT" "../evil" wf-code
expect_reject "C10-4e: mixing the positional and flag forms" 1 -- \
  node "$SWT" guard wf-meta --session guard
check_contains "C10-4e: the diagnostic names the mixing rule" \
  "do not mix the positional form" "$ERR"
expect_reject "C10-4f: any flag alongside a positional pair is the mixed form" 1 -- \
  node "$SWT" guard wf-meta --advance --step research --status complete
expect_reject "C10-4g: --next without --advance" 1 -- \
  node "$SWT" --session guard --type wf-code --next
expect_reject "C10-4h: --step/--status without --advance" 1 -- \
  node "$SWT" --session guard --type wf-code --step research --status complete
expect_reject "C10-4i: --advance --status in_progress" 1 -- \
  node "$SWT" --session guard --type wf-code --advance --step research --status in_progress
expect_reject "C10-4j: unknown flag" 1 -- \
  node "$SWT" --session guard --type wf-code --bogus
expect_reject "C10-4k: unknown step for --advance" 1 -- \
  node "$SWT" --session guard --type wf-code --advance --step no_such_step --status complete

echo ""
echo "=== C10-5: record-complexity-and-skip argument handling ==="
# This CLI keeps TWO distinct failure codes: 1 for a missing required value and
# 2 for an unknown flag. Its `--session` uses require_value, which checks
# whether the next token itself looks like a flag (`--*`) before consuming it —
# so a value-less --session immediately followed by another flag is rejected
# as a missing value (exit 2), not treated as swallowing that flag's token.
expect_reject "C10-5a: --session immediately followed by another flag is a missing value" 2 -- \
  env AGENTS_CONFIG_DIR="$AGENTS_DIR_N" bash "$RCAS" --session --target outline --signals ""
check_contains "C10-5a: the diagnostic names the missing value" "--session requires a value" "$ERR"
expect_reject "C10-5b: empty --session" 1 -- \
  env AGENTS_CONFIG_DIR="$AGENTS_DIR_N" bash "$RCAS" --session "" --signals "" --target outline
expect_reject "C10-5c: missing --session entirely" 1 -- \
  env AGENTS_CONFIG_DIR="$AGENTS_DIR_N" bash "$RCAS" --signals "" --target outline
expect_reject "C10-5d: missing --signals is a usage error, not a default" 2 -- \
  env AGENTS_CONFIG_DIR="$AGENTS_DIR_N" bash "$RCAS" --session guard --target outline
expect_reject "C10-5d2: the retired --verdict flag is rejected the same way" 2 -- \
  env AGENTS_CONFIG_DIR="$AGENTS_DIR_N" bash "$RCAS" --session guard --verdict low --signals "" --target outline
expect_reject "C10-5e: unknown flag on the advance path still exits 2, not 3" 2 -- \
  env AGENTS_CONFIG_DIR="$AGENTS_DIR_N" bash "$RCAS" --session guard --signals "" --target outline --advance --bogus
expect_reject "C10-5f: path-traversal --session" 1 -- \
  env AGENTS_CONFIG_DIR="$AGENTS_DIR_N" bash "$RCAS" --session "../evil" --signals "" --target outline

echo ""
echo "=== C10-6: boundary values that are REJECTED ==="
# A 5000-character session id is syntactically legal ([A-Za-z0-9_-]+) but exceeds
# the filesystem's name limit, so it fails at the write rather than at parse time:
# the record-failure code, and nothing created.
LONG_SID="$(node -e 'process.stdout.write("a".repeat(5000))')"
check "C10-6a: the long session id really is 5000 chars" 5000 "${#LONG_SID}"
expect_reject "C10-6a: a 5000-char --session fails at the write" 2 -- \
  node "$NS" --session "$LONG_SID" --advance --step research --status complete
# A corrupt state file is an input to argument handling too: the CLI must refuse
# rather than overwrite the unreadable bytes with a fresh state.
printf '%s' '{"steps": truncated' > "$WORKFLOW_DIR/corrupt.json"
CORRUPT_BEFORE="$(wf_snapshot)"
run_cli node "$NS" --session corrupt --advance --step research --status complete
check "C10-6b: a corrupt state file exits 2" 2 "$RC"
check "C10-6b: the corrupt bytes are not rewritten" "$CORRUPT_BEFORE" "$(wf_snapshot)"

echo ""
echo "=== C10-7: boundary values that are ACCEPTED ==="
# The symmetric half of C10-6: over-strict input handling is a bug too, so the
# accepted edges are pinned as explicitly as the rejected ones. Shell
# metacharacters in a skip reason travel from argv into a JSON state field; a
# CLI that shelled out would either execute this or mangle it.
NASTY='needs $(id) and `whoami` and "quotes" and ;rm -rf / to stay literal'
make_state c107a "workflow_init clarify_intent"
run_cli node "$NS" --session c107a --advance --step research --status skipped --skip-reason "$NASTY"
check "C10-7a: a reason full of shell metacharacters is accepted" 0 "$RC"
check "C10-7a: the reason is stored verbatim" '"skipped"' "$(step_status c107a research)"
check_contains "C10-7a: the command substitution text survives unexpanded" \
  '$(id)' "$(PROBE_SID=c107a PROBE_STEP=research PROBE_FIELD=skip_reason \
      run_with_timeout node "$PROBE" field 2>/dev/null)"

# A very long but non-repeating reason. (A long run of one repeated character is
# rejected by validateSkipReason as a non-explanation, which is a different rule.)
LONG_REASON="$(node -e 'let s="";for(let i=0;i<800;i++)s+="reason-part-"+i+" ";process.stdout.write(s.trim())')"
check "C10-7b: the long reason is over 5000 chars" yes \
  "$([ "${#LONG_REASON}" -gt 5000 ] && echo yes || echo no)"
make_state c107b "workflow_init clarify_intent"
run_cli node "$NS" --session c107b --advance --step research --status skipped --skip-reason "$LONG_REASON"
check "C10-7b: a very long reason is accepted" 0 "$RC"
check "C10-7b: research is recorded skipped" '"skipped"' "$(step_status c107b research)"

# A session with no state file at all: CURRENT BEHAVIOR is that the forward
# operation CREATES the state rather than refusing. Pinned deliberately —
# workflow-init's very first advance depends on it.
run_cli node "$NS" --session c107c --advance --step workflow_init --status complete
check "C10-7c: an unknown session id is accepted and creates its state" 0 "$RC"
check "C10-7c: the step is recorded" '"complete"' "$(step_status c107c workflow_init)"

echo ""
echo "=== C10-8: the guard session survived every rejected call ==="
# One last end-to-end statement: after ~40 malformed invocations, the pre-existing
# session is exactly as it was.
check "C10-8: guard research is still complete" '"complete"' "$(step_status guard research)"
check "C10-8: guard outline is still pending" '"pending"' "$(step_status guard outline)"
LOCKS="$(ls -d "$WORKFLOW_DIR"/*.lock 2>/dev/null | wc -l | tr -d ' ')"
check "C10-8: no lock entry was left behind" 0 "$LOCKS"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
