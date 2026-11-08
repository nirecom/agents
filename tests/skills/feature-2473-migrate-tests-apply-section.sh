#!/usr/bin/env bash
# tests/skills/feature-2473-migrate-tests-apply-section.sh
# Tests: skills/migrate-tests/scripts/apply-section.sh
# Tags: TL2, skills, migrate, scope:issue-specific
# Issue #2473: apply-section.sh is /migrate-tests MTS-3: write the tests section, then commit it. Stub
# cases record bin/repo-settings, bin/migrate-needs and the commit script; real-tools cases run them.
# TL3 gap (what this test does NOT catch):
# - a model confirming through AskUserQuestion on exit 3 and re-running the write after the reset;
# - a real origin push: the real-tools commit runs with --no-push.
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

SUT_REL="skills/migrate-tests/scripts/apply-section.sh"
SUT_REAL="$SCRIPT_CHECKOUT_ROOT/$SUT_REL"
SUT_MISSING=0
[[ -f "$SUT_REAL" ]] || SUT_MISSING=1
TEMPLATE="$TMPBASE/stub-template"
mkdir -p "$TEMPLATE/bin/github-issues/migration" "$TEMPLATE/skills/migrate-tests/scripts" "$TEMPLATE/.calls"

# Call <n> (0-based) stores each argument raw in .calls/rs.<n>.arg.<i> and appends one line to
# .calls/rs.log; exit code from .calls/rs.rc (default 0).
cat >"$TEMPLATE/bin/repo-settings" <<'JS'
#!/usr/bin/env node
"use strict";
const fs = require("fs");
const path = require("path");
const calls = path.join(__dirname, "..", ".calls");
const args = process.argv.slice(2);
const log = path.join(calls, "rs.log");
const n = fs.existsSync(log) ? fs.readFileSync(log, "utf8").split("\n").filter(Boolean).length : 0;
fs.writeFileSync(path.join(calls, `rs.${n}.argc`), String(args.length));
args.forEach((a, i) => fs.writeFileSync(path.join(calls, `rs.${n}.arg.${i}`), a));
fs.appendFileSync(log, args.join("\x1f").replace(/\n/g, " ") + "\n");
const rcFile = path.join(calls, "rs.rc");
const rc = fs.existsSync(rcFile) ? Number(fs.readFileSync(rcFile, "utf8").trim()) : 0;
if (rc !== 0) process.stderr.write("repo-settings stub: nothing written, refused\n");
process.exit(rc);
JS

# MALFORMED from .calls/needs.malformed (default 0); exit code from .calls/needs.rc (default 0).
cat >"$TEMPLATE/bin/migrate-needs" <<'JS'
#!/usr/bin/env node
"use strict";
const fs = require("fs");
const path = require("path");
const calls = path.join(__dirname, "..", ".calls");
fs.appendFileSync(path.join(calls, "needs.log"), process.argv.slice(2).join("\x1f") + "\n");
const read = (name, dflt) => (fs.existsSync(path.join(calls, name)) ? fs.readFileSync(path.join(calls, name), "utf8").trim() : dflt);
const rc = Number(read("needs.rc", "0"));
if (rc !== 0) {
  process.stderr.write("migrate-needs stub: read failed\n");
  process.exit(rc);
}
process.stdout.write(`NEEDED=\nUNCOMMITTED=0\nUNPUSHED=0\nHOST=\nMALFORMED=${read("needs.malformed", "0")}\n`);
JS

# Exit code from .calls/commit.rc (default 0).
cat >"$TEMPLATE/bin/github-issues/migration/commit-migration-artifacts.sh" <<'SH'
#!/usr/bin/env bash
calls="$(cd "$(dirname "$0")/../../.." && pwd)/.calls"
(IFS=$'\037'; printf '%s\n' "$*") >>"$calls/commit.log"
rc=0
[[ -f "$calls/commit.rc" ]] && rc="$(cat "$calls/commit.rc")"
[[ "$rc" == 0 ]] || echo "commit stub: push refused" >&2
exit "$rc"
SH

new_stub() {
  STUB="$TMPBASE/stubs/${1:?}"
  mkdir -p "$TMPBASE/stubs"
  cp -R "$TEMPLATE" "$STUB"
  if [[ "$SUT_MISSING" -eq 0 ]]; then cp "$SUT_REAL" "$STUB/$SUT_REL"; fi
}
set_calls() { printf '%s\n' "$2" >"$STUB/.calls/$1"; }

# run_apply <args>... — runs the stub tree's apply-section.sh; sets RC, OUT_FILE, ERR_FILE.
run_apply() {
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

expect_rc() { check "exit $1" '[[ "$RC" -eq '"$1"' ]]'; }
reads() { if [[ -f "$STUB/.calls/needs.log" ]]; then grep -c '' "$STUB/.calls/needs.log"; else echo 0; fi; }
commits() { if [[ -f "$STUB/.calls/commit.log" ]]; then grep -c '' "$STUB/.calls/commit.log"; else echo 0; fi; }
expect_no_commit() { check "no commit call" '[[ "$(commits)" -eq 0 ]]'; }
expect_nothing_called() {
  check "repo-settings not called" '[[ "$(rs_calls)" -eq 0 ]]'
  check "migrate-needs not called" '[[ "$(reads)" -eq 0 ]]'
  expect_no_commit
}
rs_calls() { if [[ -f "$STUB/.calls/rs.log" ]]; then grep -c '' "$STUB/.calls/rs.log"; else echo 0; fi; }
# rs_arg <i> [<n>] — argument i of repo-settings call n (default 0, the --write-tests call).
rs_arg() { cat "$STUB/.calls/rs.${2:-0}.arg.$1" 2>/dev/null || true; }
# expect_write <root> <json> — the first call is exactly: --root <root> --write-tests <json>, bytes intact.
expect_write() {
  local root="$1" json="$2"
  check "repo-settings gets four arguments" '[[ "$(cat "$STUB/.calls/rs.0.argc" 2>/dev/null)" == 4 ]]'
  check "repo-settings gets --root ROOT" '[[ "$(rs_arg 0)" == --root && "$(rs_arg 1)" == "$root" ]]' "got=$(rs_arg 0) $(rs_arg 1)"
  check "repo-settings gets --write-tests" '[[ "$(rs_arg 2)" == --write-tests ]]' "got=$(rs_arg 2)"
  printf '%s' "$json" >"$STUB/.calls/rs.want"
  check "the JSON reaches repo-settings byte-identically" 'cmp -s "$STUB/.calls/rs.want" "$STUB/.calls/rs.0.arg.3"' "want=$json got=$(rs_arg 3)"
}
# expect_set_migrate <root> — the second and last call is exactly: --root <root> --set-migrate tests.
expect_set_migrate() {
  local root="$1"
  check "repo-settings is called twice" '[[ "$(rs_calls)" -eq 2 ]]' "calls=$(rs_calls)"
  check "--root ROOT --set-migrate tests follows --write-tests" '[[ "$(cat "$STUB/.calls/rs.1.argc" 2>/dev/null)" == 4 && "$(rs_arg 0 1)" == --root && "$(rs_arg 1 1)" == "$root" && "$(rs_arg 2 1)" == --set-migrate && "$(rs_arg 3 1)" == tests ]]' "got=$(tr '\037' ' ' <"$STUB/.calls/rs.log" 2>/dev/null || true)"
}
# expect_commit <root> <flag>... — exactly one call, ROOT first, then --skill migrate-tests plus these flags.
expect_commit() {
  local root="$1" want got_root got_rest
  shift
  want="$(printf '%s\n' --skill migrate-tests "$@" | LC_ALL=C sort | tr '\n' ' ')"
  check "exactly one commit call" '[[ "$(commits)" -eq 1 ]]'
  got_root="$(head -n 1 "$STUB/.calls/commit.log" 2>/dev/null | tr '\037' '\n' | head -n 1 | tr -d '\r' || true)"
  got_rest="$(head -n 1 "$STUB/.calls/commit.log" 2>/dev/null | tr '\037' '\n' | tail -n +2 | tr -d '\r' | LC_ALL=C sort | tr '\n' ' ' || true)"
  check "the commit gets ROOT as its first argument" '[[ "$got_root" == "$root" ]]' "want=$root got=$got_root"
  check "the commit gets exactly: $want" '[[ "$got_rest" == "$want" ]]' "got=$got_rest"
  check "--skill is followed by migrate-tests" 'grep -q $'"'"'\037--skill\037migrate-tests\($\|\037\)'"'"' "$STUB/.calls/commit.log"' "$(cat "$STUB/.calls/commit.log" 2>/dev/null || true)"
}

ROOT="$(np "$TMPBASE/target")"
JSON='{"categorization":"flat","testHarness":"off","caseMarker":"off"}'

case_begin "apply-write-then-commit" "skills/migrate-tests/scripts/apply-section.sh"
new_stub ok
run_apply "$ROOT" "$JSON"
expect_rc 0
expect_write "$ROOT" "$JSON"
expect_set_migrate "$ROOT"
expect_commit "$ROOT"
check "a successful write needs no migrate-needs read" '[[ "$(reads)" -eq 0 ]]'
case_end

case_begin "apply-forwards-no-push" "skills/migrate-tests/scripts/apply-section.sh"
new_stub no-push
run_apply "$ROOT" "$JSON" --no-push
expect_rc 0
expect_write "$ROOT" "$JSON"
expect_commit "$ROOT" --no-push
case_end

case_begin "apply-refused-malformed-exits-3" "skills/migrate-tests/scripts/apply-section.sh"
new_stub refused-malformed
set_calls rs.rc 1
set_calls needs.malformed 1
run_apply "$ROOT" "$JSON"
expect_rc 3
expect_no_commit
check "migrate-needs gets --root ROOT" '[[ "$(head -n 1 "$STUB/.calls/needs.log" | tr -d "\r")" == "--root"$'"'"'\037'"'"'"$ROOT" ]]' "$(cat "$STUB/.calls/needs.log" 2>/dev/null || true)"
check "the refusal is shown on stderr" 'grep -q "nothing written, refused" "$ERR_FILE"'
case_end

case_begin "apply-refused-otherwise-exits-1" "skills/migrate-tests/scripts/apply-section.sh"
new_stub refused-section
set_calls rs.rc 1
set_calls needs.malformed 0
run_apply "$ROOT" "$JSON"
expect_rc 1
expect_no_commit
check "the refusal is shown on stderr" 'grep -q "nothing written, refused" "$ERR_FILE"'
check "a refused write records no --set-migrate" '[[ "$(rs_calls)" -eq 1 ]] && ! grep -q -- "--set-migrate" "$STUB/.calls/rs.log"' "got=$(tr '\037' ' ' <"$STUB/.calls/rs.log" 2>/dev/null || true)"
new_stub refused-rc2
set_calls rs.rc 2
set_calls needs.malformed 0
run_apply "$ROOT" "$JSON"
expect_rc 1
expect_no_commit
new_stub refused-needs-fails
set_calls rs.rc 1
set_calls needs.rc 1
run_apply "$ROOT" "$JSON"
expect_rc 1
expect_no_commit
check "the refusal is shown even when migrate-needs fails" 'grep -q "nothing written, refused" "$ERR_FILE"'
case_end

case_begin "apply-commit-failure-exits-1" "skills/migrate-tests/scripts/apply-section.sh"
new_stub commit-fails
set_calls commit.rc 7
run_apply "$ROOT" "$JSON"
expect_rc 1
expect_commit "$ROOT"
check "the commit's own error reaches the caller" 'grep -q "push refused" "$OUT_FILE" "$ERR_FILE"'
case_end

case_begin "apply-bad-arguments-exit-2-call-nothing" "skills/migrate-tests/scripts/apply-section.sh"
new_stub bad-none
run_apply
expect_rc 2
expect_nothing_called
new_stub bad-root-only
run_apply "$ROOT"
expect_rc 2
expect_nothing_called
new_stub bad-flag
run_apply "$ROOT" "$JSON" --bogus
expect_rc 2
expect_nothing_called
new_stub bad-flag-as-json
run_apply "$ROOT" --no-push
expect_rc 2
expect_nothing_called
new_stub bad-empty-json
run_apply "$ROOT" ""
expect_rc 2
expect_nothing_called
case_end

# A section's strings arrive from a model's confirmed answer: nothing in them may be expanded.
case_begin "apply-json-stays-one-literal-argument" "skills/migrate-tests/scripts/apply-section.sh"
# shellcheck disable=SC2016 # the expansion characters are the point: they must stay literal
HOSTILE_JSON='{"dir":"te sts","note":"$HOME `touch apply-pwned-1` $(touch apply-pwned-2) ; touch apply-pwned-3"}'
new_stub hostile-json
run_apply "$ROOT" "$HOSTILE_JSON"
expect_rc 0
expect_write "$ROOT" "$HOSTILE_JSON"
expect_commit "$ROOT"
check "nothing in the JSON was expanded" '[[ ! -e "$TMPBASE/apply-pwned-1" && ! -e "$TMPBASE/apply-pwned-2" && ! -e "$TMPBASE/apply-pwned-3" ]]'
case_end

case_begin "apply-root-with-space" "skills/migrate-tests/scripts/apply-section.sh"
SPACE_ROOT="$ROOT with space"
new_stub root-space
run_apply "$SPACE_ROOT" "$JSON" --no-push
expect_rc 0
expect_write "$SPACE_ROOT" "$JSON"
expect_commit "$SPACE_ROOT" --no-push
case_end

case_begin "apply-resolves-its-tree-from-any-cwd" "skills/migrate-tests/scripts/apply-section.sh"
new_stub relative
OUT_FILE="$STUB/.calls/stdout"
ERR_FILE="$STUB/.calls/stderr"
RC=0
(cd "$STUB/skills/migrate-tests" && bash scripts/apply-section.sh "$ROOT" "$JSON") >"$OUT_FILE" 2>"$ERR_FILE" </dev/null || RC=$?
expect_rc 0
expect_write "$ROOT" "$JSON"
expect_commit "$ROOT"
case_end

# Integration: the checkout's real script, bin/repo-settings, bin/migrate-needs and commit script
# against a fixture repo, so the exit-code mapping meets the real CLIs' refusals.
new_fixture() {
  FIXTURE="$TMPBASE/fixtures/$1"
  mkdir -p "$TMPBASE/fixtures"
  harness_git_init "$FIXTURE"
  git -C "$FIXTURE" config user.name t
  git -C "$FIXTURE" config user.email t@example.com
  printf 'fixture\n' >"$FIXTURE/README"
  git -C "$FIXTURE" add README
  git -C "$FIXTURE" commit -q --no-verify -m init
  FIXTURE_HEAD="$(git -C "$FIXTURE" rev-parse HEAD)"
}
run_real_apply() {
  OUT_FILE="$TMPBASE/fixtures/real.out"
  ERR_FILE="$TMPBASE/fixtures/real.err"
  RC=0
  bash "$SUT_REAL" "$(np "$FIXTURE")" "$@" >"$OUT_FILE" 2>"$ERR_FILE" </dev/null || RC=$?
}

case_begin "apply-real-tools-malformed-file-exits-3" "skills/migrate-tests/scripts/apply-section.sh"
new_fixture real-not-json
printf 'not json at all\n' >"$FIXTURE/.agents.json"
run_real_apply "$JSON" --no-push
expect_rc 3
check "real tools: the file holds the same bytes" '[[ "$(cat "$FIXTURE/.agents.json")" == "not json at all" ]]'
check "real tools: no backup is made" '[[ ! -e "$FIXTURE/.agents.json.malformed" ]]'
check "real tools: nothing is committed" '[[ "$(git -C "$FIXTURE" rev-parse HEAD)" == "$FIXTURE_HEAD" ]]'
check "real tools: the refusal is shown on stderr" 'grep -q "reset-malformed" "$ERR_FILE"'
new_fixture real-array
printf '[]\n' >"$FIXTURE/.agents.json"
run_real_apply "$JSON" --no-push
expect_rc 3
check "real tools: an array is refused the same way" '[[ "$(cat "$FIXTURE/.agents.json")" == "[]" && "$(git -C "$FIXTURE" rev-parse HEAD)" == "$FIXTURE_HEAD" ]]'
case_end

case_begin "apply-real-tools-refused-section-exits-1" "skills/migrate-tests/scripts/apply-section.sh"
new_fixture real-bad-section
run_real_apply '{"categorization":"no-such-layout"}' --no-push
expect_rc 1
check "real tools: nothing is written" '[[ ! -e "$FIXTURE/.agents.json" ]]'
check "real tools: nothing is committed" '[[ "$(git -C "$FIXTURE" rev-parse HEAD)" == "$FIXTURE_HEAD" ]]'
case_end

case_begin "apply-real-tools-writes-and-commits" "skills/migrate-tests/scripts/apply-section.sh"
new_fixture real-ok
run_real_apply "$JSON" --no-push
expect_rc 0
check "real tools: HEAD holds the section" 'git -C "$FIXTURE" show HEAD:.agents.json 2>/dev/null | grep -q "\"categorization\": \"flat\""'
check "real tools: HEAD records migrate.tests done" 'git -C "$FIXTURE" show HEAD:.agents.json 2>/dev/null | grep -q "\"tests\": \"done\""'
check "real tools: only .agents.json is in the commit" '[[ "$(git -C "$FIXTURE" show --name-only --format= HEAD | tr -d "\r" | sed "/^$/d")" == ".agents.json" ]]'
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
