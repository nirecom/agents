#!/usr/bin/env bash
# tests/bin/feature-plan-link-cli.sh
# Tests: bin/plan-link
# Tags: plan-link, plan-sync, blob-url, cli, TL2, scope:common, path-leak, read-only, project-host, gitlab
# bin/plan-link [--session <sid>] [--stage intent|outline|detail]: prints one line per stage on
# stdout. An existing plan's line carries its local path, with the blob URL when one may be
# shown or a reason word otherwise; an absent plan is "<stage>: (unavailable: <reason>)".
# Exit 0 resolved, 1 no plan file, 2 usage error (messages on stderr). Never changes any file.
set -uo pipefail

# TL3 gap (what this test does NOT catch):
# - the model copying the printed line into its reply (instruction level only)
# - a blob URL actually opening on a phone (the destination is never contacted here)
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=../lib/plan-sync-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/plan-sync-fixture.sh"

psf_setup || { fail "setup" "psf_setup failed"; exit 1; }
trap psf_cleanup EXIT
CLI="$(psf_np "$SCRIPT_CHECKOUT_ROOT/bin/plan-link")"
PLC_SID="0d2c5d7e-1111-4222-8333-444455556666"
PLC_OTHER="9a8b7c6d-2222-4333-8444-555566667777"
PLC_MIS="1e3d6e8f-2222-4333-8444-555566667777"
PLC_NOREC="2f4e7f90-3333-4444-8555-666677778888"
PLC_BLOB="https://github.com/test-owner/test-repo/blob/main"
PLC_BLOB_GL="https://gitlab.com/test-group/test-project/-/blob/main"
PLC_BLOB_GLS="https://gitlab.example.com/test-group/test-project/-/blob/main"
PLC_ORIGIN_SSHGH="ssh://git@ssh.github.com:443/test-owner/test-repo.git"
PLANS="$WORKFLOW_PLANS_DIR"
PLC_GL="$(psf_np "$PSF_ROOT/gl-plans")"; PLC_GLS="$(psf_np "$PSF_ROOT/gls-plans")"
PLC_SG="$(psf_np "$PSF_ROOT/sg-plans")"; PLC_NG="$(psf_np "$PSF_ROOT/ng-plans")"; PLC_RAW="$(psf_np "$PSF_ROOT/raw-plans")"

# plc_publish <plansDir> <rel> <content> — on disk, on main and on origin/main.
plc_publish() {
  printf '%s\n' "$3" > "$1/$2" || return 1
  psf_commit_file "$1" "$2" refs/remotes/origin/main >/dev/null 2>&1
}

# plc_one_published <plansDir> <origin> <record-host> — provisioned dir holding a published intent.
plc_one_published() {
  psf_make_provisioned "$1" "$2" >/dev/null 2>&1 || return 1
  plc_publish "$1" "$PLC_SID-intent.md" "intent for ${1##*/}" || return 1
  psf_record "$1" "$PLC_SID-intent.md" "$3"
}

# Fixture, $PLANS on a github.com destination ("published" = identical on origin/main):
#   PLC_SID   (match record): intent published, outline published then edited, detail absent.
#   PLC_MIS   intent published + other-host record, outline local-only + other-host record,
#             detail published + no-host record.
#   PLC_NOREC (no record): intent published, outline local-only.
PLC_FIX="ok"
psf_make_provisioned "$PLANS" "$PSF_ORIGIN_E2E" >/dev/null 2>&1 || PLC_FIX="provision"
plc_publish "$PLANS" "$PLC_SID-intent.md" "intent body" || PLC_FIX="intent"
plc_publish "$PLANS" "$PLC_SID-outline.md" "published outline" || PLC_FIX="outline"
printf 'outline edited after publishing\n' > "$PLANS/$PLC_SID-outline.md"
plc_publish "$PLANS" "$PLC_MIS-intent.md" "mismatch intent" || PLC_FIX="mis-intent"
printf 'mismatch outline\n' > "$PLANS/$PLC_MIS-outline.md"
plc_publish "$PLANS" "$PLC_MIS-detail.md" "no-host detail" || PLC_FIX="mis-detail"
plc_publish "$PLANS" "$PLC_NOREC-intent.md" "norec intent" || PLC_FIX="norec-intent"
printf 'norec outline\n' > "$PLANS/$PLC_NOREC-outline.md"
psf_record "$PLANS" "$PLC_SID-intent.md" github.com
psf_record "$PLANS" "$PLC_SID-outline.md" github.com
psf_record "$PLANS" "$PLC_MIS-intent.md" gitlab.com
psf_record "$PLANS" "$PLC_MIS-outline.md" gitlab.com
psf_record "$PLANS" "$PLC_MIS-detail.md" none
plc_one_published "$PLC_GL" "$PSF_ORIGIN_GL" gitlab.com || PLC_FIX="gl"
plc_one_published "$PLC_GLS" "$PSF_ORIGIN_GL_SELF" gitlab.example.com || PLC_FIX="gls"
plc_one_published "$PLC_SG" "$PLC_ORIGIN_SSHGH" github.com || PLC_FIX="sg"
plc_one_published "$PLC_NG" "$PSF_ORIGIN_PLAIN" "$PSF_HOST_PLAIN" || PLC_FIX="ng"
mkdir -p "$PLC_RAW"; printf 'raw\n' > "$PLC_RAW/$PLC_SID-intent.md"
psf_record "$PLC_RAW" "$PLC_SID-intent.md" github.com
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

# plc_no_leak <name> — neither stream names the plans dir (error paths carry no plan file).
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

# plc_stage_line <stage> — the stdout line of <stage> (empty when there is none).
plc_stage_line() { printf '%s\n' "$PLC_OUT" | grep -E "^$1: " | head -n 1; }

# plc_line_has_path <line> <plansDir> <file> — the plan's absolute path, native or forward-slash.
plc_line_has_path() {
  local fwd="$2/$3" native
  native="${fwd//\//\\}"
  case "$1" in *"$fwd"*|*"$native"*) return 0 ;; esac
  return 1
}

# plc_expect_url <name> <stage> <url> <plansDir> <sid> — rc 0, the stage line holds the URL and the path.
plc_expect_url() {
  local line
  line="$(plc_stage_line "$2")"
  if [ "$PLC_RC" -eq 0 ] && [[ "$line" == *"$3"* ]]; then pass "$1 -> blob URL"; else fail "$1 -> blob URL" "rc=$PLC_RC want=$3 out=$PLC_OUT"; fi
  if plc_line_has_path "$line" "$4" "$5-$2.md"; then pass "$1 -> local path on the line"; else fail "$1 -> local path on the line" "out=$PLC_OUT"; fi
}

# plc_expect_reason <name> <stage> <reason> <plansDir> <sid> — rc 0, the stage line holds the path
# and the reason word, and no URL.
plc_expect_reason() {
  local line
  line="$(plc_stage_line "$2")"
  if [ "$PLC_RC" -eq 0 ] && [[ "$line" == *"$3"* ]] && [[ "$line" != *"://"* ]]; then pass "$1 -> $3, no URL"; else fail "$1 -> $3, no URL" "rc=$PLC_RC out=$PLC_OUT"; fi
  if plc_line_has_path "$line" "$4" "$5-$2.md"; then pass "$1 -> local path on the line"; else fail "$1 -> local path on the line" "out=$PLC_OUT"; fi
}

plc_one_line() {
  local n
  n="$(printf '%s\n' "$PLC_OUT" | grep -c .)"
  if [ "$PLC_RC" -eq 0 ] && [ "$n" -eq 1 ]; then pass "$1"; else fail "$1" "rc=$PLC_RC lines=$n out=$PLC_OUT"; fi
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
plc_expect_url "match record, published identical" intent "$PLC_BLOB/$PLC_SID-intent.md" "$PLANS" "$PLC_SID"
plc_expect_reason "match record, content differs from the destination" outline not-published "$PLANS" "$PLC_SID"
plc_expect_line "detail line is unavailable: no-artifact" "detail: (unavailable: no-artifact)"
PLC_LINES="$(printf '%s\n' "$PLC_OUT" | grep -cE '^(intent|outline|detail): ')"
if [ "$PLC_LINES" -eq 3 ]; then pass "exactly one line per stage"; else fail "exactly one line per stage" "count=$PLC_LINES out=$PLC_OUT"; fi
plc_streams "all stages: result lines on stdout, stderr empty" ok
SNAP_AFTER="$(plc_snapshot)"
if [ "$PLC_RC" -ne 127 ] && [ -n "$SNAP_BEFORE" ] && [ "$SNAP_BEFORE" = "$SNAP_AFTER" ]; then pass "read-only: plans dir unchanged"; else fail "read-only: plans dir unchanged" "before=[$SNAP_BEFORE] after=[$SNAP_AFTER]"; fi
case_end

case_begin "single-stage" "bin/plan-link"
plc_run -- --session "$PLC_SID" --stage intent
plc_one_line "--stage intent prints one line"
plc_expect_url "--stage intent" intent "$PLC_BLOB/$PLC_SID-intent.md" "$PLANS" "$PLC_SID"
plc_run -- --session "$PLC_SID" --stage outline
plc_one_line "--stage outline prints one line"
plc_expect_reason "--stage outline" outline not-published "$PLANS" "$PLC_SID"
plc_streams "single stage: result on stdout, stderr empty" ok
case_end

case_begin "session-from-env" "bin/plan-link"
plc_run "CLAUDE_CODE_SESSION_ID=$PLC_SID" -- --stage intent
plc_one_line "session from CLAUDE_CODE_SESSION_ID prints one line"
plc_expect_url "session defaults to CLAUDE_CODE_SESSION_ID" intent "$PLC_BLOB/$PLC_SID-intent.md" "$PLANS" "$PLC_SID"
plc_run "CLAUDE_CODE_SESSION_ID=$PLC_OTHER" -- --session "$PLC_SID" --stage intent
plc_expect_url "--session overrides CLAUDE_CODE_SESSION_ID" intent "$PLC_BLOB/$PLC_SID-intent.md" "$PLANS" "$PLC_SID"
case_end

case_begin "mismatch-record" "bin/plan-link"
plc_run -- --session "$PLC_MIS"
plc_expect_reason "other-host record, plan identical at the destination" intent host-mismatch "$PLANS" "$PLC_MIS"
plc_expect_reason "other-host record, plan absent at the destination" outline host-mismatch "$PLANS" "$PLC_MIS"
plc_expect_reason "no-host record, plan identical at the destination" detail no-project-host "$PLANS" "$PLC_MIS"
case_end

case_begin "no-record" "bin/plan-link"
plc_run -- --session "$PLC_NOREC"
plc_expect_url "no record, plan identical at the destination" intent "$PLC_BLOB/$PLC_NOREC-intent.md" "$PLANS" "$PLC_NOREC"
plc_expect_reason "no record, plan absent at the destination" outline not-published "$PLANS" "$PLC_NOREC"
case_end

case_begin "sync-off-reason" "bin/plan-link"
plc_run "PLAN_SYNC_REMOTE_URL=" -- --session "$PLC_SID" --stage intent
plc_one_line "plan-sync off prints one line"
plc_expect_reason "plan-sync off" intent plan-sync-off "$PLANS" "$PLC_SID"
case_end

case_begin "not-provisioned-reason" "bin/plan-link"
plc_run "WORKFLOW_PLANS_DIR=$PLC_RAW" -- --session "$PLC_SID" --stage intent
plc_expect_reason "unprovisioned plans dir" intent not-provisioned "$PLC_RAW" "$PLC_SID"
case_end

case_begin "forge-url-shapes" "bin/plan-link"
plc_run "WORKFLOW_PLANS_DIR=$PLC_GL" "PLAN_SYNC_REMOTE_URL=$PSF_ORIGIN_GL" -- --session "$PLC_SID" --stage intent
plc_expect_url "gitlab.com destination" intent "$PLC_BLOB_GL/$PLC_SID-intent.md" "$PLC_GL" "$PLC_SID"
plc_run "WORKFLOW_PLANS_DIR=$PLC_GLS" "PLAN_SYNC_REMOTE_URL=$PSF_ORIGIN_GL_SELF" "GITLAB_HOSTNAME=gitlab.example.com" -- --session "$PLC_SID" --stage intent
plc_expect_url "self-hosted GitLab destination" intent "$PLC_BLOB_GLS/$PLC_SID-intent.md" "$PLC_GLS" "$PLC_SID"
plc_run "WORKFLOW_PLANS_DIR=$PLC_SG" "PLAN_SYNC_REMOTE_URL=$PLC_ORIGIN_SSHGH" -- --session "$PLC_SID" --stage intent
plc_expect_url "ssh.github.com destination" intent "$PLC_BLOB/$PLC_SID-intent.md" "$PLC_SG" "$PLC_SID"
plc_run "WORKFLOW_PLANS_DIR=$PLC_NG" "PLAN_SYNC_REMOTE_URL=$PSF_ORIGIN_PLAIN" -- --session "$PLC_SID" --stage intent
plc_expect_reason "unknown-forge destination, plan published" intent unknown-forge "$PLC_NG" "$PLC_SID"
case_end

case_begin "invalid-session" "bin/plan-link"
# detail.md names the exit code of a malformed session id only through resolvePlanLink's
# invalid-session reason, so any non-zero code with a stderr message is accepted.
for bad in "../escape" "not-a-session"; do
  plc_run -- --session "$bad"
  if [ "$PLC_RC" -ne 0 ] && [ "$PLC_RC" -ne 127 ]; then pass "session '$bad' exits non-zero"; else fail "session '$bad' exits non-zero" "rc=$PLC_RC out=$PLC_OUT"; fi
  if [ -n "$PLC_ERR" ]; then pass "session '$bad': message on stderr"; else fail "session '$bad': message on stderr" "stderr empty, stdout=[$PLC_OUT]"; fi
  plc_no_leak "session '$bad'"
done
plc_run "CLAUDE_CODE_SESSION_ID=" --
if [ "$PLC_RC" -ne 0 ] && [ "$PLC_RC" -ne 127 ]; then pass "no session at all exits non-zero"; else fail "no session at all exits non-zero" "rc=$PLC_RC out=$PLC_OUT"; fi
if [ -n "$PLC_ERR" ]; then pass "no session: message on stderr"; else fail "no session: message on stderr" "stderr empty, stdout=[$PLC_OUT]"; fi
case_end

case_begin "valid-session-zero-artifacts" "bin/plan-link"
# PLC_OTHER is a well-formed session id with no plan file at all: exit 1 (no plan file).
plc_run -- --session "$PLC_OTHER"
if [ "$PLC_RC" -eq 1 ]; then pass "zero artifacts exits 1"; else fail "zero artifacts exits 1" "rc=$PLC_RC out=$PLC_OUT"; fi
for st in intent outline detail; do
  plc_expect_line "zero artifacts: $st unavailable: no-artifact" "$st: (unavailable: no-artifact)"
done
plc_no_leak "zero artifacts"
plc_run -- --session "$PLC_SID" --stage detail
if [ "$PLC_RC" -eq 1 ]; then pass "--stage of an absent plan exits 1"; else fail "--stage of an absent plan exits 1" "rc=$PLC_RC out=$PLC_OUT"; fi
plc_expect_line "--stage of an absent plan: unavailable: no-artifact" "detail: (unavailable: no-artifact)"
case_end

case_begin "executable-bit" "bin/plan-link"
# Index mode, not the working-tree bit (Windows checkouts do not carry +x).
PLC_MODE="$(git -C "$SCRIPT_CHECKOUT_ROOT" ls-files -s -- bin/plan-link)"
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
