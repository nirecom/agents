#!/usr/bin/env bash
# Tests: hooks/workflow-state/record-step-verdict.js, hooks/workflow-state/evidence-resolver.js, hooks/workflow-gate/staged-evidence.js, hooks/workflow-mark.js, hooks/workflow-mark/mark-step-handler.js, hooks/lib/path-normalize.js, bin/workflow/next-step
# Tags: tl2, workflow, write-tests, evidence, cwd, door-parity, scope:issue-specific, pwsh-not-required

# INV-1 (#2102): the two write_tests doors resolve the evidence repo from different
# inputs -- the CLI door from the node process CWD (resolveTrustedRepoDir, which
# ignores the forgeable CLAUDE_PROJECT_DIR), the sentinel door from the payload's
# input.cwd (resolveRepoCwd). Both doors are driven across the same 3 directories.

# TL3 gap (what this test does NOT catch): whether a live model issues the CLI call from
# the linked-worktree CWD rather than under a `cd <main> &&` prefix, and whether
# settings.json permissions.allow admits the migrated shape. Closest-to-action mitigation:
# WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"
NS="$AGENTS_DIR_N/bin/workflow/next-step"
MARK_HOOK="$AGENTS_DIR_N/hooks/workflow-mark.js"
PROBE="$AGENTS_DIR_N/tests/feature-1644-advance-transaction/state-probe.js"
WFSTATE_MODULE="$AGENTS_DIR_N/hooks/workflow-state"; export WFSTATE_MODULE

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
WORKFLOW_DIR="$TMPDIR_BASE/wf"; PLANS_DIR="$TMPDIR_BASE/plans"; NEUTRAL="$TMPDIR_BASE/neutral"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR" "$NEUTRAL"
CLAUDE_WORKFLOW_DIR="$(nrm "$WORKFLOW_DIR")"; export CLAUDE_WORKFLOW_DIR
WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"; export WORKFLOW_PLANS_DIR
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
CONFIG_EMPTY="$TMPDIR_BASE/cfg"; mkdir -p "$CONFIG_EMPTY"; : > "$CONFIG_EMPTY/.env"
AGENTS_CONFIG_DIR="$(nrm "$CONFIG_EMPTY")"; export AGENTS_CONFIG_DIR

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- expected [$2] got [$3]"; fi; }
check_contains() {
  case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 -- expected [$2] in: $3" ;; esac
}
check_not_contains() {
  case "$3" in *"$2"*) fail "$1 -- did NOT expect [$2] in: $3" ;; *) pass "$1" ;; esac
}
# Separator-insensitive containment: the diagnostic is emitted after toWindowsPath,
# so the same directory reaches stderr with backslashes on Windows.
check_contains_path() {
  local hay need
  hay="$(printf '%s' "$3" | tr '\\A-Z' '/a-z')"; need="$(printf '%s' "$2" | tr '\\A-Z' '/a-z')"
  # `case` rather than a grep pipeline: under `pipefail` a -q grep that exits on the
  # first match SIGPIPEs the writer, and a multi-line haystack would read as a miss.
  case "$hay" in
    *"$need"*) pass "$1" ;;
    *) fail "$1 -- expected [$need] in: $hay" ;;
  esac
}
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
  else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}
# A refused advance must be silent on stdout, not merely nonzero: a caller that reads
# ACTION= / NEXT_SKILL= would otherwise act on a next step the transaction never took.
# The exit code alone cannot catch a build that prints the block and THEN fails.
ADVANCE_TOKENS="ADVANCED ADVANCE_SCOPE ACTION NEXT_SKILL NEXT_HINT"
check_no_advance_tokens() {
  local id="$1" text="$2" t
  for t in $ADVANCE_TOKENS; do
    check_not_contains "$id: stdout carries no $t token" "$t" "$text"
  done
}
# check_no_advance_tokens only reads stdout: a build that mutates an unrelated state
# field, or appends a spurious event, on a rejected advance would pass it undetected.
# snapshot_state/check_state_untouched pin the state file byte-for-byte (sha256, falling
# back to a node-computed digest where neither sha256sum nor shasum is on PATH) plus the
# events array length -- the same array shape provenance.sh's ev_field/last_event read --
# around every rejected `--advance` call.
sha256_of() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$f" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
  else
    run_with_timeout node -e '
      const fs = require("fs"), crypto = require("crypto");
      process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));
    ' "$f" 2>/dev/null
  fi
}
event_count_of() {
  local f="$1"
  run_with_timeout node -e '
    const fs = require("fs");
    let raw;
    try { raw = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
    catch (e) { process.stdout.write("READ_FAIL"); return; }
    process.stdout.write(String((raw.events || []).length));
  ' "$f" 2>/dev/null || echo "PROBE_FAIL"
}
STATE_FILE_FOR() { printf '%s/%s.json' "$WORKFLOW_DIR" "$1"; }
snapshot_state() {
  local sid="$1" f
  f="$(STATE_FILE_FOR "$sid")"
  SNAP_SID="$sid"; SNAP_HASH="$(sha256_of "$f")"; SNAP_EVCOUNT="$(event_count_of "$f")"
}
check_state_untouched() {
  local id="$1" f
  f="$(STATE_FILE_FOR "$SNAP_SID")"
  check "$id: state file is byte-for-byte unchanged" "$SNAP_HASH" "$(sha256_of "$f")"
  check "$id: event count is unchanged" "$SNAP_EVCOUNT" "$(event_count_of "$f")"
}

# Fixtures: (a) MAIN, a repo with NO staged tests/ change; (b) LINKED, a linked
# worktree of (a) whose own index HAS one; (c) NOGIT, outside any repository.
MAIN="$TMPDIR_BASE/main"
LINKED="$TMPDIR_BASE/linked"
NOGIT="$TMPDIR_BASE/nogit"; mkdir -p "$NOGIT"
git init -q "$MAIN" >/dev/null 2>&1
git -C "$MAIN" config core.hooksPath /dev/null
git -C "$MAIN" config user.email "t@example.com"
git -C "$MAIN" config user.name "t"
printf 'seed\n' > "$MAIN/README.md"
git -C "$MAIN" add README.md >/dev/null 2>&1
git -C "$MAIN" commit -qm seed >/dev/null 2>&1
git -C "$MAIN" worktree add -q -b wt2102 "$LINKED" >/dev/null 2>&1
git -C "$LINKED" config core.hooksPath /dev/null
mkdir -p "$LINKED/tests"
printf '# fixture test\n' > "$LINKED/tests/fixture-2102.sh"
git -C "$LINKED" add tests/ >/dev/null 2>&1

MAIN_N="$(nrm "$MAIN")"; LINKED_N="$(nrm "$LINKED")"; NOGIT_N="$(nrm "$NOGIT")"

# Preconditions -- without these the verdicts below would be vacuous.
if [ -e "$LINKED/.git" ]; then
  pass "F0a: the linked worktree fixture exists"
else
  fail "F0a: git worktree add did not produce $LINKED"
fi
check "F0b: the linked worktree has tests/ staged" "tests/fixture-2102.sh" \
  "$(git -C "$LINKED" diff --cached --name-only | tr -d '\r')"
check "F0c: the main worktree has NOTHING staged" "" \
  "$(git -C "$MAIN" diff --cached --name-only | tr -d '\r')"
if (cd "$NOGIT" && git rev-parse --show-toplevel >/dev/null 2>&1); then
  fail "F0d: the no-git fixture $NOGIT is inside a repository -- cell (c) is vacuous"
else
  pass "F0d: the no-git fixture is outside any repository"
fi

STEPS_ALL="workflow_init clarify_intent research outline detail branching_complete write_tests review_tests write_code run_tests review_security docs user_verification cleanup pre_final_report_gate final_report"
DONE_BEFORE=" workflow_init clarify_intent research outline detail branching_complete "
at_write_tests() {
  local sid="$1" json='{"steps":{' first=1 s st
  for s in $STEPS_ALL; do
    st="pending"; case "$DONE_BEFORE" in *" $s "*) st="complete" ;; esac
    [ $first -eq 1 ] || json="$json,"; first=0
    json="$json\"$s\":{\"status\":\"$st\"}"
  done
  printf '%s' "$json},\"closes_issues\":[2102]}" > "$WORKFLOW_DIR/${sid}.json"
}
step_status() {
  PROBE_SID="$1" PROBE_STEP="$2" PROBE_FIELD=status \
    run_with_timeout node "$PROBE" field 2>/dev/null || echo "PROBE_FAIL"
}

ERRF="$TMPDIR_BASE/err.txt"
OUT=""; ERR=""; RC=0
# The CLI door. `dir` is the node process CWD -- the only input resolveTrustedRepoDir
# consults, and exactly what a `cd <main> &&` prefix would change.
run_cli_at() {
  local dir="$1" sid="$2"
  RC=0
  OUT="$(cd "$dir" && run_with_timeout node "$NS" --session "$sid" \
    --advance --step write_tests --complete --next 2>"$ERRF")" || RC=$?
  ERR="$(cat "$ERRF" 2>/dev/null || echo "")"
}
# The sentinel door. Process CWD is NEUTRAL for every cell: the door reads
# input.cwd, so its verdict must not depend on where the hook itself runs.
mk_payload() {
  SID="$1" ICWD="$2" node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"echo \"<<WORKFLOW_MARK_STEP_write_tests_complete>>\""},tool_response:{exit_code:0},session_id:process.env.SID,cwd:process.env.ICWD}))'
}
# No `cwd` field at all -- the shape path-normalize.js's header states production
# PostToolUse stdin does not always carry (priority-0 cannot fire without it).
mk_payload_no_cwd() {
  SID="$1" node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"echo \"<<WORKFLOW_MARK_STEP_write_tests_complete>>\""},tool_response:{exit_code:0},session_id:process.env.SID}))'
}
run_sentinel_with() {
  local sid="$1" icwd="$2"
  mk_payload "$sid" "$icwd" > "$TMPDIR_BASE/payload.json"
  RC=0
  OUT="$(cd "$NEUTRAL" && run_with_timeout node "$MARK_HOOK" < "$TMPDIR_BASE/payload.json" 2>"$ERRF")" || RC=$?
  ERR="$(cat "$ERRF" 2>/dev/null || echo "")"
}
run_sentinel_no_cwd() {
  local sid="$1"
  mk_payload_no_cwd "$sid" > "$TMPDIR_BASE/payload.json"
  RC=0
  OUT="$(cd "$NEUTRAL" && run_with_timeout node "$MARK_HOOK" < "$TMPDIR_BASE/payload.json" 2>"$ERRF")" || RC=$?
  ERR="$(cat "$ERRF" 2>/dev/null || echo "")"
}

REJECT_CLI="record-step-verdict: write_tests cannot be completed without test evidence"
REJECT_SENTINEL="workflow-mark: write_tests NOT recorded"

echo "=== E1: the CLI door, CLAUDE_PROJECT_DIR pinned to the STAGED side ==="
# The env var points at the linked worktree in every cell, so a cell that completed
# from an unstaged CWD would prove CLAUDE_PROJECT_DIR is still trusted (H2 reopened).
export CLAUDE_PROJECT_DIR="$LINKED_N"
at_write_tests e1a
run_cli_at "$LINKED" e1a
check "E1a: CWD=linked (staged) exits 0" 0 "$RC"
check "E1a: write_tests is complete" '"complete"' "$(step_status e1a write_tests)"
check_contains "E1a: the advance line is reported" "ADVANCED=write_tests status=complete" "$OUT"
# Non-vacuity for the E1b/E1c/E2b/E2c absence assertions: on the accepted path the very
# same tokens DO appear, so their absence below is a property of the refusal.
check_contains "E1a: control -- the accepted path does emit ACTION=" "ACTION=" "$OUT"
check_contains "E1a: control -- the accepted path does emit ADVANCE_SCOPE=" "ADVANCE_SCOPE=" "$OUT"

at_write_tests e1b
snapshot_state e1b
run_cli_at "$MAIN" e1b
check "E1b: CWD=main (unstaged) exits 2" 2 "$RC"
check_contains "E1b: it names the missing evidence" "$REJECT_CLI" "$ERR"
check "E1b: write_tests stays pending" '"pending"' "$(step_status e1b write_tests)"
check_no_advance_tokens "E1b" "$OUT"
check_state_untouched "E1b"

at_write_tests e1c
snapshot_state e1c
run_cli_at "$NOGIT" e1c
check "E1c: CWD outside any repo exits 2" 2 "$RC"
check_contains "E1c: it names the missing evidence" "$REJECT_CLI" "$ERR"
check "E1c: write_tests stays pending" '"pending"' "$(step_status e1c write_tests)"
check_no_advance_tokens "E1c" "$OUT"
check_state_untouched "E1c"

echo ""
echo "=== E2: the same three cells with CLAUDE_PROJECT_DIR on the UNSTAGED side ==="
# Symmetric counterpart of E1: the env var must not be able to BREAK a legitimate
# completion either. Identical verdicts across E1/E2 is the H2 pin.
export CLAUDE_PROJECT_DIR="$MAIN_N"
at_write_tests e2a
run_cli_at "$LINKED" e2a
check "E2a: CWD=linked still exits 0" 0 "$RC"
check "E2a: write_tests is complete" '"complete"' "$(step_status e2a write_tests)"

at_write_tests e2b
snapshot_state e2b
run_cli_at "$MAIN" e2b
check "E2b: CWD=main still exits 2" 2 "$RC"
check "E2b: write_tests stays pending" '"pending"' "$(step_status e2b write_tests)"
check_no_advance_tokens "E2b" "$OUT"
check_state_untouched "E2b"

at_write_tests e2c
snapshot_state e2c
run_cli_at "$NOGIT" e2c
check "E2c: CWD outside any repo still exits 2" 2 "$RC"
check "E2c: write_tests stays pending" '"pending"' "$(step_status e2c write_tests)"
check_no_advance_tokens "E2c" "$OUT"
check_state_untouched "E2c"

echo ""
echo "=== E3: the sentinel door over the same three directories ==="
# CLAUDE_PROJECT_DIR stays on the unstaged side so resolveRepoCwd's priority-0 branch
# (input.cwd differs from the project dir) is the arm actually exercised.
at_write_tests e3a
run_sentinel_with e3a "$LINKED_N"
check "E3a: input.cwd=linked exits 0" 0 "$RC"
check "E3a: write_tests is complete (the accepted contrast case)" '"complete"' "$(step_status e3a write_tests)"
check_not_contains "E3a: no rejection message" "$REJECT_SENTINEL" "$OUT"
check_not_contains "E3a: no staged-evidence diagnostic on the success path" "(cwd=" "$ERR"

at_write_tests e3b
run_sentinel_with e3b "$MAIN_N"
check "E3b: input.cwd=main exits 0 (the hook never fails the tool call)" 0 "$RC"
check_contains "E3b: it rejects with the MARK_STEP guidance" "$REJECT_SENTINEL" "$OUT"
check "E3b: write_tests stays pending" '"pending"' "$(step_status e3b write_tests)"

at_write_tests e3c
run_sentinel_with e3c "$NOGIT_N"
check "E3c: input.cwd outside any repo exits 0" 0 "$RC"
check_contains "E3c: it rejects with the MARK_STEP guidance" "$REJECT_SENTINEL" "$OUT"
check "E3c: write_tests stays pending" '"pending"' "$(step_status e3c write_tests)"
# hasStagedTestChanges prints `(cwd=<dir>)` only on the git-failure path, so this is
# the one cell where the diagnostic names the directory the door actually resolved.
check_contains "E3c: the staged-evidence failure names the resolved cwd" "(cwd=" "$ERR"
check_contains_path "E3c: the named cwd is the payload's, not the process's" "$NOGIT_N" "$ERR"

echo ""
echo "=== E3d/E3e: the two env configurations E1/E2 exercise for the CLI door, mirrored for the sentinel door ==="
# CLAUDE_PROJECT_DIR flips to the STAGED side for these two cells -- the mirror of
# E1 (env=staged) for a door that priority-0 in resolveRepoCwd can bypass.
export CLAUDE_PROJECT_DIR="$LINKED_N"

# E3d: no `cwd` field at all. Priority 0 cannot fire (it requires input.cwd), so
# resolution falls through to priority 2 (CLAUDE_PROJECT_DIR) -- the door completes
# from a repo the payload itself never named. Pinned as observed behaviour, not
# endorsed: this is exactly the trust boundary the CLI door's resolveTrustedRepoDir()
# was hardened against (H2), and the sentinel door has no equivalent hardening.
at_write_tests e3d
run_sentinel_no_cwd e3d
check "E3d: no cwd field, CLAUDE_PROJECT_DIR=staged exits 0" 0 "$RC"
check "E3d: write_tests completes from CLAUDE_PROJECT_DIR alone (pinned gap)" \
  '"complete"' "$(step_status e3d write_tests)"

# E3e: input.cwd=unstaged, CLAUDE_PROJECT_DIR=staged -- the symmetric counterpart of
# E1-vs-E2. Priority 0 fires (input.cwd differs from CLAUDE_PROJECT_DIR) and returns
# input.cwd, so the door must still refuse on the unstaged directory.
at_write_tests e3e
run_sentinel_with e3e "$MAIN_N"
check "E3e: input.cwd=unstaged, CLAUDE_PROJECT_DIR=staged exits 0 (hook never fails the tool call)" 0 "$RC"
check_contains "E3e: it still rejects -- priority 0 picks input.cwd, not the env var" "$REJECT_SENTINEL" "$OUT"
check "E3e: write_tests stays pending" '"pending"' "$(step_status e3e write_tests)"

export CLAUDE_PROJECT_DIR="$MAIN_N"

echo ""
echo "=== E4: the doors agree on every directory ==="
# The migration's precondition: after #2102 the CLI door replaces the sentinel door
# for write_tests, so a directory where the two verdicts differ is a behaviour change.
check "E4a: staged side -- both doors complete" "$(step_status e2a write_tests)" "$(step_status e3a write_tests)"
check "E4b: unstaged side -- both doors refuse" "$(step_status e2b write_tests)" "$(step_status e3b write_tests)"
check "E4c: outside any repo -- both doors refuse" "$(step_status e2c write_tests)" "$(step_status e3c write_tests)"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
