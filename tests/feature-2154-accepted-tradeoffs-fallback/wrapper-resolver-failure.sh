# Tests: skills/make-outline-plan/scripts/run-codex-review-loop.sh, skills/make-detail-plan/scripts/run-codex-review-loop.sh, skills/review-plan-security/scripts/run-codex-review-loop.sh, skills/review-tests/scripts/run-codex-review-loop.sh, bin/review-plan-codex, bin/resolve-accepted-tradeoffs-file
# Tags: codex, review, accepted-tradeoffs, fallback, exit-code, fail-closed, scope:issue-specific
# WRAPPER FAILURE PATH (F1-F4) — the `|| exit 4` remap each stage wrapper puts on
# the resolver call. Layer A only ever drives the SUCCESS path, so nothing proved
# that a resolver refusal (exit 3) or usage error (exit 2) is remapped to 4 (HALT)
# rather than leaking through as 2/3 — codes the 0-7 review-loop protocol already
# spends on ESCALATE / codex-unavailable — nor that the downstream reviewer is
# never reached once the tradeoffs source is untrusted.
# Sourced by tests/feature-2154-accepted-tradeoffs-fallback.sh.
echo "=== Wrapper failure path: resolver 2/3 → wrapper 4, downstream never run ==="

# TL3 gap (what this file does NOT catch): bin/run-codex-review-loop is stubbed,
# so how a real review loop reacts to HALT is not observed — only that the
# wrapper never reaches it. Closest-to-action: check-verification-gate.sh.

# CPR-ORTH: one fixture, all four stages. Each wrapper carries its own copy of
# the resolver line, so a remap present in three of them and missing in the
# fourth is exactly the defect this table exists to find.
WF_ROOT="$TMPROOT/wrapfail-agents"
mkdir -p "$WF_ROOT"
cp -r "$AGENTS_ROOT/bin" "$WF_ROOT/bin"
cp -r "$AGENTS_ROOT/hooks" "$WF_ROOT/hooks"

# The downstream canary: bin/run-codex-review-loop is what every wrapper calls
# after the resolver. It writes a file when invoked, so "the reviewer never ran"
# is judged by an observable side effect rather than by the exit code alone.
WF_CANARY="$TMPROOT/wrapfail-downstream-canary.txt"
{
  printf '#!/bin/bash\n'
  printf 'printf "invoked\\n" > "%s"\n' "$WF_CANARY"
  printf 'exit 0\n'
} > "$WF_ROOT/bin/run-codex-review-loop"
chmod +x "$WF_ROOT/bin/run-codex-review-loop"

WF_REPO="$TMPROOT/wrapfail-repo"
mkdir -p "$WF_REPO"
git -C "$WF_REPO" init -q >/dev/null 2>&1
git -C "$WF_REPO" config core.hooksPath /dev/null >/dev/null 2>&1

WF_STAGES="make-outline-plan make-detail-plan review-plan-security review-tests"
# Each stage reviews its own draft; a missing draft is a different failure mode.
wf_draft_for() {
  case "$1" in
    make-outline-plan) printf 'outline' ;;
    review-tests) printf 'test-review' ;;
    *) printf 'detail' ;;
  esac
}

# wf_run <tag> <stage> <session-id> → WF_RC / WF_OUT / WF_ERR, canary removed first.
wf_run() {
  local tag="$1" stage="$2" sid="$3"
  local pd="$TMPROOT/wfplans-$tag-$stage"
  mkdir -p "$pd"
  printf '# %s draft\n' "$stage" > "$pd/$sid-$(wf_draft_for "$stage").md" 2>/dev/null || true
  printf '# intent\n\n## Accepted Tradeoffs\n\nsettled\n' > "$pd/$sid-intent.md" 2>/dev/null || true
  rm -f "$WF_CANARY"
  local outf="$TMPROOT/wrapfail-out.txt" errf="$TMPROOT/wrapfail-err.txt"
  rm -f "$outf" "$errf"
  WF_RC=0
  (
    cd "$WF_REPO" || exit 1
    export AGENTS_CONFIG_DIR="$WF_ROOT"
    export SESSION_ID="$sid"
    export PLANS_DIR="$pd"
    export EXTENSIONS_USED=0
    export REVIEW_TESTS_FULL_SCAN=1
    with_timeout bash "$AGENTS_ROOT/skills/$stage/scripts/run-codex-review-loop.sh" > "$outf" 2>"$errf"
  ) || WF_RC=$?
  WF_OUT="$(cat "$outf" 2>/dev/null || true)"
  WF_ERR="$(cat "$errf" 2>/dev/null || true)"
}

# --- F1 (anti-vacuity control, protection-fix-tests.md Pattern 4): the SANCTIONED
# path. Without it "the canary is absent" in F2-F4 could pass simply because the
# stub is never reachable in this fixture at all, and every refusal row below
# would be proving nothing.
for wf_stage in $WF_STAGES; do
  wf_run f1 "$wf_stage" "sidF1"
  assert_eq "F1 ($wf_stage): a resolvable tradeoffs source → wrapper exit 0" "0" "$WF_RC"
  if [[ -e "$WF_CANARY" ]]; then
    pass "F1 ($wf_stage): the downstream review loop WAS invoked (canary present) — the canary can fire"
  else
    fail "F1 ($wf_stage): the downstream review loop was never invoked on the success path; F2-F4's canary rows would be vacuous"
  fi
done

# --- F2: a REAL resolver refusal (exit 3). The session id carries `../..`, so the
# last candidate path lexically leaves PLANS_DIR and the resolver refuses to
# forward it — the containment refusal S5/S22 pin at the resolver, driven here
# through the wrapper that must translate it.
WF_ESC_SID='../../wrapfail-escape'
WF_ESC_TEXT='resolve-accepted-tradeoffs-file: the last candidate path leaves the plans directory'
for wf_stage in $WF_STAGES; do
  wf_run f2 "$wf_stage" "$WF_ESC_SID"
  assert_eq "F2 ($wf_stage): resolver refusal (exit 3) → wrapper exit 4 (HALT)" "4" "$WF_RC"
  # (b) the operator must still learn WHY: the wrapper neither swallows nor
  # rewrites the resolver's own diagnostic.
  if [[ "$WF_ERR" == *"$WF_ESC_TEXT"* ]]; then
    pass "F2 ($wf_stage): the resolver's own stderr diagnostic reaches the wrapper's stderr"
  else
    fail "F2 ($wf_stage): the resolver's diagnostic was lost — stderr: [$WF_ERR]"
  fi
  # (c) fail CLOSED: nothing downstream may run on an untrusted tradeoffs source.
  if [[ -e "$WF_CANARY" ]]; then
    fail "F2 ($wf_stage): the downstream review loop RAN despite the resolver refusal (canary $WF_CANARY created)"
  else
    pass "F2 ($wf_stage): the downstream review loop was never invoked (canary absent)"
  fi
  assert_eq "F2 ($wf_stage): the refusal emits nothing on stdout" "" "$WF_OUT"
done

# --- F3: the resolver's OTHER non-zero status, exit 2 (usage). No wrapper can
# produce it with the real resolver — all four pass a fixed, valid argument shape
# — so the resolver is replaced by a stub for this row only. The wrapper, not the
# resolver, is the unit under test here: `|| exit 4` must cover EVERY non-zero
# status, not just the containment refusal F2 happens to reach.
WF_REAL_RESOLVER="$WF_ROOT/bin/resolve-accepted-tradeoffs-file"
WF_STUB_MARKER='WRAPFAIL_STUB_MARKER_2154_QZWX'
if [[ -e "$WF_REAL_RESOLVER" ]]; then mv "$WF_REAL_RESOLVER" "$WF_REAL_RESOLVER.real"; fi
{
  printf '#!/bin/bash\n'
  printf 'echo "%s: simulated usage error" >&2\n' "$WF_STUB_MARKER"
  printf 'exit 2\n'
} > "$WF_REAL_RESOLVER"
chmod +x "$WF_REAL_RESOLVER"
for wf_stage in $WF_STAGES; do
  wf_run f3 "$wf_stage" "sidF3"
  assert_eq "F3 ($wf_stage): resolver usage error (exit 2) → wrapper exit 4 (HALT)" "4" "$WF_RC"
  if [[ "$WF_ERR" == *"$WF_STUB_MARKER"* ]]; then
    pass "F3 ($wf_stage): the resolver's stderr diagnostic reaches the wrapper's stderr"
  else
    fail "F3 ($wf_stage): the resolver's diagnostic was lost — stderr: [$WF_ERR]"
  fi
  if [[ -e "$WF_CANARY" ]]; then
    fail "F3 ($wf_stage): the downstream review loop RAN despite the resolver usage error (canary $WF_CANARY created)"
  else
    pass "F3 ($wf_stage): the downstream review loop was never invoked (canary absent)"
  fi
done

# --- F4: the exit code must be remapped, not merely non-zero. A wrapper that
# forwarded the resolver's own status would answer 5 here; the 0-7 protocol reads
# 5 as a distinct outcome, so "any failure" is not the contract — 4 is.
{
  printf '#!/bin/bash\n'
  printf 'echo "%s: simulated out-of-protocol status" >&2\n' "$WF_STUB_MARKER"
  printf 'exit 5\n'
} > "$WF_REAL_RESOLVER"
chmod +x "$WF_REAL_RESOLVER"
for wf_stage in $WF_STAGES; do
  wf_run f4 "$wf_stage" "sidF4"
  assert_eq "F4 ($wf_stage): an out-of-protocol resolver status (exit 5) is still remapped to 4" "4" "$WF_RC"
  if [[ -e "$WF_CANARY" ]]; then
    fail "F4 ($wf_stage): the downstream review loop RAN despite the resolver failure (canary $WF_CANARY created)"
  else
    pass "F4 ($wf_stage): the downstream review loop was never invoked (canary absent)"
  fi
done
rm -f "$WF_REAL_RESOLVER"
if [[ -e "$WF_REAL_RESOLVER.real" ]]; then mv "$WF_REAL_RESOLVER.real" "$WF_REAL_RESOLVER"; fi

# --- F5 (C6): CONFIDENTIALITY of the resolved tradeoffs content, end to end. This
# change makes a plan's `## Accepted Tradeoffs` section flow resolver → prompt →
# codex, and `bin/review-plan-codex` writes that whole prompt to a `mktemp` file and
# appends a round record for every run. Both are new places the settled text can come
# to rest. Nothing above observes where the content ENDS UP — F1-F4 judge exit codes
# and a canary. Here the content carries a unique marker and every sink the run can
# touch (stdout, stderr, the round/debug logs, the temp dir, HOME) is scanned for it;
# only the mocked codex's stdin capture may hold it.
F5_SECRET='F5_TRADEOFF_SECRET_2154_QZWX'
F5_HOME="$TMPROOT/f5-home"
F5_LOGDIR="$TMPROOT/f5-logs"
F5_TMPDIR="$TMPROOT/f5-tmp"
F5_PLANS="$TMPROOT/f5-plans"
mkdir -p "$F5_HOME" "$F5_LOGDIR" "$F5_TMPDIR" "$F5_PLANS"
{
  printf '# intent\n\n## Accepted Tradeoffs\n\n'
  printf -- '- %s: TL3 coverage delegated to manual verification.\n\n' "$F5_SECRET"
  printf '## Class members\n\n- review-tests — triage: MUST\n'
} > "$F5_PLANS/F5SID-intent.md"
F5_INPUT="$TMPROOT/f5-input.md"
printf '# tests/example.sh\n\nassert_eq "n" "$w" "$g"\n' > "$F5_INPUT"
F5_CONTEXT="$TMPROOT/f5-context.md"
printf '## Test Case Categories\n\n- Normal cases\n' > "$F5_CONTEXT"

# The path really comes from the resolver, so the marker travels the production
# route rather than being handed to review-plan-codex directly.
F5_RESOLVED="$(with_timeout bash "$AGENTS_ROOT/bin/resolve-accepted-tradeoffs-file" "$F5_PLANS" F5SID detail outline intent 2>/dev/null)"
assert_eq "F5-0: the resolver selects the tradeoffs file carrying the marker" \
  "$F5_PLANS/F5SID-intent.md" "$F5_RESOLVED"

F5_OUT_F="$TMPROOT/f5-stdout.txt"; F5_ERR_F="$TMPROOT/f5-stderr.txt"
F5_RC=0
(
  export PATH="$MOCK_BIN_PATH:$PATH"
  export HOME="$F5_HOME"
  export TMPDIR="$F5_TMPDIR" TMP="$F5_TMPDIR" TEMP="$F5_TMPDIR"
  # Debug logging ON: its stderr copy is one of the sinks the scan must clear.
  export MCP_FS_DEBUG=1
  with_timeout bash "$REVIEW_PLAN_CODEX" \
    --input "$F5_INPUT" --format test-review \
    --accepted-tradeoffs "$F5_RESOLVED" --context "$F5_CONTEXT" \
    --session-id F5SID --log-dir "$F5_LOGDIR" \
    > "$F5_OUT_F" 2>"$F5_ERR_F"
) || F5_RC=$?

# f5_hits <dir> — every file under dir whose bytes carry the marker.
f5_hits() { grep -rlF -- "$F5_SECRET" "$1" 2>/dev/null | tr '\n' ' '; }

# F5-1 — anti-vacuity in both directions: the run must have reached codex, and the
# marker must really be in the prompt. Without this every "absent" row below would
# pass on a run that never happened.
if [[ -f "$PROMPT_CAPTURE" ]] && grep -qF -- "$F5_SECRET" "$PROMPT_CAPTURE"; then
  pass "F5-1: the marker reached the mocked codex's stdin — the intended destination, and the scan is not vacuous"
else
  fail "F5-1: the marker never reached the codex prompt capture (rc=$F5_RC; stderr: $(tail -2 "$F5_ERR_F" 2>/dev/null | tr '\n' ' '))"
fi

# F5a/F5b — the two streams the calling skill splices into its own transcript.
if grep -qF -- "$F5_SECRET" "$F5_OUT_F" 2>/dev/null; then
  fail "F5a: the settled-decisions content was echoed onto stdout, where the caller pastes it into the review transcript"
else
  pass "F5a: the settled-decisions content never appears on stdout"
fi
if grep -qF -- "$F5_SECRET" "$F5_ERR_F" 2>/dev/null; then
  fail "F5b: the settled-decisions content was echoed onto stderr"
else
  pass "F5b: the settled-decisions content never appears on stderr"
fi

# F5c — the round log must exist, or F5d would be scanning an empty directory.
if [[ -s "$F5_LOGDIR/F5SID-plan.jsonl" ]]; then
  pass "F5c: the round log was written — the log-directory scan has something to judge"
else
  fail "F5c: no round log at $F5_LOGDIR/F5SID-plan.jsonl; F5d would pass on an empty directory"
fi
F5_LOG_HITS="$(f5_hits "$F5_LOGDIR")"
if [[ -z "$F5_LOG_HITS" ]]; then
  pass "F5d: no file in the log directory carries the marker (round log and the MCP_FS_DEBUG stderr copy included)"
else
  fail "F5d: the settled-decisions content was persisted to a log file: $F5_LOG_HITS"
fi
F5_HOME_HITS="$(f5_hits "$F5_HOME")"
if [[ -z "$F5_HOME_HITS" ]]; then
  pass "F5e: nothing under the isolated HOME carries the marker (codex-core's own session log included)"
else
  fail "F5e: the settled-decisions content was persisted under HOME: $F5_HOME_HITS"
fi

# F5f — the prompt is staged through `mktemp`, so the temp dir holds the marker
# WHILE codex runs. The claim is that the EXIT trap leaves nothing behind: a
# residual prompt file would expose the settled text to every user on the host.
F5_TMP_HITS="$(f5_hits "$F5_TMPDIR")"
if [[ -z "$F5_TMP_HITS" ]]; then
  pass "F5f: no residual temp file carries the marker after the run exits"
else
  fail "F5f: the prompt temp file survived the run and still carries the settled-decisions content: $F5_TMP_HITS"
fi
F5_TMP_LEFT="$(find "$F5_TMPDIR" -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
assert_eq "F5g: the run leaves no file at all behind in its temp directory" "0" "$F5_TMP_LEFT"

# SKIPPED: that the real codex CLI does not itself persist the prompt.
# Because: codex is mocked here, so only what review-plan-codex writes is
#          observable; the marker's presence in the mock's stdin capture is the
#          hand-off point, not a claim about what codex does with it afterwards.
# TL3 gap: a real codex round shows whether the upstream service or its own cache
#          retains the settled-decisions text.

echo ""

# F6 (C5): leak-check on FAILURE paths — F5 above only proves no leak on the
# SUCCESSFUL mock-codex path. See docs at each f6_check row for what each sink
# guards against; script below drives two rows: a non-zero codex exit and a
# codex process killed past a short deadline (interruption's observable shape).
F6_SECRET='F6_TRADEOFF_SECRET_2154_QZWX'
F6_PLANS="$TMPROOT/f6-plans"
mkdir -p "$F6_PLANS"
{
  printf '# intent\n\n## Accepted Tradeoffs\n\n'
  printf -- '- %s: TL3 coverage delegated to manual verification.\n\n' "$F6_SECRET"
  printf '## Class members\n\n- review-tests — triage: MUST\n'
} > "$F6_PLANS/F6SID-intent.md"
F6_RESOLVED="$(with_timeout bash "$AGENTS_ROOT/bin/resolve-accepted-tradeoffs-file" "$F6_PLANS" F6SID detail outline intent 2>/dev/null)"

# f6_short_timeout <seconds> <cmd...> — with_timeout's short-bound sibling;
# the F6-hang row must not cost with_timeout's 90s per run.
f6_short_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else perl -e 'alarm shift; exec @ARGV' -- "$secs" "$@"; fi
}

# f6_hits <dir> — every file under dir whose bytes carry the F6 marker.
f6_hits() { grep -rlF -- "$F6_SECRET" "$1" 2>/dev/null | tr '\n' ' '; }

# f6_check <tag> — F5a/b/d/e/f/g's sink scan, run against the just-completed f6 run.
f6_check() {
  local tag="$1"
  if grep -qF -- "$F6_SECRET" "$F6_OUT_F" 2>/dev/null; then
    fail "F6a ($tag): the settled-decisions content was echoed onto stdout on the failure path"
  else
    pass "F6a ($tag): stdout carries no settled-decisions content on the failure path"
  fi
  local err_hits; err_hits="$(f6_hits "$F6_ERR_F")"
  if [[ -n "$err_hits" ]]; then
    fail "F6b ($tag): the settled-decisions content was echoed onto stderr on the failure path"
  else
    pass "F6b ($tag): stderr carries no settled-decisions content on the failure path"
  fi
  local log_hits; log_hits="$(f6_hits "$F6_LOGDIR")"
  if [[ -n "$log_hits" ]]; then
    fail "F6c ($tag): the settled-decisions content was persisted to a log file on the failure path: $log_hits"
  else
    pass "F6c ($tag): no log-directory file carries the marker on the failure path"
  fi
  local home_hits; home_hits="$(f6_hits "$F6_HOME")"
  if [[ -n "$home_hits" ]]; then
    fail "F6d ($tag): the settled-decisions content was persisted under HOME on the failure path: $home_hits"
  else
    pass "F6d ($tag): nothing under the isolated HOME carries the marker on the failure path"
  fi
  local tmp_hits; tmp_hits="$(f6_hits "$F6_TMPDIR")"
  if [[ -n "$tmp_hits" ]]; then
    fail "F6e ($tag): a residual temp file carries the marker after the killed/failed run: $tmp_hits"
  else
    pass "F6e ($tag): no residual temp file carries the marker after the killed/failed run"
  fi
}

# F6-nonzero: codex reads the prompt then exits 1 (a real API/CLI error).
F6_MOCK_A="$TMPROOT/f6-mock-a"
mkdir -p "$F6_MOCK_A"
{
  printf '#!/usr/bin/env bash\n'
  printf 'cat > /dev/null\n'
  printf 'echo "simulated codex failure" >&2\n'
  printf 'exit 1\n'
} > "$F6_MOCK_A/codex"
chmod +x "$F6_MOCK_A/codex"
if command -v cygpath >/dev/null 2>&1; then F6_MOCK_A_PATH="$(cygpath -u "$F6_MOCK_A")"; else F6_MOCK_A_PATH="$F6_MOCK_A"; fi

F6_HOME="$TMPROOT/f6a-home"; F6_LOGDIR="$TMPROOT/f6a-logs"; F6_TMPDIR="$TMPROOT/f6a-tmp"
mkdir -p "$F6_HOME" "$F6_LOGDIR" "$F6_TMPDIR"
F6_OUT_F="$TMPROOT/f6a-stdout.txt"; F6_ERR_F="$TMPROOT/f6a-stderr.txt"
F6_RC=0
(
  export PATH="$F6_MOCK_A_PATH:$PATH"
  export HOME="$F6_HOME"
  export TMPDIR="$F6_TMPDIR" TMP="$F6_TMPDIR" TEMP="$F6_TMPDIR"
  with_timeout bash "$REVIEW_PLAN_CODEX" \
    --input "$F5_INPUT" --format test-review \
    --accepted-tradeoffs "$F6_RESOLVED" --context "$F5_CONTEXT" \
    --session-id F6SID --log-dir "$F6_LOGDIR" \
    > "$F6_OUT_F" 2>"$F6_ERR_F"
) || F6_RC=$?
# Fail-soft contract (bin/review-plan-codex's own `case $codex_exit in ... esac`
# always falls through to `exit 0`; failure is signaled on stdout only, never via
# the wrapper's own exit code — same pattern as log_persist_or_fail's exit 0).
assert_eq "F6-nonzero: review-plan-codex exits 0 even when the mocked codex fails (fail-soft; failure is signaled on stdout, not via exit code)" "0" "$F6_RC"
if grep -qF -- '## Codex Plan Review: FAILED' "$F6_OUT_F" 2>/dev/null; then
  pass "F6-nonzero: a FAILED verdict line is emitted on stdout"
else
  fail "F6-nonzero: no FAILED verdict line found on stdout: $(cat "$F6_OUT_F" 2>/dev/null)"
fi
f6_check "nonzero-exit"

# F6-hang: codex reads the prompt then hangs — a short external deadline kills
# the whole run before it exits. Interruption mid-run (Ctrl-C, deadline,
# SIGTERM) has the same observable shape: torn down before its own cleanup
# path runs, not before the prompt was read.
F6_HOME="$TMPROOT/f6b-home"; F6_LOGDIR="$TMPROOT/f6b-logs"; F6_TMPDIR="$TMPROOT/f6b-tmp"
mkdir -p "$F6_HOME" "$F6_LOGDIR" "$F6_TMPDIR"

# f6_write_hang_mock <dir> <precond-file> <tmpdir> <sleep-secs> — a codex that reads
# the prompt, records WHERE the marker is staged, then hangs.
# The precondition file is the anti-vacuity half of every "no residual temp file"
# row below (the S13-0 / F5-1 idiom): on a host whose mktemp ignores TMPDIR the
# prompt is staged elsewhere, and "the scan found nothing" would then be true
# before the run was even interrupted. Grepping from INSIDE the still-running
# codex is the only moment the staged prompt is observable.
f6_write_hang_mock() {
  local dir="$1" precond="$2" tmpd="$3" secs="$4"
  mkdir -p "$dir"
  rm -f "$precond"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'cat > /dev/null\n'
    printf 'grep -rlF -- "%s" "%s" > "%s" 2>/dev/null || true\n' "$F6_SECRET" "$tmpd" "$precond"
    printf 'sleep %s\n' "$secs"
  } > "$dir/codex"
  chmod +x "$dir/codex"
}

# f6_assert_staged <tag> <precond-file> — the temp file really existed under TMPDIR.
f6_assert_staged() {
  local tag="$1" precond="$2"
  if [[ -s "$precond" ]]; then
    pass "$tag: the prompt temp file carrying the settled decisions really existed under TMPDIR while codex ran ($(tr '\n' ' ' < "$precond")) — the cleanup rows below are not vacuous"
  else
    fail "$tag: no temp file under TMPDIR ever carried the marker, so 'nothing survives' proves nothing about cleanup"
  fi
}

F6_MOCK_B="$TMPROOT/f6-mock-b"
F6B_PRECOND="$TMPROOT/f6b-staged-prompt.txt"
f6_write_hang_mock "$F6_MOCK_B" "$F6B_PRECOND" "$F6_TMPDIR" 30
if command -v cygpath >/dev/null 2>&1; then F6_MOCK_B_PATH="$(cygpath -u "$F6_MOCK_B")"; else F6_MOCK_B_PATH="$F6_MOCK_B"; fi

F6_OUT_F="$TMPROOT/f6b-stdout.txt"; F6_ERR_F="$TMPROOT/f6b-stderr.txt"
F6_RC=0
(
  export PATH="$F6_MOCK_B_PATH:$PATH"
  export HOME="$F6_HOME"
  export TMPDIR="$F6_TMPDIR" TMP="$F6_TMPDIR" TEMP="$F6_TMPDIR"
  f6_short_timeout 3 bash "$REVIEW_PLAN_CODEX" \
    --input "$F5_INPUT" --format test-review \
    --accepted-tradeoffs "$F6_RESOLVED" --context "$F5_CONTEXT" \
    --session-id F6SID --log-dir "$F6_LOGDIR" \
    > "$F6_OUT_F" 2>"$F6_ERR_F"
) || F6_RC=$?
if [[ "$F6_RC" -ne 0 ]]; then
  pass "F6-hang: the deadline kills the run and it surfaces as a non-zero exit ($F6_RC)"
else
  fail "F6-hang: review-plan-codex exited 0 despite codex hanging past the deadline"
fi
f6_assert_staged "F6-hang-0" "$F6B_PRECOND"
f6_check "killed-by-timeout"

echo ""

# F7 (CPR-ORTH with F6-hang): the OTHER half of `trap 'exit 143' TERM INT`.
# F6-hang arrives through `timeout`, which sends SIGTERM — so the INT arm, the one
# a real Ctrl-C at the operator's terminal takes, was never exercised. A trap
# registered for TERM alone would satisfy every row above and still leave the
# settled-decisions prompt on disk when a reviewer interrupts the loop by hand.
F7_HOME="$TMPROOT/f7-home"; F7_LOGDIR="$TMPROOT/f7-logs"; F7_TMPDIR="$TMPROOT/f7-tmp"
mkdir -p "$F7_HOME" "$F7_LOGDIR" "$F7_TMPDIR"
F7_MOCK="$TMPROOT/f7-mock"
F7_PRECOND="$TMPROOT/f7-staged-prompt.txt"
f6_write_hang_mock "$F7_MOCK" "$F7_PRECOND" "$F7_TMPDIR" 12
if command -v cygpath >/dev/null 2>&1; then F7_MOCK_PATH="$(cygpath -u "$F7_MOCK")"; else F7_MOCK_PATH="$F7_MOCK"; fi

# The signal must reach review-plan-codex's OWN shell, so the runner `exec`s it:
# the backgrounded pid then IS that shell, not a parent that would absorb the INT.
F7_OUT_F="$TMPROOT/f7-stdout.txt"; F7_ERR_F="$TMPROOT/f7-stderr.txt"
F7_RUNNER="$TMPROOT/f7-runner.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'export PATH="%s:$PATH"\n' "$F7_MOCK_PATH"
  printf 'export HOME="%s"\n' "$F7_HOME"
  printf 'export TMPDIR="%s" TMP="%s" TEMP="%s"\n' "$F7_TMPDIR" "$F7_TMPDIR" "$F7_TMPDIR"
  printf 'exec bash "%s" --input "%s" --format test-review --accepted-tradeoffs "%s" --context "%s" --session-id F7SID --log-dir "%s"\n' \
    "$REVIEW_PLAN_CODEX" "$F5_INPUT" "$F6_RESOLVED" "$F5_CONTEXT" "$F7_LOGDIR"
} > "$F7_RUNNER"

# Job control ON for the launch: without it a shell backgrounds the job with SIGINT
# set to SIG_IGN, and a signal ignored on entry can never be trapped — the run
# under test would silently be immune to the very signal this case sends, and F7
# would "pass" on an ordinary completion. `set -m` gives the child the default
# disposition, so its own `trap ... INT` is the thing being exercised.
set -m
bash "$F7_RUNNER" > "$F7_OUT_F" 2> "$F7_ERR_F" &
F7_PID=$!
set +m
# Wait for the mock to report the staged prompt, so the interrupt lands while the
# temp file provably exists rather than before it was written.
F7_WAITED=0
while [[ "$F7_WAITED" -lt 100 ]]; do
  [[ -s "$F7_PRECOND" ]] && break
  sleep 0.1
  F7_WAITED=$((F7_WAITED + 1))
done
f6_assert_staged "F7-0" "$F7_PRECOND"
kill -INT "$F7_PID" 2>/dev/null || true
F7_RC=0
wait "$F7_PID" || F7_RC=$?

# 143 exactly, observed and pinned: the handler is a literal `exit 143` for BOTH
# signals, so SIGINT does not produce the conventional 130 here. 130 would mean
# the default disposition ran instead of the trap — and then the EXIT trap, which
# is what deletes the prompt temp file, never fired.
assert_eq "F7: SIGINT terminates review-plan-codex through the TERM/INT trap's own 'exit 143' (130 would mean the default disposition ran and the EXIT cleanup was skipped)" \
  "143" "$F7_RC"
F6_OUT_F="$F7_OUT_F"; F6_ERR_F="$F7_ERR_F"
F6_LOGDIR="$F7_LOGDIR"; F6_HOME="$F7_HOME"; F6_TMPDIR="$F7_TMPDIR"
f6_check "killed-by-SIGINT"

echo ""
