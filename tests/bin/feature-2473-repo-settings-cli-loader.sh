#!/usr/bin/env bash
# tests/bin/feature-2473-repo-settings-cli-loader.sh
# Tests: bin/repo-settings, bin/lib/repo-settings.sh
# Tags: TL2, bin, repo-settings, migrate, scope:issue-specific, test-lang-exception:e2e
# Issue #2473: the repo settings CLI (read, --set-migrate, --write-tests; exit 0 ok / 1 missing or
# malformed / 2 bad arguments; writes never commit) and the bash loader (rsf_load calls the CLI
# once per (CLI, root), like tlr_load).
# TL3 gap: a real migrate run writes through the CLI from a skill; here the CLI runs on fixtures.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR GIT_DIR GIT_WORK_TREE

CLI="$SCRIPT_CHECKOUT_ROOT/bin/repo-settings"
LOADER="$SCRIPT_CHECKOUT_ROOT/bin/lib/repo-settings.sh"
REAL_NODE="$(command -v node)"
cd "$TMPBASE" || exit 1

OK_JSON='{"tests":{"dir":"tests","categorization":"by-target","categories":[{"dir":"hooks","covers":["hooks"]},{"dir":"bin","covers":["bin"]}],"supportDirs":["lib"],"testHarness":"on","caseMarker":"off"}}'

# fx <name> [<content>] — a git fixture, with .agents.json when content is given (committed).
fx() {
  local d="$TMPBASE/$1"
  mkdir -p "$d"
  harness_git_init "$d"
  if [ $# -ge 2 ]; then
    printf '%s\n' "$2" >"$d/.agents.json"
    git -C "$d" add .agents.json
    git -C "$d" -c user.email=t@t -c user.name=t commit -qm init
  fi
  np "$d"
}

# cli <args...> — sets CLI_RC / CLI_OUT.
cli() {
  CLI_OUT="$(run_with_timeout 60 node "$(np "$CLI")" "$@" 2>&1)"
  CLI_RC=$?
}

# json_field <json-text> <expr> — evaluate a JS expression over parsed JSON (d).
json_field() {
  node -e 'const d = JSON.parse(process.argv[1]); process.stdout.write(String(eval(process.argv[2])));' "$1" "$2" 2>/dev/null
}

R_OK="$(fx ok "$OK_JSON")"
R_MISSING="$(fx missing)"
R_BAD="$(fx bad '{ not json')"

case_begin "CLI-exit-codes" "bin/repo-settings"
cli --root "$R_OK" --format json
assert_eq "ok rc=$CLI_RC" "ok rc=0"
assert_eq "ok tests.state=$(json_field "$CLI_OUT" 'd.tests.state')" "ok tests.state=ok"
cli --root "$R_MISSING" --format json
assert_eq "missing rc=$CLI_RC" "missing rc=1"
assert_eq "missing tests.state=$(json_field "$CLI_OUT" 'd.tests.state')" "missing tests.state=missing"
cli --root "$R_BAD" --format json
assert_eq "malformed rc=$CLI_RC" "malformed rc=1"
cli --root "$(np "$SCRIPT_CHECKOUT_ROOT")" --format json
assert_eq "agents own rc=$CLI_RC" "agents own rc=0"
case_end

case_begin "CLI-bad-arguments" "bin/repo-settings"
cli --root "$R_OK" --format xml
assert_eq "bad format rc=$CLI_RC" "bad format rc=2"
cli --root
assert_eq "valueless --root rc=$CLI_RC" "valueless --root rc=2"
cli --root "$R_OK" --no-such-flag
assert_eq "unknown flag rc=$CLI_RC" "unknown flag rc=2"
case_end

case_begin "CLI-set-migrate" "bin/repo-settings"
R_SM="$(fx setmig "$OK_JSON")"
head_before="$(git -C "$R_SM" rev-parse HEAD)"
cli --root "$R_SM" --set-migrate tracker
assert_eq "set-migrate rc=$CLI_RC" "set-migrate rc=0"
got="$(json_field "$(cat "$R_SM/.agents.json")" 'd.migrate.tracker + "|" + d.tests.categorization')"
assert_eq "written: $got" "written: done|by-target"
assert_eq "no commit: $(git -C "$R_SM" rev-parse HEAD)" "no commit: $head_before"
R_SM2="$(fx setmig-new)"
cli --root "$R_SM2" --set-migrate issues
assert_eq "set-migrate on a missing file rc=$CLI_RC" "set-migrate on a missing file rc=0"
assert_eq "created: $(json_field "$(cat "$R_SM2/.agents.json" 2>/dev/null)" 'd.migrate.issues')" "created: done"
before="$(cat "$R_SM/.agents.json")"
cli --root "$R_SM" --set-migrate nonsense
if [ "$CLI_RC" -ne 0 ] && [ "$(cat "$R_SM/.agents.json")" = "$before" ]; then
  pass "unknown migrate key is refused and the file is unchanged (rc=$CLI_RC)"
else
  fail "unknown migrate key is refused and the file is unchanged" "rc=$CLI_RC"
fi
case_end

case_begin "CLI-write-tests" "bin/repo-settings"
R_WT="$(fx writetests '{"migrate":{"tracker":"done"}}')"
head_before="$(git -C "$R_WT" rev-parse HEAD)"
cli --root "$R_WT" --write-tests '{"categorization":"flat","testHarness":"off","caseMarker":"off"}'
assert_eq "write-tests rc=$CLI_RC" "write-tests rc=0"
got="$(json_field "$(cat "$R_WT/.agents.json")" 'd.tests.categorization + "|" + d.tests.testHarness + "|" + d.migrate.tracker')"
assert_eq "written: $got" "written: flat|off|done"
assert_eq "no commit: $(git -C "$R_WT" rev-parse HEAD)" "no commit: $head_before"
before="$(cat "$R_WT/.agents.json")"
cli --root "$R_WT" --write-tests '{"categorization":"flat","categories":[{"dir":"x"}],"testHarness":"on","caseMarker":"on"}'
assert_eq "invalid tests rc=$CLI_RC" "invalid tests rc=1"
assert_eq "file unchanged: $([ "$(cat "$R_WT/.agents.json")" = "$before" ] && echo yes || echo no)" "file unchanged: yes"
cli --root "$R_WT" --write-tests '{ not json'
assert_eq "unparsable tests rc=$CLI_RC" "unparsable tests rc=1"
assert_eq "file unchanged: $([ "$(cat "$R_WT/.agents.json")" = "$before" ] && echo yes || echo no)" "file unchanged: yes"
case_end

# Table: name | args (ROOT = a fresh fixture holding OK_JSON) | want rc. rc=2 rows must print the
# usage line and leave .agents.json untouched.
case_begin "CLI-arg-parser-table" "bin/repo-settings"
while IFS='|' read -r name args want; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"
  want="${want//[[:space:]]/}"
  root="$(fx "argtab-$name" "$OK_JSON")"
  before="$(cat "$root/.agents.json")"
  read -r -a argv <<<"$args"
  for i in "${!argv[@]}"; do [ "${argv[$i]}" = "ROOT" ] && argv[$i]="$root"; done
  cli "${argv[@]}"
  assert_eq "$name rc=$CLI_RC" "$name rc=$want"
  if [ "$want" = "2" ]; then
    assert_eq "$name usage=$(printf '%s\n' "$CLI_OUT" | grep -c '^usage: repo-settings')" "$name usage=1"
    assert_eq "$name unchanged=$([ "$(cat "$root/.agents.json")" = "$before" ] && echo yes || echo no)" "$name unchanged=yes"
  fi
done <<'TABLE'
read-default-format   | --root ROOT                                       | 0
read-shell            | --root ROOT --format shell                        | 0
read-json-flag-first  | --format json --root ROOT                         | 0
root-repeated         | --root /nonexistent-rsf-root --root ROOT          | 0
set-migrate-tests     | --root ROOT --set-migrate tests                   | 0
write-tests-flat      | --root ROOT --write-tests {"categorization":"flat","testHarness":"off","caseMarker":"off"} | 0
format-unknown        | --root ROOT --format xml                          | 2
flag-unknown          | --root ROOT --bogus x                             | 2
positional-arg        | ROOT                                              | 2
root-no-value         | --root                                            | 2
format-no-value       | --root ROOT --format                              | 2
set-migrate-no-value  | --root ROOT --set-migrate                         | 2
write-tests-no-value  | --root ROOT --write-tests                         | 2
set-migrate-bad-key   | --root ROOT --set-migrate history                 | 2
set-migrate-and-write | --root ROOT --set-migrate tracker --write-tests {"categorization":"flat","testHarness":"off","caseMarker":"off"} | 2
write-and-set-migrate | --root ROOT --write-tests {"categorization":"flat","testHarness":"off","caseMarker":"off"} --set-migrate tracker | 2
TABLE
case_end

case_begin "CLI-set-migrate-with-write-tests-writes-nothing" "bin/repo-settings"
R_BOTH="$(fx both-missing)"
cli --root "$R_BOTH" --set-migrate tracker --write-tests '{"categorization":"flat","testHarness":"off","caseMarker":"off"}'
assert_eq "both flags on a missing file rc=$CLI_RC" "both flags on a missing file rc=2"
assert_eq "no file written: $([ -e "$R_BOTH/.agents.json" ] && echo exists || echo absent)" "no file written: absent"
cli --root "$R_BOTH" --format ""
assert_eq "empty --format value rc=$CLI_RC" "empty --format value rc=2"
case_end

# rsf <root> <snippet> — source the loader in a fresh bash and run <snippet> after it.
rsf() {
  run_with_timeout 60 bash -c '. "$1" || exit 97; '"$2" _ "$LOADER" "$1" "${@:3}" 2>&1
}

case_begin "LOADER-vars" "bin/lib/repo-settings.sh"
got="$(rsf "$R_OK" 'rsf_load "$2"; printf "%s|%s|%s|%s|%s|" "$RSF_TESTS_STATE" "$RSF_TESTS_DIR" "$RSF_CATEGORIZATION" "$RSF_TEST_HARNESS" "$RSF_CASE_MARKER"; rsf_categories | tr "\n" " "')"
assert_eq "$got" "ok|tests|by-target|on|off|hooks bin "
got="$(rsf "$R_MISSING" 'rsf_load "$2"; printf "%s" "$RSF_TESTS_STATE"')"
assert_eq "missing: $got" "missing: missing"
got="$(rsf "$R_BAD" 'rsf_load "$2"; printf "%s" "$RSF_TESTS_STATE"')"
assert_eq "malformed: $got" "malformed: malformed"
got="$(rsf "$(np "$SCRIPT_CHECKOUT_ROOT")" 'rsf_load "$2"; printf "%s|" "$RSF_TESTS_STATE" "$RSF_CATEGORIZATION"; rsf_categories | sort | tr "\n" " "')"
assert_eq "agents: $got" "agents: ok|by-target|agents bin hooks install skills tests "
case_end

case_begin "LOADER-one-call-per-root" "bin/lib/repo-settings.sh"
SHIM="$TMPBASE/shim"
mkdir -p "$SHIM"
COUNT="$TMPBASE/node-calls"
: >"$COUNT"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\nexec "%s" "$@"\n' "$COUNT" "$REAL_NODE" >"$SHIM/node"
chmod +x "$SHIM/node"
got="$(PATH="$SHIM:$PATH" rsf "$R_OK" 'rsf_load "$2"; rsf_load "$2"; rsf_load "$2"; printf "%s" "$RSF_TESTS_STATE"')"
assert_eq "three loads, same root: $got calls=$(grep -c . "$COUNT")" "three loads, same root: ok calls=1"
: >"$COUNT"
got="$(PATH="$SHIM:$PATH" rsf "$R_OK" 'rsf_load "$2"; rsf_load "$3"; rsf_load "$2"; printf "%s" "$RSF_TESTS_STATE"' "$R_MISSING")"
# The second root replaces the cached one, so going back reads again: 3 calls at most, 2 at least.
n="$(grep -c . "$COUNT")"
if [ "$got" = "ok" ] && [ "$n" -ge 2 ] && [ "$n" -le 3 ]; then
  pass "another root is read again and the last root wins (calls=$n)"
else
  fail "another root is read again and the last root wins" "state=$got calls=$n"
fi
case_end

# --reset-malformed (standalone; only --root may accompany it): a file that is not JSON or not an
# object is copied byte for byte to .agents.json.malformed, then replaced by `{}` + newline.
FLAT_TESTS='{"categorization":"flat","testHarness":"off","caseMarker":"off"}'
# snap <root> — keep the current .agents.json bytes for a later byte comparison (sets SNAP).
snap() {
  SNAP="$TMPBASE/snap-$(basename "$1")"
  cp "$1/.agents.json" "$SNAP"
}
same_bytes() { cmp -s "$1" "$2" && echo yes || echo no; }
exists() { [[ -e "$1" ]] && echo exists || echo absent; }
# cli_split <args...> — like cli, but keeps stderr apart (sets CLI_RC / CLI_STDOUT / CLI_STDERR).
cli_split() {
  local errf="$TMPBASE/cli-stderr"
  CLI_STDOUT="$(run_with_timeout 60 node "$(np "$CLI")" "$@" 2>"$errf")"
  CLI_RC=$?
  CLI_STDERR="$(cat "$errf")"
}
# reset_ok <label> <root> — assert a reset of a malformed file: rc 0, backup = SNAP, file = `{}`\n,
# exactly one stderr line, and it names the backup.
reset_ok() {
  local label="$1" root="$2"
  cli_split --root "$root" --reset-malformed
  assert_eq "$label rc=$CLI_RC" "$label rc=0"
  assert_eq "$label backup is the original bytes: $(same_bytes "$SNAP" "$root/.agents.json.malformed")" "$label backup is the original bytes: yes"
  printf '{}\n' >"$TMPBASE/empty-object"
  assert_eq "$label file is {} + newline: $(same_bytes "$TMPBASE/empty-object" "$root/.agents.json")" "$label file is {} + newline: yes"
  assert_eq "$label stderr lines=$(printf '%s' "$CLI_STDERR" | grep -c .)" "$label stderr lines=1"
  assert_eq "$label stderr names the backup=$(printf '%s' "$CLI_STDERR" | grep -c '\.agents\.json\.malformed')" "$label stderr names the backup=1"
}

case_begin "CLI-reset-malformed-not-json" "bin/repo-settings"
R_RM="$(fx rm-notjson '{ not json')"
snap "$R_RM"
head_before="$(git -C "$R_RM" rev-parse HEAD)"
reset_ok "not-JSON" "$R_RM"
assert_eq "no commit: $(git -C "$R_RM" rev-parse HEAD)" "no commit: $head_before"
cli --root "$R_RM" --write-tests "$FLAT_TESTS"
assert_eq "a write after the reset succeeds rc=$CLI_RC" "a write after the reset succeeds rc=0"
case_end

case_begin "CLI-reset-malformed-non-object" "bin/repo-settings"
while IFS='|' read -r name content; do
  [[ -z "$name" ]] && continue
  root="$(fx "rm-nonobj-$name" "$content")"
  snap "$root"
  reset_ok "$name" "$root"
done <<'TABLE'
array|[]
string|"x"
null|null
number|42
TABLE
case_end

case_begin "CLI-malformed-without-reset-flag-writes-nothing" "bin/repo-settings"
while IFS='|' read -r name content; do
  [[ -z "$name" ]] && continue
  root="$(fx "rm-noflag-$name" "$content")"
  snap "$root"
  cli_split --root "$root" --write-tests "$FLAT_TESTS"
  assert_eq "$name write-tests rc=$CLI_RC" "$name write-tests rc=1"
  assert_eq "$name write-tests file unchanged: $(same_bytes "$SNAP" "$root/.agents.json")" "$name write-tests file unchanged: yes"
  assert_eq "$name write-tests no backup: $(exists "$root/.agents.json.malformed")" "$name write-tests no backup: absent"
  assert_eq "$name write-tests stderr names --reset-malformed=$(printf '%s' "$CLI_STDERR" | grep -c -- '--reset-malformed')" "$name write-tests stderr names --reset-malformed=1"
  cli_split --root "$root" --set-migrate tracker
  assert_eq "$name set-migrate rc=$CLI_RC" "$name set-migrate rc=1"
  assert_eq "$name set-migrate leaves it: $(same_bytes "$SNAP" "$root/.agents.json")|$(exists "$root/.agents.json.malformed")" "$name set-migrate leaves it: yes|absent"
  assert_eq "$name set-migrate stderr names --reset-malformed=$(printf '%s' "$CLI_STDERR" | grep -c -- '--reset-malformed')" "$name set-migrate stderr names --reset-malformed=1"
done <<'TABLE'
notjson|{ not json
array|[]
TABLE
case_end

case_begin "CLI-reset-malformed-valid-object-untouched" "bin/repo-settings"
R_RV="$(fx rm-valid '{"migrate":{"tracker":"done"},"other":1}')"
snap "$R_RV"
cli --root "$R_RV" --reset-malformed
assert_eq "valid object rc=$CLI_RC" "valid object rc=0"
assert_eq "file untouched: $(same_bytes "$SNAP" "$R_RV/.agents.json")" "file untouched: yes"
assert_eq "no backup: $(exists "$R_RV/.agents.json.malformed")" "no backup: absent"
case_end

case_begin "CLI-reset-malformed-absent-creates-nothing" "bin/repo-settings"
R_RA="$(fx rm-absent)"
cli --root "$R_RA" --reset-malformed
assert_eq "absent file rc=$CLI_RC" "absent file rc=0"
assert_eq "nothing created: $(exists "$R_RA/.agents.json")|$(exists "$R_RA/.agents.json.malformed")" "nothing created: absent|absent"
case_end

case_begin "CLI-reset-malformed-overwrites-old-backup" "bin/repo-settings"
R_RO="$(fx rm-oldbackup '[1,2]')"
printf 'OLD BACKUP LINE 1\nOLD BACKUP LINE 2 that is longer than the new original\n' >"$R_RO/.agents.json.malformed"
snap "$R_RO"
cli --root "$R_RO" --reset-malformed
assert_eq "rc=$CLI_RC" "rc=0"
assert_eq "backup replaced, not appended: $(same_bytes "$SNAP" "$R_RO/.agents.json.malformed")" "backup replaced, not appended: yes"
case_end

# Table: name | args (ROOT = a fresh fixture holding OK_JSON; TESTS = FLAT_TESTS) | want rc. Every row
# leaves .agents.json untouched and creates no backup (ROOT is valid); rc=2 rows print the usage line.
case_begin "CLI-reset-malformed-arg-table" "bin/repo-settings"
while IFS='|' read -r name args want; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"
  want="${want//[[:space:]]/}"
  root="$(fx "rmargs-$name" "$OK_JSON")"
  before="$(cat "$root/.agents.json")"
  read -r -a argv <<<"$args"
  for i in "${!argv[@]}"; do
    [[ "${argv[$i]}" == "ROOT" ]] && argv[$i]="$root"
    [[ "${argv[$i]}" == "TESTS" ]] && argv[$i]="$FLAT_TESTS"
  done
  cli "${argv[@]}"
  assert_eq "$name rc=$CLI_RC" "$name rc=$want"
  assert_eq "$name no backup: $(exists "$root/.agents.json.malformed")" "$name no backup: absent"
  assert_eq "$name unchanged=$([[ "$(cat "$root/.agents.json")" == "$before" ]] && echo yes || echo no)" "$name unchanged=yes"
  if [[ "$want" == "2" ]]; then
    assert_eq "$name usage=$(printf '%s\n' "$CLI_OUT" | grep -c '^usage: repo-settings')" "$name usage=1"
  fi
done <<'TABLE'
reset-root-last          | --root ROOT --reset-malformed                             | 0
reset-root-first         | --reset-malformed --root ROOT                             | 0
reset-with-format        | --root ROOT --format json --reset-malformed               | 2
reset-with-format-shell  | --root ROOT --reset-malformed --format shell              | 2
reset-with-set-migrate   | --root ROOT --set-migrate tracker --reset-malformed       | 2
reset-with-write-tests   | --root ROOT --write-tests TESTS --reset-malformed         | 2
reset-before-write-tests | --root ROOT --reset-malformed --write-tests TESTS         | 2
reset-given-a-value      | --root ROOT --reset-malformed yes                         | 2
replace-removed-alone    | --root ROOT --replace-malformed                           | 2
replace-removed-write    | --root ROOT --write-tests TESTS --replace-malformed       | 2
TABLE
case_end

# Schema version (same contract as the workflow state file): a version above MAX_KNOWN (1) is
# unsupported — read exits non-zero, every write and --reset-malformed leave the file alone.
V2_JSON='{"version":2,"tests":{"categorization":"flat","testHarness":"off","caseMarker":"off"},"migrate":{"tracker":"done"}}'

case_begin "CLI-version-newer-read" "bin/repo-settings"
R_V2R="$(fx v2-read "$V2_JSON")"
cli --root "$R_V2R" --format shell
assert_eq "v2 read rc!=0: $([[ "$CLI_RC" -ne 0 ]] && echo yes || echo no)" "v2 read rc!=0: yes"
assert_eq "v2 tests_state=$(printf '%s\n' "$CLI_OUT" | grep -c $'^tests_state\tunsupported$')" "v2 tests_state=1"
assert_eq "v2 migrate_state=$(printf '%s\n' "$CLI_OUT" | grep -c $'^migrate_state\tunsupported$')" "v2 migrate_state=1"
assert_eq "v2 error line=$(printf '%s\n' "$CLI_OUT" | grep -c $'^error\ttests\t.*newer than this release understands (max known 1)')" "v2 error line=1"
case_end

case_begin "CLI-version-newer-write-refused" "bin/repo-settings"
while IFS='|' read -r name flag value; do
  [[ -z "$name" ]] && continue
  root="$(fx "v2-write-$name" "$V2_JSON")"
  snap "$root"
  cli_split --root "$root" "$flag" "$value"
  assert_eq "$name refused: $([[ "$CLI_RC" -ne 0 ]] && echo yes || echo no)" "$name refused: yes"
  assert_eq "$name file unchanged: $(same_bytes "$SNAP" "$root/.agents.json")" "$name file unchanged: yes"
done <<TABLE
write-tests|--write-tests|$FLAT_TESTS
set-migrate|--set-migrate|issues
TABLE
case_end

case_begin "CLI-version-newer-not-reset" "bin/repo-settings"
R_V2X="$(fx v2-reset "$V2_JSON")"
snap "$R_V2X"
cli --root "$R_V2X" --reset-malformed
assert_eq "v2 reset file unchanged: $(same_bytes "$SNAP" "$R_V2X/.agents.json")" "v2 reset file unchanged: yes"
assert_eq "v2 reset no backup: $(exists "$R_V2X/.agents.json.malformed")" "v2 reset no backup: absent"
case_end

# first_key <root> — "<first top-level key>|<version>" of <root>/.agents.json.
first_key() { json_field "$(cat "$1/.agents.json" 2>/dev/null)" 'Object.keys(d)[0] + "|" + d.version'; }

case_begin "CLI-version-written-first" "bin/repo-settings"
R_V1A="$(fx v1-add '{"migrate":{"tracker":"done"},"other":1}')"
cli --root "$R_V1A" --write-tests "$FLAT_TESTS"
assert_eq "write-tests rc=$CLI_RC" "write-tests rc=0"
assert_eq "write-tests first key: $(first_key "$R_V1A")" "write-tests first key: version|1"
got="$(json_field "$(cat "$R_V1A/.agents.json")" 'd.migrate.tracker + "|" + d.other + "|" + d.tests.categorization')"
assert_eq "other content kept: $got" "other content kept: done|1|flat"
R_V1B="$(fx v1-setmig '{"tests":{"categorization":"flat","testHarness":"off","caseMarker":"off"}}')"
cli --root "$R_V1B" --set-migrate tracker
assert_eq "set-migrate rc=$CLI_RC" "set-migrate rc=0"
assert_eq "set-migrate first key: $(first_key "$R_V1B")" "set-migrate first key: version|1"
R_V1C="$(fx v1-new)"
cli --root "$R_V1C" --set-migrate issues
assert_eq "new file rc=$CLI_RC" "new file rc=0"
assert_eq "new file first key: $(first_key "$R_V1C")" "new file first key: version|1"
case_end

case_begin "LOADER-version-newer" "bin/lib/repo-settings.sh"
got="$(rsf "$R_V2R" 'rsf_load "$2"; printf "%s|%s" "$RSF_TESTS_STATE" "$RSF_MIGRATE_STATE"')"
assert_eq "loader v2: $got" "loader v2: unsupported|unsupported"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
