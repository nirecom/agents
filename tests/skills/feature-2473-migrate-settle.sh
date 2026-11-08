#!/usr/bin/env bash
# tests/skills/feature-2473-migrate-settle.sh
# Tests: skills/migrate/scripts/settle.sh
# Tags: TL2, skills, migrate, scope:issue-specific
# Issue #2473: settle.sh ends /migrate (MG-3). Each case runs the real script from a stub agents tree
# whose bin/migrate-needs and commit-migration-artifacts.sh record their calls.
# TL3 gap (what this test does NOT catch):
# - a model printing the script's MIGRATE_RESULT line as is and routing a non-zero exit to On failure;
# - a real origin push: the integration case runs --dry-run only.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'cd /; rm -rf "${TMPBASE:?}"' EXIT
harness_isolate "$TMPBASE/iso"
unset CLAUDE_PROJECT_DIR GIT_DIR GIT_WORK_TREE
cd "$TMPBASE"

SUT_REL="skills/migrate/scripts/settle.sh"
SUT_REAL="$SCRIPT_CHECKOUT_ROOT/$SUT_REL"
SUT_MISSING=0
[[ -f "$SUT_REAL" ]] || SUT_MISSING=1
TEMPLATE="$TMPBASE/stub-template"
mkdir -p "$TEMPLATE/bin/github-issues/migration" "$TEMPLATE/skills/migrate/scripts" "$TEMPLATE/.calls"

# Reads .calls/needs.seq, one "<rc>|<NEEDED>|<UNCOMMITTED>|<UNPUSHED>" per call; the last line repeats.
cat >"$TEMPLATE/bin/migrate-needs" <<'JS'
#!/usr/bin/env node
"use strict";
const fs = require("fs");
const path = require("path");
const calls = path.join(__dirname, "..", ".calls");
const log = path.join(calls, "needs.log");
fs.appendFileSync(log, process.argv.slice(2).join("\x1f") + "\n");
const n = fs.readFileSync(log, "utf8").split("\n").filter(Boolean).length;
const seq = fs.readFileSync(path.join(calls, "needs.seq"), "utf8").split(/\r?\n/).filter(Boolean);
const [rc, needed, uncommitted, unpushed] = seq[Math.min(n, seq.length) - 1].split("|");
if (rc !== "0") {
  process.stderr.write("migrate-needs stub: read failed\n");
  process.exit(Number(rc));
}
process.stdout.write(`NEEDED=${needed}\nUNCOMMITTED=${uncommitted}\nUNPUSHED=${unpushed}\nHOST=\nMALFORMED=0\n`);
JS

# Exit code from .calls/commit.rc (default 0); prints its own text on stdout as the real script does.
cat >"$TEMPLATE/bin/github-issues/migration/commit-migration-artifacts.sh" <<'SH'
#!/usr/bin/env bash
calls="$(cd "$(dirname "$0")/../../.." && pwd)/.calls"
(IFS=$'\037'; printf '%s\n' "$*") >>"$calls/commit.log"
echo "commit stub: [dry-run] would stage .agents.json"
rc=0
[[ -f "$calls/commit.rc" ]] && rc="$(cat "$calls/commit.rc")"
[[ "$rc" == 0 ]] || echo "commit stub: push refused" >&2
exit "$rc"
SH

# new_stub <name> <needs-seq-line>... — a fresh tree in STUB with the real settle.sh inside it.
new_stub() {
  local name="${1:?}"
  shift
  STUB="$TMPBASE/stubs/$name"
  mkdir -p "$TMPBASE/stubs"
  cp -R "$TEMPLATE" "$STUB"
  if [[ "$SUT_MISSING" -eq 0 ]]; then cp "$SUT_REAL" "$STUB/$SUT_REL"; fi
  printf '%s\n' "$@" >"$STUB/.calls/needs.seq"
}

# run_settle <args>... — runs the stub tree's settle.sh; sets RC, OUT_FILE, ERR_FILE.
run_settle() {
  OUT_FILE="$STUB/.calls/stdout"
  ERR_FILE="$STUB/.calls/stderr"
  RC=0
  bash "$STUB/$SUT_REL" "$@" >"$OUT_FILE" 2>"$ERR_FILE" </dev/null || RC=$?
}

check() {
  if [[ "$SUT_MISSING" -eq 1 ]]; then
    fail "$1" "$SUT_REL does not exist"
  elif eval "$2"; then
    pass "$1"
  else
    fail "$1" "${3:-rc=$RC stdout=$(cat "$OUT_FILE") stderr=$(cat "$ERR_FILE")}"
  fi
}

result_lines() { grep -c '^MIGRATE_RESULT=' "$OUT_FILE" || true; }
expect_rc() { check "exit $1" '[[ "$RC" -eq '"$1"' ]]'; }
# expect_result <value> — exactly one MIGRATE_RESULT line on stdout, the last line, with that value.
expect_result() {
  check "exactly one MIGRATE_RESULT line" '[[ "$(result_lines)" -eq 1 ]]'
  check "last stdout line is MIGRATE_RESULT=$1" '[[ "$(tail -n 1 "$OUT_FILE" | tr -d "\r")" == "MIGRATE_RESULT='"$1"'" ]]'
}
expect_no_result() { check "no MIGRATE_RESULT line on stdout" '[[ "$(result_lines)" -eq 0 ]]'; }
# expect_diagnostic — a failing run says why, since On failure shows the failing output to the user.
expect_diagnostic() { check "the failure says why" '[[ -s "$OUT_FILE" || -s "$ERR_FILE" ]]'; }
reads() { if [[ -f "$STUB/.calls/needs.log" ]]; then grep -c '' "$STUB/.calls/needs.log"; else echo 0; fi; }
commits() { if [[ -f "$STUB/.calls/commit.log" ]]; then grep -c '' "$STUB/.calls/commit.log"; else echo 0; fi; }
expect_no_commit() { check "no commit call" '[[ "$(commits)" -eq 0 ]]'; }
expect_reads() { check "$1 migrate-needs read(s)" '[[ "$(reads)" -eq '"$1"' ]]'; }
# expect_commit <root> <flag>... — exactly one call, ROOT first, then --skill migrate plus these flags.
expect_commit() {
  local root="$1" want got_root got_rest
  shift
  want="$(printf '%s\n' --skill migrate "$@" | LC_ALL=C sort | tr '\n' ' ')"
  check "exactly one commit call" '[[ "$(commits)" -eq 1 ]]'
  got_root="$(head -n 1 "$STUB/.calls/commit.log" 2>/dev/null | tr '\037' '\n' | head -n 1 | tr -d '\r' || true)"
  got_rest="$(head -n 1 "$STUB/.calls/commit.log" 2>/dev/null | tr '\037' '\n' | tail -n +2 | tr -d '\r' | LC_ALL=C sort | tr '\n' ' ' || true)"
  check "the commit gets ROOT as its first argument" '[[ "$got_root" == "$root" ]]' "want=$root got=$got_root"
  check "the commit gets exactly: $want" '[[ "$got_rest" == "$want" ]]' "got=$got_rest"
  check "--skill is followed by migrate" 'grep -q $'"'"'\037--skill\037migrate\($\|\037\)'"'"' "$STUB/.calls/commit.log"' "$(cat "$STUB/.calls/commit.log" 2>/dev/null || true)"
}

ROOT="$(np "$TMPBASE/target")"

case_begin "settle-all-done-ok" "skills/migrate/scripts/settle.sh"
new_stub all-done "0||0|0"
run_settle "$ROOT"
expect_rc 0
expect_result ok
expect_no_commit
check "the stub tree's migrate-needs is what ran, resolved from the script's own location" '[[ "$(reads)" -ge 1 ]]'
check "migrate-needs gets --root ROOT" '[[ "$(head -n 1 "$STUB/.calls/needs.log" | tr -d "\r")" == "--root"$'"'"'\037'"'"'"$ROOT" ]]' "$(head -n 1 "$STUB/.calls/needs.log" 2>/dev/null || true)"
case_end

case_begin "settle-unpushed-with-no-push-counts-as-settled" "skills/migrate/scripts/settle.sh"
new_stub unpushed-no-push "0||0|1"
run_settle "$ROOT" --no-push
expect_rc 0
expect_result ok
expect_no_commit
case_end

case_begin "settle-uncommitted-recovers-on-second-read" "skills/migrate/scripts/settle.sh"
new_stub uncommitted "0||1|0" "0||0|0"
run_settle "$ROOT"
expect_rc 0
expect_result ok
expect_commit "$ROOT"
expect_reads 2
case_end

case_begin "settle-unpushed-without-no-push-goes-to-recovery" "skills/migrate/scripts/settle.sh"
new_stub unpushed "0||0|1" "0||0|0"
run_settle "$ROOT"
expect_rc 0
expect_result ok
expect_commit "$ROOT"
case_end

# The second read judges by --no-push as well: UNPUSHED=1 is settled there.
case_begin "settle-recovery-forwards-no-push" "skills/migrate/scripts/settle.sh"
new_stub recover-no-push "0||1|0" "0||0|1"
run_settle "$ROOT" --no-push
expect_rc 0
expect_result ok
expect_commit "$ROOT" --no-push
case_end

case_begin "settle-commit-text-keeps-result-last-and-only" "skills/migrate/scripts/settle.sh"
new_stub commit-text "0||1|0" "0||0|0"
run_settle "$ROOT"
expect_result ok
check "the commit's own text never counts as a result line" '[[ "$(grep -c "^MIGRATE_RESULT=" "$OUT_FILE")" -eq 1 ]]'
case_end

case_begin "settle-dry-run-with-nothing-left-is-ok" "skills/migrate/scripts/settle.sh"
new_stub dry-nothing "0||0|0"
run_settle "$ROOT" --dry-run
expect_rc 0
expect_result ok
expect_no_commit
case_end

case_begin "settle-dry-run-unsettled-commits-with-dry-run" "skills/migrate/scripts/settle.sh"
new_stub dry-unsettled "0||1|0"
run_settle "$ROOT" --dry-run
expect_rc 0
expect_result skipped
expect_commit "$ROOT" --dry-run
case_end

case_begin "settle-dry-run-needed-never-commits" "skills/migrate/scripts/settle.sh"
new_stub dry-needed "0|migrate-tests|1|1"
run_settle "$ROOT" --dry-run
expect_rc 0
expect_result skipped
expect_no_commit
case_end

case_begin "settle-flags-forward-in-either-order" "skills/migrate/scripts/settle.sh"
new_stub flags-a "0||1|0"
run_settle "$ROOT" --dry-run --no-push
expect_rc 0
expect_result skipped
expect_commit "$ROOT" --dry-run --no-push
new_stub flags-b "0||1|0"
run_settle "$ROOT" --no-push --dry-run
expect_rc 0
expect_result skipped
expect_commit "$ROOT" --dry-run --no-push
case_end

case_begin "settle-needed-left-fails-without-commit" "skills/migrate/scripts/settle.sh"
new_stub needed "0|migrate-tests|1|0"
run_settle "$ROOT"
expect_rc 1
expect_no_result
expect_no_commit
expect_diagnostic
case_end

case_begin "settle-recovery-still-unsettled-fails" "skills/migrate/scripts/settle.sh"
new_stub still-unsettled "0||1|0" "0||1|0"
run_settle "$ROOT"
expect_rc 1
expect_no_result
expect_commit "$ROOT"
expect_reads 2
expect_diagnostic
new_stub still-unpushed "0||0|1" "0||0|1"
run_settle "$ROOT"
expect_rc 1
expect_no_result
new_stub still-needed "0||1|0" "0|migrate-tests|0|0"
run_settle "$ROOT"
expect_rc 1
expect_no_result
case_end

case_begin "settle-commit-failure-fails" "skills/migrate/scripts/settle.sh"
new_stub commit-fails "0||1|0" "0||0|0"
printf '7\n' >"$STUB/.calls/commit.rc"
run_settle "$ROOT"
expect_rc 1
expect_no_result
check "the commit's own error reaches the caller" 'grep -q "push refused" "$OUT_FILE" "$ERR_FILE"'
new_stub commit-fails-dry "0||1|0"
printf '7\n' >"$STUB/.calls/commit.rc"
run_settle "$ROOT" --dry-run
expect_rc 1
expect_no_result
case_end

# Exit 2 from migrate-needs is its usage error; settle.sh keeps exit 2 for its own bad arguments.
case_begin "settle-first-read-failure-fails" "skills/migrate/scripts/settle.sh"
new_stub first-read "2|||"
run_settle "$ROOT"
expect_rc 1
expect_no_result
expect_no_commit
expect_diagnostic
new_stub first-read-dry "1|||"
run_settle "$ROOT" --dry-run
expect_rc 1
expect_no_result
expect_no_commit
case_end

case_begin "settle-second-read-failure-fails" "skills/migrate/scripts/settle.sh"
new_stub second-read "0||1|0" "1|||"
run_settle "$ROOT"
expect_rc 1
expect_no_result
expect_commit "$ROOT"
expect_diagnostic
case_end

case_begin "settle-bad-arguments-exit-2-call-nothing" "skills/migrate/scripts/settle.sh"
new_stub bad-none "0||0|0"
run_settle
expect_rc 2
expect_no_result
check "no argument: no migrate-needs call" '[[ "$(reads)" -eq 0 ]]'
expect_no_commit
new_stub bad-flag "0||0|0"
run_settle "$ROOT" --bogus
expect_rc 2
expect_no_result
check "unknown flag: no migrate-needs call" '[[ "$(reads)" -eq 0 ]]'
expect_no_commit
new_stub bad-flag-only "0||0|0"
run_settle --no-push
expect_rc 2
check "flag without ROOT: no migrate-needs call" '[[ "$(reads)" -eq 0 ]]'
new_stub bad-empty "0||0|0"
run_settle ""
expect_rc 2
check "empty ROOT: no migrate-needs call" '[[ "$(reads)" -eq 0 ]]'
case_end

case_begin "settle-root-stays-one-literal-argument" "skills/migrate/scripts/settle.sh"
SPACE_ROOT="$ROOT with space"
new_stub root-space "0||1|0" "0||0|0"
run_settle "$SPACE_ROOT"
expect_rc 0
expect_result ok
expect_commit "$SPACE_ROOT"
check "migrate-needs gets ROOT with its space" 'grep -qF "with space" "$STUB/.calls/needs.log"'
# shellcheck disable=SC2016 # the expansion characters are the point: they must stay literal
HOSTILE_ROOT="$ROOT"'/$(touch settle-pwned) `touch settle-pwned`;x'
new_stub root-hostile "0||1|0" "0||0|0"
run_settle "$HOSTILE_ROOT"
expect_commit "$HOSTILE_ROOT"
check "metacharacters in ROOT are not expanded" '[[ ! -e "$TMPBASE/settle-pwned" ]]'
case_end

case_begin "settle-resolves-its-tree-from-any-cwd" "skills/migrate/scripts/settle.sh"
new_stub relative "0||0|0"
OUT_FILE="$STUB/.calls/stdout"
ERR_FILE="$STUB/.calls/stderr"
RC=0
(cd "$STUB/skills/migrate" && bash scripts/settle.sh "$ROOT") >"$OUT_FILE" 2>"$ERR_FILE" </dev/null || RC=$?
expect_rc 0
expect_result ok
check "a relative invocation still reaches the stub tree" '[[ "$(reads)" -eq 1 ]]'
case_end

# Integration: the checkout's real settle.sh, bin/migrate-needs and commit script against a fixture
# repo. A dry run writes nothing, so this cannot touch anything but the fixture's read side.
INTEGRATION_DONE='{"tests":{"dir":"tests","categorization":"flat","testHarness":"off","caseMarker":"off"},"migrate":{"tracker":"done","issues":"done"}}'
# fixture_state <repo> — HEAD, the porcelain status and the settings file bytes, for before/after.
fixture_state() { git -C "$1" rev-parse HEAD; git -C "$1" status --porcelain; cat "$1/.agents.json" 2>/dev/null || true; }
new_fixture() {
  FIXTURE="$TMPBASE/fixtures/$1"
  mkdir -p "$TMPBASE/fixtures"
  harness_git_init "$FIXTURE"
  git -C "$FIXTURE" config user.name t
  git -C "$FIXTURE" config user.email t@example.com
  printf 'fixture\n' >"$FIXTURE/README"
  git -C "$FIXTURE" add README
  git -C "$FIXTURE" commit -q --no-verify -m init
}
run_real_settle() {
  OUT_FILE="$FIXTURE/../$1.out"
  ERR_FILE="$FIXTURE/../$1.err"
  RC=0
  bash "$SUT_REAL" "$(np "$FIXTURE")" --dry-run >"$OUT_FILE" 2>"$ERR_FILE" </dev/null || RC=$?
}

case_begin "settle-real-tools-dry-run-uncommitted" "skills/migrate/scripts/settle.sh"
new_fixture real-uncommitted
printf '%s\n' "$INTEGRATION_DONE" >"$FIXTURE/.agents.json"
BEFORE="$(fixture_state "$FIXTURE")"
run_real_settle real-uncommitted
expect_rc 0
expect_result skipped
check "real tools: the fixture repo is unchanged" '[[ "$(fixture_state "$FIXTURE")" == "$BEFORE" ]]'
case_end

case_begin "settle-real-tools-dry-run-needed" "skills/migrate/scripts/settle.sh"
new_fixture real-needed
BEFORE="$(fixture_state "$FIXTURE")"
run_real_settle real-needed
expect_rc 0
expect_result skipped
check "real tools: no .agents.json appears" '[[ ! -e "$FIXTURE/.agents.json" ]]'
check "real tools: the fixture repo is unchanged" '[[ "$(fixture_state "$FIXTURE")" == "$BEFORE" ]]'
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
