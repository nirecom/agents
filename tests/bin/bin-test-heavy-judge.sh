#!/usr/bin/env bash
# tests/bin/bin-test-heavy-judge.sh
# Tests: bin/lib/test-heavy-judge.sh
# Tags: TL2, scope:issue-specific, heavy-judge, ledger, durations, test-time
# TL3 gap (what this test does NOT catch):
# - a real ledger grown by many run-all invocations rather than planted v3 segments
# - an awk other than this host's (the POSIX subset is assumed, not proven)
# Closest-to-action mitigation: none needed — a read-only classification, fail-soft on any error.
set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

ROOT="$(make_tmp)"
readonly ROOT
trap 'rm -rf "$ROOT"' EXIT
harness_isolate "$ROOT/iso"
unset CLAUDE_CODE_SESSION_ID
export HOME="$ROOT/home" NO_LOG=true RUN_ALL_CACHE_DIR="$ROOT/cache"
mkdir -p "$HOME" "$RUN_ALL_CACHE_DIR"

JUDGE_REL="bin/lib/test-heavy-judge.sh"
. "$SCRIPT_CHECKOUT_ROOT/bin/lib/run-all-parallelism.sh"
. "$SCRIPT_CHECKOUT_ROOT/bin/lib/run-all-durations.sh"
[ -f "$SCRIPT_CHECKOUT_ROOT/$JUDGE_REL" ] && . "$SCRIPT_CHECKOUT_ROOT/$JUDGE_REL"

REPO="$ROOT/repo"
harness_git_init "$REPO"
cd "$REPO" || exit 1
# Primed after every source, so the judge reuses the memoised identity of the fixture repo.
run_all_dur_repo_id "$REPO" >/dev/null
run_all_dur_host_token >/dev/null
RID="$RUN_ALL_DUR_REPO_ID"
TOK="$RUN_ALL_DUR_HOST_TOKEN"
OSA="${RUN_ALL_DUR_OS_ATTR:-fixture}"
OTHER_RID="$(run_all_dur_pad16 "foreignrepo${RID}")"
OTHER_TOK="$(run_all_dur_pad16 "foreignhost${TOK}")"
LEDGER="$(run_all_dur_dir)"
OUT="$ROOT/judge.tsv"
PF="$ROOT/paths.txt"

segf() { printf '%s/dur.%s.%s.20200101T%06d-1.log' "$LEDGER" "$RUN_ALL_DUR_SCHEMA" "${2:-$TOK}" "$1"; }
fresh() { rm -rf "$LEDGER"; mkdir -p "$LEDGER"; }
# put <stamp> <rid> <tok> <secs|verdict|termination|key>... — raw v3 rows into one segment.
put() {
  local f r rid="$2"
  f="$(segf "$1" "$3")"; shift 3
  [ -f "$f" ] || printf '#os %s\n' "$OSA" >"$f"
  for r in "$@"; do printf '%s|%s\n' "$rid" "$r" >>"$f"; done
}
# pc <stamp> <key> <secs>... — this repo's PASS|completed rows, oldest first.
pc() {
  local st="$1" k="$2" s; shift 2
  for s in "$@"; do put "$st" "$RID" "$TOK" "$s|PASS|completed|$k"; done
}
# judge <path>... — runs thj_judge on the paths, in order; JRC is its exit code.
judge() {
  printf '%s\n' "$@" >"$PF"
  rm -f "$OUT"
  thj_judge "$REPO" "$PF" "$OUT"
  JRC=$?
}
hdr() { [ -f "$OUT" ] && head -n 1 "$OUT" | tr -d '\r'; }
# col <path> <n> — column n (1 = path, 2 = tier ... 7 = criteria) of that path's row.
col() { [ -f "$OUT" ] && tr -d '\r' <"$OUT" | awk -F '\t' -v p="$1" -v c="$2" 'NR > 1 && $1 == p { print $c; exit }'; }
# row <path> — tier/basis/samples/median/timeouts/criteria, slash-joined.
row() { [ -f "$OUT" ] && tr -d '\r' <"$OUT" | awk -F '\t' -v p="$1" 'NR > 1 && $1 == p { print $2 "/" $3 "/" $4 "/" $5 "/" $6 "/" $7; exit }'; }
ck() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=[$2] got=[$3]"; fi; }
ready() {
  declare -F thj_judge >/dev/null && return 0
  fail "$1" "thj_judge is not defined (not implemented: $JUDGE_REL)"
  return 1
}

case_begin "abs-boundaries-60-61-150-151" "bin/lib/test-heavy-judge.sh"
if ready "abs-boundaries"; then
  fresh
  pc 1 t/b60.sh 60 60 60; pc 1 t/b61.sh 61 61 61; pc 1 t/b150.sh 150 150 150; pc 1 t/b151.sh 151 151 151
  judge t/b60.sh t/b61.sh t/b150.sh t/b151.sh
  ck "judge exits 0" "0" "$JRC"
  ck "header reason=ok and this host's token" "1" "$(hdr | grep -c "^#heavy-judge reason=ok host=$TOK ")"
  ck "60 s is not heavy" "-/-/3/60/0/-" "$(row t/b60.sh)"
  ck "61 s is WARN by abs" "WARN/median/3/61/0/abs" "$(row t/b61.sh)"
  ck "150 s is WARN by abs" "WARN/median/3/150/0/abs" "$(row t/b150.sh)"
  ck "151 s is HARD by abs" "HARD/median/3/151/0/abs" "$(row t/b151.sh)"
fi
case_end

case_begin "hard-needs-three-samples" "bin/lib/test-heavy-judge.sh"
if ready "hard-needs-three-samples"; then
  fresh
  pc 1 t/two.sh 200 200; pc 1 t/three.sh 200 200 200
  judge t/two.sh t/three.sh
  ck "2 samples of 200 s stop at WARN" "WARN/median/2/200" "$(row t/two.sh | cut -d/ -f1-4)"
  ck "3 samples of 200 s reach HARD" "HARD/median/3/200" "$(row t/three.sh | cut -d/ -f1-4)"
fi
case_end

case_begin "even-count-median-floors" "bin/lib/test-heavy-judge.sh"
if ready "even-count-median-floors"; then
  fresh
  pc 1 t/even.sh 60 61 60 61
  judge t/even.sh
  ck "median of 60,60,61,61 floors to 60 (not heavy)" "-/-/4/60" "$(row t/even.sh | cut -d/ -f1-4)"
fi
case_end

case_begin "relative-criterion-against-suite-median" "bin/lib/test-heavy-judge.sh"
if ready "relative-criterion"; then
  fresh
  for _i in 1 2 3 4 5 6 7; do pc 1 "t/f$_i.sh" 4 4 4; done
  pc 1 t/r25.sh 25 25 25; pc 1 t/r31.sh 31 31 31; pc 1 t/r70.sh 70 70 70; pc 1 t/r200.sh 200 200 200
  judge t/f1.sh t/r25.sh t/r31.sh t/r70.sh t/r200.sh
  ck "suite median is 4 over 11 files" "1" "$(hdr | grep -c ' suite_median=4 suite_files=11$')"
  ck "25 s over 5x4 but under the 30 s floor is not heavy" "-/-/-" "$(row t/r25.sh | cut -d/ -f1,2,6)"
  ck "31 s over 5x4 and 30 is WARN by rel" "WARN/median/rel" "$(row t/r31.sh | cut -d/ -f1,2,6)"
  ck "70 s over 10x4 and 60 is HARD by rel" "HARD/median/rel" "$(row t/r70.sh | cut -d/ -f1,2,6)"
  ck "200 s meets HARD by both" "HARD/median/abs+rel" "$(row t/r200.sh | cut -d/ -f1,2,6)"
  ck "a filler at the suite median is not heavy" "-" "$(col t/f1.sh 2)"
fi
case_end

case_begin "timeout-floor-raises-to-hard" "bin/lib/test-heavy-judge.sh"
if ready "timeout-floor"; then
  fresh
  pc 1 t/to150.sh 10 10 10; put 1 "$RID" "$TOK" "150|FAIL|timeout|t/to150.sh"
  pc 1 t/to149.sh 10 10 10; put 1 "$RID" "$TOK" "149|FAIL|timeout|t/to149.sh"
  pc 1 t/both.sh 151 151 151; put 1 "$RID" "$TOK" "160|FAIL|timeout|t/both.sh"
  judge t/to150.sh t/to149.sh t/both.sh
  ck "a 150 s timeout row raises to HARD" "HARD/timeout-floor/3/10/1" "$(row t/to150.sh | cut -d/ -f1-5)"
  ck "a 149 s timeout row does not raise" "-/-/3/10/0" "$(row t/to149.sh | cut -d/ -f1-5)"
  ck "median HARD plus a timeout row" "HARD/median+timeout-floor/3/151/1" "$(row t/both.sh | cut -d/ -f1-5)"
fi
case_end

case_begin "timeout-floor-without-pass-rows" "bin/lib/test-heavy-judge.sh"
if ready "timeout-only"; then
  fresh
  put 1 "$RID" "$TOK" "150|FAIL|timeout|t/tonly.sh"
  pc 1 t/p2to.sh 200 200; put 1 "$RID" "$TOK" "160|FAIL|timeout|t/p2to.sh"
  judge t/tonly.sh t/p2to.sh
  ck "a timeout-only file is HARD by the floor with no samples" "HARD/timeout-floor/0/-/1" "$(row t/tonly.sh | cut -d/ -f1-5)"
  ck "2 PASS samples plus a timeout row is HARD by median+floor" "HARD/median+timeout-floor/2/200/1" "$(row t/p2to.sh | cut -d/ -f1-5)"
fi
case_end

case_begin "relative-threshold-boundaries" "bin/lib/test-heavy-judge.sh"
if ready "relative-boundaries"; then
  fresh
  for _i in 1 2 3 4 5 6 7; do pc 1 "t/g$_i.sh" 4 4 4; done
  pc 1 t/s30.sh 30 30 30; pc 1 t/s55.sh 55 55 55; pc 1 t/s60.sh 60 60 60
  judge t/g1.sh t/s30.sh t/s55.sh t/s60.sh
  ck "suite median is 4 over 10 files" "1" "$(hdr | grep -c ' suite_median=4 suite_files=10$')"
  ck "30 s is not over the 30 s floor: not heavy" "-/-/-" "$(row t/s30.sh | cut -d/ -f1,2,6)"
  ck "55 s is WARN by rel (under 10x4 HARD)" "WARN/median/rel" "$(row t/s55.sh | cut -d/ -f1,2,6)"
  ck "60 s is WARN by rel (not over the 60 s HARD floor)" "WARN/median/rel" "$(row t/s60.sh | cut -d/ -f1,2,6)"
fi
case_end

case_begin "relative-multiplier-decides-at-suite-median-10" "bin/lib/test-heavy-judge.sh"
if ready "relative-median-10"; then
  fresh
  for _i in 1 2 3 4 5 6 7; do pc 1 "t/m$_i.sh" 10 10 10; done
  pc 1 t/m45.sh 45 45 45; pc 1 t/m51.sh 51 51 51; pc 1 t/m90.sh 90 90 90; pc 1 t/m101.sh 101 101 101
  judge t/m1.sh t/m45.sh t/m51.sh t/m90.sh t/m101.sh
  ck "suite median is 10 over 11 files" "1" "$(hdr | grep -c ' suite_median=10 suite_files=11$')"
  ck "45 s is under 5x10 (and under the 60 s abs floor): not heavy" "-/-/-" "$(row t/m45.sh | cut -d/ -f1,2,6)"
  ck "51 s is over 5x10 but not over the 60 s abs floor: WARN by rel alone" "WARN/median/rel" "$(row t/m51.sh | cut -d/ -f1,2,6)"
  ck "90 s is over the 60 s abs floor and over 5x10: WARN by abs+rel" "WARN/median/abs+rel" "$(row t/m90.sh | cut -d/ -f1,2,6)"
  ck "101 s is over 10x10 and 60 but under the 150 s abs HARD: HARD by rel alone" "HARD/median/rel" "$(row t/m101.sh | cut -d/ -f1,2,6)"
fi
case_end

case_begin "unreadable-header-when-node-fails" "bin/lib/test-heavy-judge.sh"
if ready "unreadable"; then
  fresh
  pc 1 t/a.sh 200 200 200
  UNSTUB="$ROOT/failnode"
  mkdir -p "$UNSTUB"
  printf '#!/bin/sh\nexit 1\n' >"$UNSTUB/node"
  chmod +x "$UNSTUB/node"
  (PATH="$UNSTUB:$PATH"; judge t/a.sh; echo "$JRC" >"$ROOT/unreadable.rc")
  ck "a failing node: the judge still exits 0" "0" "$(cat "$ROOT/unreadable.rc")"
  ck "a failing node: header reason=unreadable" "1" "$(hdr | grep -c '^#heavy-judge reason=unreadable ')"
  ck "a failing node: every path is tier ?" "?" "$(col t/a.sh 2)"
fi
case_end

case_begin "only-pass-completed-rows-count" "bin/lib/test-heavy-judge.sh"
if ready "only-pass-completed"; then
  fresh
  pc 1 t/mix.sh 10 10 10
  put 1 "$RID" "$TOK" "500|FAIL|completed|t/mix.sh" "500|FAIL|completed|t/mix.sh" "500|FAIL|completed|t/mix.sh" \
    "500|?|?|t/mix.sh" "500|?|?|t/mix.sh" "500|?|?|t/mix.sh"
  judge t/mix.sh
  ck "FAIL|completed and ?|? rows stay out of the median" "-/-/3/10/0" "$(row t/mix.sh | cut -d/ -f1-5)"
fi
case_end

case_begin "no-series-is-unknown" "bin/lib/test-heavy-judge.sh"
if ready "no-series"; then
  fresh
  pc 1 t/known.sh 10 10 10
  judge t/unknown.sh t/known.sh
  ck "a path with no rows is ?" "?" "$(col t/unknown.sh 2)"
  ck "a measured path is -" "-" "$(col t/known.sh 2)"
fi
case_end

case_begin "rows-keep-input-order" "bin/lib/test-heavy-judge.sh"
if ready "input-order"; then
  fresh
  pc 1 t/a.sh 10 10 10; pc 1 t/b.sh 200 200 200; pc 1 t/c.sh 70 70 70
  judge t/c.sh t/unmeasured.sh t/a.sh t/b.sh
  ck "one row per input path, in input order" "t/c.sh t/unmeasured.sh t/a.sh t/b.sh" \
    "$(tr -d '\r' <"$OUT" 2>/dev/null | awk -F '\t' 'NR > 1 { printf "%s%s", (NR > 2 ? " " : ""), $1 }')"
fi
case_end

case_begin "newest-five-samples-only" "bin/lib/test-heavy-judge.sh"
if ready "newest-five"; then
  fresh
  pc 1 t/seg.sh 200 200 200 200 200; pc 2 t/seg.sh 10 10 10 10 10
  pc 1 t/line.sh 200 200 200 10 10 10 10 10
  judge t/seg.sh t/line.sh
  ck "the newer segment's five rows win" "-/-/5/10" "$(row t/seg.sh | cut -d/ -f1-4)"
  ck "later lines in a segment are newer" "-/-/5/10" "$(row t/line.sh | cut -d/ -f1-4)"
fi
case_end

case_begin "foreign-repo-and-host-rows-ignored" "bin/lib/test-heavy-judge.sh"
if ready "foreign-rows"; then
  fresh
  pc 1 t/own.sh 10 10 10
  put 2 "$OTHER_RID" "$TOK" "200|PASS|completed|t/own.sh" "200|PASS|completed|t/own.sh" "200|PASS|completed|t/own.sh"
  put 3 "$RID" "$OTHER_TOK" "200|PASS|completed|t/own.sh" "200|PASS|completed|t/own.sh" "200|PASS|completed|t/own.sh"
  judge t/own.sh
  ck "another repo's and another host's rows are not read" "-/-/3/10" "$(row t/own.sh | cut -d/ -f1-4)"
  ck "foreign rows stay out of the suite median and file count" "1" "$(hdr | grep -c ' suite_median=10 suite_files=1$')"
fi
case_end

case_begin "no-ledger-forks-nothing" "bin/lib/test-heavy-judge.sh"
if ready "no-ledger"; then
  STUB="$ROOT/stub"; CNT="$ROOT/forks.log"
  mkdir -p "$STUB"
  for _c in awk node; do
    _real="$(command -v "$_c")"
    printf '#!/bin/sh\nprintf "%%s\\n" %s >>"%s"\nexec "%s" "$@"\n' "$_c" "$CNT" "$_real" >"$STUB/$_c"
    chmod +x "$STUB/$_c"
  done
  rm -rf "$LEDGER"; : >"$CNT"
  (PATH="$STUB:$PATH"; judge t/a.sh t/b.sh)
  ck "no segment: reason=missing" "1" "$(hdr | grep -c '^#heavy-judge reason=missing ')"
  ck "no segment: awk is never started" "0" "$(grep -c '^awk$' "$CNT")"
  ck "no segment: node is never started" "0" "$(grep -c '^node$' "$CNT")"
  fresh; pc 1 t/a.sh 10 10 10; : >"$CNT"
  (PATH="$STUB:$PATH"; judge t/a.sh t/b.sh)
  _n="$(grep -c '^awk$' "$CNT")"
  if [ "$_n" -ge 1 ]; then pass "positive control: the stub counts awk once a ledger exists ($_n)"
  else fail "positive control: the stub saw no awk with a ledger present"; fi
fi
case_end

case_begin "dispatcher-of-fragment" "bin/lib/test-heavy-judge.sh"
if declare -F thj_dispatcher_of >/dev/null; then
  mkdir -p "$REPO/tests/bin/foo"
  : >"$REPO/tests/bin/foo.sh"; : >"$REPO/tests/bin/foo/x.sh"
  ck "a sibling-suite fragment maps to its dispatcher" "tests/bin/foo.sh" "$(thj_dispatcher_of tests/bin/foo/x.sh)"
  ck "a dispatcher maps to itself" "tests/bin/foo.sh" "$(thj_dispatcher_of tests/bin/foo.sh)"
  mkdir -p "$REPO/tests/hooks/bar" "$REPO/tests/bin/nodisp"
  : >"$REPO/tests/hooks/bar.js"; : >"$REPO/tests/hooks/bar/f.js"; : >"$REPO/tests/bin/nodisp/x.sh"
  ck "a JS fragment maps to its dispatcher" "tests/hooks/bar.js" "$(thj_dispatcher_of tests/hooks/bar/f.js)"
  ck "a fragment with no dispatcher passes through" "tests/bin/nodisp/x.sh" "$(thj_dispatcher_of tests/bin/nodisp/x.sh)"
  ck "a plain test with no sibling suite passes through" "tests/bin/plain.sh" "$(thj_dispatcher_of tests/bin/plain.sh)"
else
  fail "dispatcher-of-fragment" "thj_dispatcher_of is not defined (not implemented: $JUDGE_REL)"
fi
case_end

case_begin "dispatcher-of-outermost-and-stem-mismatch" "bin/lib/test-heavy-judge.sh"
if declare -F thj_dispatcher_of >/dev/null; then
  mkdir -p "$REPO/tests/bin/outer/inner" "$REPO/tests/bin/q.Tests" "$REPO/tests/bin/notes"
  : >"$REPO/tests/bin/outer.sh"; : >"$REPO/tests/bin/outer/inner.sh"; : >"$REPO/tests/bin/outer/inner/x.sh"
  : >"$REPO/tests/bin/q.Tests.ps1"; : >"$REPO/tests/bin/q.Tests/y.ps1"
  : >"$REPO/tests/bin/notes.txt"; : >"$REPO/tests/bin/notes/z.sh"
  ck "a nested fragment maps to the outermost dispatcher" "tests/bin/outer.sh" "$(thj_dispatcher_of tests/bin/outer/inner/x.sh "$REPO")"
  ck "an inner dispatcher itself maps to the outer one" "tests/bin/outer.sh" "$(thj_dispatcher_of tests/bin/outer/inner.sh "$REPO")"
  ck "a folder whose name is not the candidate's stem passes through" "tests/bin/q.Tests/y.ps1" "$(thj_dispatcher_of tests/bin/q.Tests/y.ps1 "$REPO")"
  ck "a non-test candidate beside the folder passes through" "tests/bin/notes/z.sh" "$(thj_dispatcher_of tests/bin/notes/z.sh "$REPO")"
else
  fail "dispatcher-of-outermost" "thj_dispatcher_of is not defined (not implemented: $JUDGE_REL)"
fi
case_end

case_begin "bad-parameters-are-unreadable" "bin/lib/test-heavy-judge.sh"
if ready "bad-parameters"; then
  fresh
  pc 1 t/a.sh 200 200 200
  GOOD_P="samples=5 min_hard=3 ratio_warn=5 ratio_hard=10 floor_warn=30 floor_hard=60"
  # bp <name> <reason> <tier> <limits> <params> — node exits 0 and prints these values.
  bp() {
    local d="$ROOT/node-$RANDOM$RANDOM"
    mkdir -p "$d"
    printf '#!/bin/sh\ncase "$2" in --get) echo "%s" ;; *) echo "%s" ;; esac\nexit 0\n' "$4" "$5" >"$d/node"
    chmod +x "$d/node"
    (PATH="$d:$PATH"; judge t/a.sh; echo "$JRC" >"$ROOT/bp.rc")
    ck "$1: the judge exits 0" "0" "$(cat "$ROOT/bp.rc")"
    ck "$1: header reason=$2" "1" "$(hdr | grep -c "^#heavy-judge reason=$2 ")"
    ck "$1: the path is tier $3" "$3" "$(col t/a.sh 2)"
  }
  bp "zero WARN limit" unreadable "?" "0 150" "$GOOD_P"
  bp "zero HARD limit" unreadable "?" "60 0" "$GOOD_P"
  bp "samples=0" unreadable "?" "60 150" "${GOOD_P/samples=5/samples=0}"
  bp "a missing ratio_hard" unreadable "?" "60 150" "${GOOD_P/ ratio_hard=10/}"
  bp "a negative floor_warn" unreadable "?" "60 150" "${GOOD_P/floor_warn=30/floor_warn=-1}"
  bp "the same stub with valid values (control)" ok HARD "60 150" "$GOOD_P"
fi
case_end

case_begin "argument-shortage-missing-pathsfile-crlf" "bin/lib/test-heavy-judge.sh"
if ready "arguments"; then
  fresh
  pc 1 t/cr.sh 200 200 200
  rc=0; thj_judge "$REPO" "$PF" || rc=$?
  ck "a missing <out-file> argument returns 2" "2" "$rc"
  rc=0; thj_judge "" "$PF" "$OUT" || rc=$?
  ck "an empty <repo-root> returns 2" "2" "$rc"
  rm -f "$OUT"; rc=0; thj_judge "$REPO" "$ROOT/no-such-paths" "$OUT" || rc=$?
  ck "a missing paths file still exits 0" "0" "$rc"
  ck "a missing paths file: header only, no rows" "1" "$(tr -d '\r' <"$OUT" | wc -l | tr -d ' ')"
  printf 't/cr.sh\r\n' >"$PF"; rm -f "$OUT"; thj_judge "$REPO" "$PF" "$OUT"
  ck "a CRLF path is judged under its stripped key" "HARD/median/3/200" "$(row t/cr.sh | cut -d/ -f1-4)"
  ck "no CR survives into the path column" "0" "$(awk -F '\t' 'NR > 1 && $1 ~ /\r/' "$OUT" | wc -l | tr -d ' ')"
fi
case_end

case_begin "report-orders-tiers-and-medians" "bin/lib/test-heavy-judge.sh"
if declare -F thj_report >/dev/null; then
  fresh
  pc 1 t/h200.sh 200 200 200; put 1 "$RID" "$TOK" "150|FAIL|timeout|t/hto.sh"
  pc 1 t/w100.sh 100 100 100; pc 1 t/z10.sh 10 10 10
  printf '%s\n' t/unk.sh t/z10.sh t/hto.sh t/w100.sh t/h200.sh >"$PF"
  thj_report "$REPO" "$PF" >"$ROOT/report.tsv"
  ck "HARD by median desc (median - last), WARN, -, then ?" "t/h200.sh t/hto.sh t/w100.sh t/z10.sh t/unk.sh" \
    "$(tr -d '\r' <"$ROOT/report.tsv" | awk -F '\t' 'NR > 1 { printf "%s%s", (NR > 2 ? " " : ""), $1 }')"
  ck "the judge header comes first" "1" "$(head -n 1 "$ROOT/report.tsv" | grep -c '^#heavy-judge reason=ok ')"
else
  fail "report-orders" "thj_report is not defined (not implemented: $JUDGE_REL)"
fi
case_end

case_begin "audit-heavy-skips-runner-and-fragments" "bin/lib/test-heavy-judge.sh"
if declare -F thj_audit_heavy >/dev/null; then
  fresh
  mkdir -p "$REPO/flat/a"
  : >"$REPO/flat/run-all.sh"; : >"$REPO/flat/a.sh"; : >"$REPO/flat/a/frag.sh"
  pc 1 flat/run-all.sh 200 200 200; pc 1 flat/a.sh 10 10 10; pc 1 flat/a/frag.sh 200 200 200
  (
    . "$SCRIPT_CHECKOUT_ROOT/bin/lib/test-dup-group.sh"
    declare -F tlr_list_dir_into >/dev/null || . "$SCRIPT_CHECKOUT_ROOT/bin/lib/test-language-registry.sh"
    tlr_load
    _TDG_TEST_DIRS=(flat); _TDG_TESTS_DIR=flat
    thj_audit_heavy "$REPO"
  ) >"$ROOT/audit.tsv" 2>"$ROOT/audit.err"
  ck "a flat test dir lists only its direct test (err=$(head -c 200 "$ROOT/audit.err"))" "flat/a.sh" \
    "$(tr -d '\r' <"$ROOT/audit.tsv" | awk -F '\t' 'NR > 1 { printf "%s%s", (NR > 2 ? " " : ""), $1 }')"
else
  fail "audit-heavy" "thj_audit_heavy is not defined (not implemented: $JUDGE_REL)"
fi
case_end

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
