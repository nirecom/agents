#!/usr/bin/env bash
# Tests: skills/review-tests/scripts/check-heavy-tests.sh
# Tags: TL2, scope:issue-specific, review-tests, heavy, durations, ledger
# #2932 RT-1c gate: staged tests -> dispatcher (fragments dedupe) -> thj_judge -> HEAVY lines;
# no ledger -> exactly `HEAVY-SKIP: reason=missing`, exit 0. Interface assumed by this test:
# `bash check-heavy-tests.sh --root <repo>` with CWD = <repo>, reading the repo's staged paths.
# TL3 gap (what this test does NOT catch): a real ~/.claude/run-all ledger grown by real runs
# on a real host; the codex-free RT-5c counting itself is static-checked in main-review-tests.sh.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$ROOT/tests/lib/harness.sh"
SCRIPT="$ROOT/skills/review-tests/scripts/check-heavy-tests.sh"

CH_TMP="$(make_tmp)"
readonly CH_TMP
trap 'rm -rf "$CH_TMP"' EXIT
mkdir -p "$CH_TMP/home"
export HOME="$CH_TMP/home"
harness_isolate "$CH_TMP/state"
unset CLAUDE_CODE_SESSION_ID RUN_ALL_DUR_REPO_ID RUN_ALL_DUR_HOST_TOKEN

# ch_stamp <minutes-ago> — a segment stamp inside every retention window (never a fixed date).
ch_stamp() {
  local t=$(( $(date -u +%s) - $1 * 60 ))
  date -u -d "@$t" +%Y%m%dT%H%M%S 2>/dev/null || date -u -r "$t" +%Y%m%dT%H%M%S
}

# ch_repo — a fixture repo with a dispatcher + 2 fragments, a WARN-sized test, a quiet one, a tool.
ch_repo() {
  local r; r="$(mktemp -d -p "$CH_TMP")"
  harness_git_init "$r"
  git -C "$r" config user.email t@example.com
  git -C "$r" config user.name t
  mkdir -p "$r/tests/bin/foo" "$r/bin"
  for f in tests/bin/foo.sh tests/bin/foo/a.sh tests/bin/foo/b.sh tests/bin/bar.sh tests/bin/quiet.sh tests/bin/fresh.sh bin/tool.sh; do
    printf '#!/usr/bin/env bash\n# Tests: bin/tool.sh\n# Tags: TL2, scope:common\necho %s\n' "$f" >"$r/$f"
  done
  git -C "$r" add -A >/dev/null 2>&1
  git -C "$r" commit -q --no-verify -m init >/dev/null 2>&1
  printf '%s\n' "$r"
}

# ch_plant <repo> <cache> <secs:key>... — 3 PASS|completed samples per key (v3 rows, #os header).
ch_plant() {
  local repo="$1" cache="$2"
  shift 2
  (
    export RUN_ALL_CACHE_DIR="$cache"
    # shellcheck source=../../bin/lib/run-all-parallelism.sh
    . "$ROOT/bin/lib/run-all-parallelism.sh"
    # shellcheck source=../../bin/lib/run-all-durations.sh
    . "$ROOT/bin/lib/run-all-durations.sh"
    run_all_dur_repo_id "$repo" >/dev/null
    run_all_dur_host_token >/dev/null
    dir="$(run_all_dur_dir)"
    mkdir -p "$dir"
    for i in 1 2 3; do
      seg="$dir/dur.3.$RUN_ALL_DUR_HOST_TOKEN.$(ch_stamp $((i * 10)))-1.log"
      printf '#os %s\n' "$RUN_ALL_DUR_OS_ATTR" >"$seg"
      for kv in "$@"; do
        printf '%s|%s|PASS|completed|%s\n' "$RUN_ALL_DUR_REPO_ID" "${kv%%:*}" "${kv#*:}" >>"$seg"
      done
    done
  )
}

# ch_host <cache> — the host token the judge reports for this host.
ch_host() {
  (
    export RUN_ALL_CACHE_DIR="$1"
    . "$ROOT/bin/lib/run-all-parallelism.sh"
    . "$ROOT/bin/lib/run-all-durations.sh"
    run_all_dur_host_token
  )
}

# ch_run <repo> <cache> <staged-path>... — stage exactly these paths, run the gate; OUT / RC.
ch_run() {
  local repo="$1" cache="$2"
  shift 2
  git -C "$repo" reset -q >/dev/null 2>&1
  for p in "$@"; do printf 'echo edit\n' >>"$repo/$p"; git -C "$repo" add -- "$p"; done
  ch_gate "$repo" "$cache" --root "$repo"
}

# ch_gate <repo> <cache> <arg>... — run the gate in <repo> with these arguments; OUT / RC / ERR.
ch_gate() {
  local repo="$1" cache="$2"
  shift 2
  OUT="$(cd "$repo" && RUN_ALL_CACHE_DIR="$cache" run_with_timeout 120 bash "$SCRIPT" "$@" 2>"$CH_TMP/err")"
  RC=$?
  ERR="$(cat "$CH_TMP/err")"
}

# ch_edit_run <repo> <cache> <op:path:n>... — from a clean HEAD, stage each edit, run the gate.
# keep:<p>:<n> keeps the first n lines (deletions only); add:<p>:<n> appends n lines;
# swap:<p>:1 rewrites the last line (one deletion, one addition). Fixture files have 4 lines.
ch_edit_run() {
  local repo="$1" cache="$2" spec op p n i
  shift 2
  git -C "$repo" reset -q --hard >/dev/null 2>&1
  for spec in "$@"; do
    op="${spec%%:*}"; p="${spec#*:}"; n="${p##*:}"; p="${p%:*}"
    case "$op" in
      keep) head -n "$n" "$repo/$p" >"$CH_TMP/edit"; cat "$CH_TMP/edit" >"$repo/$p" ;;
      add) for ((i = 0; i < n; i++)); do printf 'echo add%s\n' "$i" >>"$repo/$p"; done ;;
      swap) sed '$d' "$repo/$p" >"$CH_TMP/edit"; printf 'echo swapped\n' >>"$CH_TMP/edit"; cat "$CH_TMP/edit" >"$repo/$p" ;;
    esac
    git -C "$repo" add -- "$p"
  done
  ch_gate "$repo" "$cache" --root "$repo"
}

# ch_shrinks <path> — the shrinks= value of that path's HEAVY line (empty when there is none).
ch_shrinks() { printf '%s\n' "$OUT" | awk -v p="$1" '$1 == "HEAVY:" && $2 == p { sub(/.* shrinks=/, ""); print; exit }'; }

# ck <name> <want> <got>
ck() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=[$2] got=[$3]"; fi; }
ch_lines() { printf '%s\n' "$OUT" | grep -c "^HEAVY: $1 " || true; }

REPO="$(ch_repo)"
CACHE="$CH_TMP/cache-ledger"
ch_plant "$REPO" "$CACHE" 200:tests/bin/foo.sh 100:tests/bin/bar.sh 5:tests/bin/quiet.sh 200:bin/tool.sh
HOST="$(ch_host "$CACHE")"

case_begin "fragments-map-to-dispatcher-once" "skills/review-tests/scripts/check-heavy-tests.sh"
ch_run "$REPO" "$CACHE" tests/bin/foo/a.sh tests/bin/foo/b.sh
ck "CH1 gate exits 0 (err=${ERR:0:200})" "0" "$RC"
ck "CH1 two fragments yield the dispatcher line exactly once (out=${OUT:0:300})" "1" "$(ch_lines tests/bin/foo.sh)"
ck "CH1 no fragment path is reported itself" "0" "$(printf '%s\n' "$OUT" | grep -c '^HEAVY: tests/bin/foo/' || true)"
case_end

case_begin "hard-dispatcher-line" "skills/review-tests/scripts/check-heavy-tests.sh"
ch_run "$REPO" "$CACHE" tests/bin/foo/a.sh tests/bin/foo/b.sh
if printf '%s\n' "$OUT" | grep -qxF "HEAVY: tests/bin/foo.sh tier=HARD basis=median samples=3 median=200 host=$HOST shrinks=no"; then
  pass "CH2 a HARD dispatcher prints its tier/basis/samples/median/host line"
else
  fail "CH2 a HARD dispatcher prints its tier/basis/samples/median/host line" "out=${OUT:0:400} err=${ERR:0:200}"
fi
case_end

case_begin "warn-test-line" "skills/review-tests/scripts/check-heavy-tests.sh"
ch_run "$REPO" "$CACHE" tests/bin/bar.sh tests/bin/quiet.sh
if printf '%s\n' "$OUT" | grep -qxF "HEAVY: tests/bin/bar.sh tier=WARN basis=median samples=3 median=100 host=$HOST shrinks=no"; then
  pass "CH3 a WARN test prints its line"
else
  fail "CH3 a WARN test prints its line" "out=${OUT:0:400} err=${ERR:0:200}"
fi
ck "CH3 a tier '-' test prints no HEAVY line" "0" "$(ch_lines tests/bin/quiet.sh)"
case_end

case_begin "missing-ledger-skip" "skills/review-tests/scripts/check-heavy-tests.sh"
EMPTY="$CH_TMP/cache-empty"
mkdir -p "$EMPTY"
ch_run "$REPO" "$EMPTY" tests/bin/foo/a.sh tests/bin/bar.sh
ck "CH4 no ledger exits 0 (err=${ERR:0:200})" "0" "$RC"
ck "CH4 no ledger prints exactly the HEAVY-SKIP line" "HEAVY-SKIP: reason=missing" "$OUT"
case_end

case_begin "unknown-tier-emits-no-heavy-line" "skills/review-tests/scripts/check-heavy-tests.sh"
ch_run "$REPO" "$CACHE" tests/bin/fresh.sh
ck "CH6 gate exits 0 (err=${ERR:0:200})" "0" "$RC"
ck "CH6 a staged test with no series (tier ?) prints no HEAVY line (out=${OUT:0:300})" "0" "$(printf '%s\n' "$OUT" | grep -c '^HEAVY' || true)"
case_end

case_begin "unreadable-ledger-skip" "skills/review-tests/scripts/check-heavy-tests.sh"
FAILBIN="$CH_TMP/failbin"
mkdir -p "$FAILBIN"
printf '#!/bin/sh\nexit 1\n' >"$FAILBIN/node"
chmod +x "$FAILBIN/node"
_save_path="$PATH"
export PATH="$FAILBIN:$PATH"
ch_run "$REPO" "$CACHE" tests/bin/foo/a.sh tests/bin/bar.sh
export PATH="$_save_path"
ck "CH7 an unreadable ledger exits 0 (err=${ERR:0:200})" "0" "$RC"
ck "CH7 an unreadable ledger prints exactly one HEAVY-SKIP line" "HEAVY-SKIP: reason=unreadable" "$OUT"
case_end

case_begin "non-test-staged-ignored" "skills/review-tests/scripts/check-heavy-tests.sh"
ch_run "$REPO" "$CACHE" bin/tool.sh tests/bin/bar.sh
ck "CH5 gate exits 0 (err=${ERR:0:200})" "0" "$RC"
ck "CH5 a staged non-test file is ignored even with a HARD ledger row" "0" "$(printf '%s\n' "$OUT" | grep -c 'bin/tool.sh' || true)"
ck "CH5 the staged test beside it is still judged (out=${OUT:0:300})" "1" "$(ch_lines tests/bin/bar.sh)"
case_end

case_begin "shrinks-deleted-over-added" "skills/review-tests/scripts/check-heavy-tests.sh"
ch_edit_run "$REPO" "$CACHE" keep:tests/bin/bar.sh:2
ck "CH8 two deleted, none added: shrinks=yes (out=${OUT:0:300} err=${ERR:0:200})" "yes" "$(ch_shrinks tests/bin/bar.sh)"
ch_edit_run "$REPO" "$CACHE" swap:tests/bin/bar.sh:1
ck "CH8 one deleted, one added (equal): shrinks=no (out=${OUT:0:300})" "no" "$(ch_shrinks tests/bin/bar.sh)"
ch_edit_run "$REPO" "$CACHE" keep:tests/bin/bar.sh:3 add:tests/bin/bar.sh:2
ck "CH8 one deleted, two added: shrinks=no (out=${OUT:0:300})" "no" "$(ch_shrinks tests/bin/bar.sh)"
case_end

case_begin "shrinks-counts-the-fragment-folder" "skills/review-tests/scripts/check-heavy-tests.sh"
ch_edit_run "$REPO" "$CACHE" keep:tests/bin/foo/a.sh:1
ck "CH9 a fragment-only deletion shrinks its dispatcher (out=${OUT:0:300} err=${ERR:0:200})" "yes" "$(ch_shrinks tests/bin/foo.sh)"
ch_edit_run "$REPO" "$CACHE" add:tests/bin/foo.sh:2 keep:tests/bin/foo/a.sh:1
ck "CH9 dispatcher +2 with fragment -3 sums to shrinks=yes (out=${OUT:0:300})" "yes" "$(ch_shrinks tests/bin/foo.sh)"
ck "CH9 the summed pair still yields one dispatcher line" "1" "$(ch_lines tests/bin/foo.sh)"
ch_edit_run "$REPO" "$CACHE" add:tests/bin/foo.sh:3 keep:tests/bin/foo/a.sh:2
ck "CH9 dispatcher +3 with fragment -2 sums to shrinks=no (out=${OUT:0:300})" "no" "$(ch_shrinks tests/bin/foo.sh)"
case_end

case_begin "usage-errors-exit-2" "skills/review-tests/scripts/check-heavy-tests.sh"
ch_gate "$REPO" "$CACHE" --root
ck "CH10 --root without a value exits 2" "2" "$RC"
ck "CH10 --root without a value says so on stderr (err=${ERR:0:200})" "1" "$(printf '%s\n' "$ERR" | grep -c -- '--root requires a value' || true)"
ck "CH10 --root without a value prints nothing on stdout" "" "$OUT"
ch_gate "$REPO" "$CACHE" --bogus
ck "CH10 an unknown option exits 2" "2" "$RC"
ck "CH10 an unknown option is named on stderr (err=${ERR:0:200})" "1" "$(printf '%s\n' "$ERR" | grep -c -- 'unknown option: --bogus' || true)"
ck "CH10 an unknown option prints nothing on stdout" "" "$OUT"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
