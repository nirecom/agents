#!/usr/bin/env bash
# tests/bin/feature-plan-link-cli.sh
# Tests: bin/plan-link
# Tags: plan-link, plan-sync, blob-url, cli, TL2, scope:common, path-leak, read-only
# bin/plan-link [--session <sid>] [--stage intent|outline|detail]: prints one line per
# stage, "<stage>: <url>" or "<stage>: (unavailable: <reason>)" on stdout; exit 0 ok, 1 unknown
# session, 2 usage error (messages on stderr). Never prints a local path; never changes any file.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
# shellcheck source=../lib/plan-sync-fixture.sh
. "$AGENTS_DIR/tests/lib/plan-sync-fixture.sh"

psf_setup || { fail "setup" "psf_setup failed"; exit 1; }
trap psf_cleanup EXIT
CLI="$(psf_np "$AGENTS_DIR/bin/plan-link")"
PLC_SID="0d2c5d7e-1111-4222-8333-444455556666"
PLC_OTHER="9a8b7c6d-2222-4333-8444-555566667777"
PLC_BLOB="https://github.com/test-owner/test-repo/blob/main"
PLANS="$WORKFLOW_PLANS_DIR"

# Fixture: provisioned plans dir on a GitHub origin; intent published, outline local-only,
# detail absent.
PLC_FIX="ok"
psf_make_provisioned "$PLANS" "$PSF_ORIGIN_E2E" >/dev/null 2>&1 || PLC_FIX="provision"
printf 'intent body\n' > "$PLANS/$PLC_SID-intent.md"
psf_commit_file "$PLANS" "$PLC_SID-intent.md" refs/remotes/origin/main >/dev/null 2>&1 || PLC_FIX="commit"
printf 'outline body\n' > "$PLANS/$PLC_SID-outline.md"
export PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_E2E"
if [ "$PLC_FIX" = ok ]; then pass "fixture built"; else fail "fixture built" "step=$PLC_FIX"; fi

# plc_run [VAR=val...] -- [cli args...] — sets PLC_OUT (stdout), PLC_ERR (stderr) and PLC_RC.
PLC_ERRF="$PSF_ROOT/plc-stderr"
plc_run() {
  local -a envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  if [ ! -f "$CLI" ]; then PLC_OUT="not implemented: bin/plan-link absent"; PLC_ERR=""; PLC_RC=127; return; fi
  PLC_OUT="$(env "${envs[@]+"${envs[@]}"}" bash "$RWT" 60 node "$CLI" "$@" 2>"$PLC_ERRF")"
  PLC_RC=$?
  PLC_ERR="$(cat "$PLC_ERRF")"
}

# plc_streams <name> <ok|err> — ok: result on stdout, stderr empty; err: message on stderr, stdout empty.
plc_streams() {
  if [ "$PLC_RC" -eq 127 ]; then fail "$1" "nothing ran: $PLC_OUT"; return; fi
  if [ "$2" = ok ]; then
    if [ -n "$PLC_OUT" ] && [ -z "$PLC_ERR" ]; then pass "$1"; else fail "$1" "stdout=[$PLC_OUT] stderr=[$PLC_ERR]"; fi
  else
    if [ -z "$PLC_OUT" ] && [ -n "$PLC_ERR" ]; then pass "$1"; else fail "$1" "stdout=[$PLC_OUT] stderr=[$PLC_ERR]"; fi
  fi
}

# plc_no_leak <name> — neither stream names the plans dir or ~/.workflow-plans.
plc_no_leak() {
  local leak
  if [ "$PLC_RC" -eq 127 ]; then fail "$1 — no local path" "nothing ran: $PLC_OUT"; return; fi
  leak="$(psf_path_leak "$PLC_OUT"$'\n'"$PLC_ERR" "$PLANS")"
  if [ -z "$leak" ]; then pass "$1 — no local path"; else fail "$1 — no local path" "leaked '$leak': $PLC_OUT"; fi
}

plc_expect_line() {
  local name="$1" want="$2"
  if printf '%s\n' "$PLC_OUT" | grep -qxF -- "$want"; then pass "$name"; else fail "$name" "missing line '$want' in: $PLC_OUT"; fi
}

# plc_snapshot — working-tree files + contents (outside .git) and every ref of the plans dir.
plc_snapshot() {
  PLANS_SNAP="$PLANS" bash "$RWT" 30 node -e "
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const root = process.env.PLANS_SNAP, out = [];
const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
  if (e.name === '.git' && d === root) continue;
  const p = path.join(d, e.name);
  if (e.isDirectory()) walk(p); else out.push(path.relative(root, p) + ' ' + crypto.createHash('sha1').update(fs.readFileSync(p)).digest('hex'));
} };
walk(root); process.stdout.write(out.join('\n'));"
  echo
  git -C "$PLANS" for-each-ref --format='%(refname) %(objectname)'
}

case_begin "all-stages-default" "bin/plan-link"
SNAP_BEFORE="$(plc_snapshot)"
plc_run -- --session "$PLC_SID"
if [ "$PLC_RC" -eq 0 ]; then pass "known session exits 0"; else fail "known session exits 0" "rc=$PLC_RC out=$PLC_OUT"; fi
plc_expect_line "intent line is the blob URL" "intent: $PLC_BLOB/$PLC_SID-intent.md"
plc_expect_line "outline line is unavailable: not-published" "outline: (unavailable: not-published)"
plc_expect_line "detail line is unavailable: no-artifact" "detail: (unavailable: no-artifact)"
PLC_LINES="$(printf '%s\n' "$PLC_OUT" | grep -cE '^(intent|outline|detail): ')"
if [ "$PLC_LINES" -eq 3 ]; then pass "exactly one line per stage"; else fail "exactly one line per stage" "count=$PLC_LINES out=$PLC_OUT"; fi
plc_streams "all stages: result lines on stdout, stderr empty" ok
plc_no_leak "all stages"
SNAP_AFTER="$(plc_snapshot)"
if [ "$PLC_RC" -ne 127 ] && [ -n "$SNAP_BEFORE" ] && [ "$SNAP_BEFORE" = "$SNAP_AFTER" ]; then pass "read-only: plans dir unchanged"; else fail "read-only: plans dir unchanged" "before=[$SNAP_BEFORE] after=[$SNAP_AFTER]"; fi
case_end

case_begin "single-stage" "bin/plan-link"
plc_run -- --session "$PLC_SID" --stage intent
if [ "$PLC_RC" -eq 0 ] && [ "$PLC_OUT" = "intent: $PLC_BLOB/$PLC_SID-intent.md" ]; then
  pass "--stage intent prints only the intent line"
else
  fail "--stage intent prints only the intent line" "rc=$PLC_RC out=$PLC_OUT"
fi
plc_run -- --session "$PLC_SID" --stage outline
if [ "$PLC_RC" -eq 0 ] && [ "$PLC_OUT" = "outline: (unavailable: not-published)" ]; then
  pass "--stage outline prints only the unavailable line"
else
  fail "--stage outline prints only the unavailable line" "rc=$PLC_RC out=$PLC_OUT"
fi
plc_streams "single stage: result on stdout, stderr empty" ok
plc_no_leak "single stage"
case_end

case_begin "session-from-env" "bin/plan-link"
plc_run "CLAUDE_CODE_SESSION_ID=$PLC_SID" -- --stage intent
if [ "$PLC_RC" -eq 0 ] && [ "$PLC_OUT" = "intent: $PLC_BLOB/$PLC_SID-intent.md" ]; then
  pass "session defaults to CLAUDE_CODE_SESSION_ID"
else
  fail "session defaults to CLAUDE_CODE_SESSION_ID" "rc=$PLC_RC out=$PLC_OUT"
fi
plc_run "CLAUDE_CODE_SESSION_ID=$PLC_OTHER" -- --session "$PLC_SID" --stage intent
if [ "$PLC_RC" -eq 0 ] && [ "$PLC_OUT" = "intent: $PLC_BLOB/$PLC_SID-intent.md" ]; then
  pass "--session overrides CLAUDE_CODE_SESSION_ID"
else
  fail "--session overrides CLAUDE_CODE_SESSION_ID" "rc=$PLC_RC out=$PLC_OUT"
fi
case_end

case_begin "sync-off-reason" "bin/plan-link"
plc_run "PLAN_SYNC_REMOTE_URL=" -- --session "$PLC_SID" --stage intent
if [ "$PLC_RC" -eq 0 ] && [ "$PLC_OUT" = "intent: (unavailable: plan-sync-off)" ]; then
  pass "plan-sync off -> unavailable: plan-sync-off"
else
  fail "plan-sync off -> unavailable: plan-sync-off" "rc=$PLC_RC out=$PLC_OUT"
fi
plc_no_leak "sync off"
case_end

case_begin "unknown-session" "bin/plan-link"
for bad in "../escape" "not-a-session"; do
  plc_run -- --session "$bad"
  if [ "$PLC_RC" -eq 1 ]; then pass "session '$bad' exits 1"; else fail "session '$bad' exits 1" "rc=$PLC_RC out=$PLC_OUT"; fi
  plc_streams "session '$bad': error on stderr, stdout empty" err
  plc_no_leak "session '$bad'"
done
plc_run "CLAUDE_CODE_SESSION_ID=" --
if [ "$PLC_RC" -eq 1 ]; then pass "no session at all exits 1"; else fail "no session at all exits 1" "rc=$PLC_RC out=$PLC_OUT"; fi
plc_streams "no session: error on stderr, stdout empty" err
case_end

case_begin "valid-session-zero-artifacts" "bin/plan-link"
# PLC_OTHER is a well-formed session id with no plan file at all: not an error (exit 0).
plc_run -- --session "$PLC_OTHER"
if [ "$PLC_RC" -eq 0 ]; then pass "zero artifacts exits 0"; else fail "zero artifacts exits 0" "rc=$PLC_RC out=$PLC_OUT"; fi
for st in intent outline detail; do
  plc_expect_line "zero artifacts: $st unavailable: no-artifact" "$st: (unavailable: no-artifact)"
done
plc_streams "zero artifacts: result lines on stdout, stderr empty" ok
plc_no_leak "zero artifacts"
case_end

case_begin "executable-bit" "bin/plan-link"
# Index mode, not the working-tree bit (Windows checkouts do not carry +x); RED until
# bin/plan-link is written and staged as 100755.
PLC_MODE="$(git -C "$AGENTS_DIR" ls-files -s -- bin/plan-link)"
case "$PLC_MODE" in
  100755\ *) pass "bin/plan-link is tracked with mode 100755" ;;
  *) fail "bin/plan-link is tracked with mode 100755" "ls-files: '${PLC_MODE:-<untracked>}'" ;;
esac
case_end

case_begin "usage-errors" "bin/plan-link"
for args in "--stage bogus" "--bogus" "--session" "--stage"; do
  # shellcheck disable=SC2086  # word-split the literal arg list on purpose
  plc_run -- --session "$PLC_SID" $args
  if [ "$PLC_RC" -eq 2 ]; then pass "usage '$args' exits 2"; else fail "usage '$args' exits 2" "rc=$PLC_RC out=$PLC_OUT"; fi
  plc_streams "usage '$args': error on stderr, stdout empty" err
  plc_no_leak "usage '$args'"
done
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
