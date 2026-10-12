#!/usr/bin/env bash
# Tests: tests/fixtures/spawn-record-preload.js, tests/lib/spawn-record.sh
# Tags: scope:issue-specific, tl2, spawn-record, fixture-isolation
#
# The spawn-record preload (#2590) covers the whole child_process family and holds every network
# command, prefixed forms included. Proof of "held" is a PATH stub gh / glab that logs each start.

# TL3 gap: cmd.exe as the exec shell is not exercised; the shell forms run under bash.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/cli-stub.sh"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/state"
unset CLAUDE_CODE_SESSION_ID

expect_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=$3 got=$2"; fi; }
expect_has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing: $3 in: $2" ;; esac; }
lines() { if [[ -f "$1" ]]; then grep -c . "$1" || true; else echo 0; fi; }

PRELOAD="$(np "$SCRIPT_CHECKOUT_ROOT/tests/fixtures/spawn-record-preload.js")"
DRIVER="$(np "$SCRIPT_CHECKOUT_ROOT/tests/tests/feature-2590-spawn-record-family/driver.js")"
NODE_REAL="$(node -p 'process.execPath')"
mkdir -p "$TMP_ROOT/node only"
cp "$NODE_REAL" "$TMP_ROOT/node only/" || { echo "cannot copy node" >&2; exit 1; }
SR_NODE="$(np "$TMP_ROOT/node only/${NODE_REAL##*[/\\]}")"
SR_BASH="$(np "$(command -v bash)")"
cli_stub_make "$TMP_ROOT/stub" gh glab || { echo "cannot build the gh / glab stubs" >&2; exit 1; }

# PATH for every child: the stubs, then PATH without any dir that holds a real gh / glab / codex.
SAFE_PATH="$CLI_STUB_DIR"
IFS=: read -r -a PARTS <<<"$PATH"
for d in "${PARTS[@]}"; do
  [[ -n "$d" && -d "$d" ]] || continue
  keep=1
  for t in gh gh.exe glab glab.exe codex codex.exe codex.cmd; do [[ -e "$d/$t" ]] && keep=0; done
  [[ "$keep" -eq 1 ]] && SAFE_PATH="$SAFE_PATH:$d"
done
[[ "$(PATH="$SAFE_PATH" command -v gh)" == "$CLI_STUB_DIR/gh"* ]] || { echo "the stub gh is not first on PATH" >&2; exit 1; }

# sr <out> <shape> [text] [VAR=value...] — the driver under the preload; prints its markers.
# A started stub appends "<name> <args>" to $STUB_LOG.
STUB_LOG="$TMP_ROOT/stub.log"
sr() {
  local out="$1" shape="$2" text="${3:-}"
  shift 3 2>/dev/null || shift $#
  (cd "$TMP_ROOT" && env PATH="$SAFE_PATH" NODE_OPTIONS="--require \"$CLI_STUB_PRELOAD\"" CLI_STUB_LOG="$STUB_LOG" \
    CLI_STUB_OUT=STUB-RAN SPAWN_RECORD_OUT="$(np "$out")" SR_BASH="$SR_BASH" SR_NODE="$SR_NODE" "$@" \
    bash "$RWT" 60 "$SR_NODE" -r "$PRELOAD" "$DRIVER" "$shape" "$text" 2>&1)
}

case_begin "each-spawn-function-records-once" "tests/fixtures/spawn-record-preload.js"
for fn in spawn exec execFile execSync execFileSync fork; do
  OUT="$(sr "$TMP_ROOT/fam-$fn.jsonl" "$fn")"
  expect_eq "$fn records exactly one entry" "$(lines "$TMP_ROOT/fam-$fn.jsonl")" "1"
  case "$fn" in
    spawn|fork) expect_has "$fn still delivers its exit event" "$OUT" "EXIT:0" ;;
    exec|execFile) expect_has "$fn still calls back" "$OUT" "CB" ;;
    *) expect_has "$fn still returns" "$OUT" "DONE" ;;
  esac
done
case_end

# held_case <label> <shape> <text> <stub name> — one record, held, and the stub never started.
held_case() {
  local out="$TMP_ROOT/held-$RANDOM$RANDOM.jsonl" before after text
  before="$(lines "$STUB_LOG")"
  text="$(sr "$out" "$2" "$3")"
  after="$(lines "$STUB_LOG")"
  expect_eq "$1: the stub $4 never started" "$after" "$before"
  expect_eq "$1: recorded as held" "$(grep -c '"held":true' "$out" 2>/dev/null || true)" "1"
  HELD_TEXT="$text"
}

case_begin "network-commands-are-held-in-every-prefixed-form" "tests/fixtures/spawn-record-preload.js"
held_case "execFileSync gh" execFileSync-gh "" gh
held_case "GH_TOKEN=x gh" exec-text "GH_TOKEN=x gh api repos/x/y" gh
held_case "env -u X GH_TOKEN=y glab" execSync-text "env -u X GH_TOKEN=y glab api projects" glab
held_case "env -i PATH=... gh" exec-text 'env -i PATH="$PATH" NODE_OPTIONS="$NODE_OPTIONS" CLI_STUB_LOG="$CLI_STUB_LOG" gh api repos/x/y' gh
held_case "a && gh" exec-text "true && gh api repos/x/y" gh
held_case "bash -c \"gh ...\"" spawn-shell-text "bash -c \"gh api repos/x/y\"" gh
held_case "spawn('env', ['X=1', 'gh'])" spawn-env-argv "" gh
case_end

case_begin "held-async-calls-still-complete" "tests/fixtures/spawn-record-preload.js"
held_case "exec gh" exec-text "gh api repos/x/y" gh
expect_has "exec gh: the callback arrives without an error" "$HELD_TEXT" "CB:ok:"
held_case "spawn bash -c gh" spawn-shell-text "gh api repos/x/y" gh
expect_has "spawn gh: the exit event arrives" "$HELD_TEXT" "EXIT:0"
expect_has "spawn gh: the close event arrives" "$HELD_TEXT" "CLOSE"
case_end

case_begin "execfile-fork-and-spawnsync-hold-gh-and-glab" "tests/fixtures/spawn-record-preload.js"
for tool in gh glab; do
  held_case "execFile $tool" execFile-net "$tool" "$tool"
  expect_has "execFile $tool: the callback arrives" "$HELD_TEXT" "CB:"
  held_case "spawnSync $tool" spawnSync-net "$tool" "$tool"
  expect_has "spawnSync $tool: the caller returns" "$HELD_TEXT" "DONE"
  held_case "fork, then $tool in the child" fork-net "$tool" "$tool"
  expect_has "fork $tool: the child's callback arrives" "$HELD_TEXT" "CB:"
  expect_has "fork $tool: the fork exits 0" "$HELD_TEXT" "EXIT:0"
done
case_end

case_begin "a-network-word-outside-the-command-position-is-not-held" "tests/fixtures/spawn-record-preload.js"
OUT="$(sr "$TMP_ROOT/echo.jsonl" exec-text "echo gh")"
expect_eq "echo gh: recorded once" "$(lines "$TMP_ROOT/echo.jsonl")" "1"
expect_eq "echo gh: not held" "$(grep -c '"held":false' "$TMP_ROOT/echo.jsonl" 2>/dev/null || true)" "1"
expect_has "echo gh: really ran" "$OUT" "CB:ok:gh"
case_end

case_begin "expect-count-mismatch-fails-the-process" "tests/fixtures/spawn-record-preload.js"
sr "$TMP_ROOT/count-ok.jsonl" spawnSync-node "" SPAWN_RECORD_EXPECT_COUNT=1 >/dev/null
expect_eq "a matching count exits 0" "$?" "0"
MISMATCH="$(sr "$TMP_ROOT/count-bad.jsonl" spawnSync-node "" SPAWN_RECORD_EXPECT_COUNT=2)"
MISMATCH_RC=$?
expect_eq "a mismatching count exits non-zero" "$([[ "$MISMATCH_RC" -ne 0 ]] && echo nonzero)" "nonzero"
expect_has "the mismatch is explained on one line" "$MISMATCH" "SPAWN_RECORD_EXPECT_COUNT"
case_end

case_begin "spawn-record-count-counts-entries" "tests/lib/spawn-record.sh"
COUNTS="$TMP_ROOT/counts.jsonl"
printf '%s\n' '{"held":true,"command":"gh","cmd":"gh","args":["api"]}' '{"held":true,"command":"gh","cmd":"gh","args":["pr"]}' \
  '{"held":false,"command":"git","cmd":"git","args":["status"]}' >"$COUNTS"
COUNT_OUT="$(bash -c 'source "$1/tests/lib/spawn-record.sh" || exit 90; printf "ALL=%s GH=%s GIT=%s NONE=%s EMPTY=%s\n" "$(spawn_record_count "$2")" "$(spawn_record_count "$2" gh)" "$(spawn_record_count "$2" git)" "$(spawn_record_count "$2" glab)" "$(spawn_record_count "$3")"' _ "$SCRIPT_CHECKOUT_ROOT" "$COUNTS" "$TMP_ROOT/absent.jsonl" 2>&1)"
expect_eq "all entries, per command, none, and an absent file" "$COUNT_OUT" "ALL=3 GH=2 GIT=1 NONE=0 EMPTY=0"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
