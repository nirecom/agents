#!/usr/bin/env bash
# tests/tests/feature-2591-test-jail/common.sh — sourced by the feature-2591-test-jail-*.sh tests:
# assertions, the jail runner, the fixture tree and the run-dir builders. Functions only.
#
# The caller defines SCRIPT_CHECKOUT_ROOT and TMP_ROOT (a mktemp dir) and calls jt_setup.
# Every jail script is started by absolute path from the checkout under test, never from the
# installed copy; tests/run-all.sh is never started.

expect_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=$3 got=$2"; fi; }
expect_has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing: $3 in: $2" ;; esac; }
expect_lacks() { case "$2" in *"$3"*) fail "$1" "unexpected: $3 in: $2" ;; *) pass "$1" ;; esac; }
# have_file <path> — prints yes or no, for expect_eq.
have_file() { if [[ -e "$1" ]]; then printf yes; else printf no; fi; }

# jt_setup — JT_DIR (the scripts under test), JT_WORK (cwd and capture files) and JT_PATH: the
# PATH without any command-guard dir, because the jail refuses a PATH dir that holds a forge
# stub next to git (the guard's bin) as a "shared dir".
jt_setup() {
  local d out="" parts=()
  JT_DIR="$SCRIPT_CHECKOUT_ROOT/experimental/test-jail"
  JT_WORK="$TMP_ROOT/work"
  JT_N=0
  JT_ENVV=()
  mkdir -p "$JT_WORK" || return 1
  IFS=: read -r -a parts <<<"$PATH"
  for d in "${parts[@]}"; do
    [[ -n "$d" ]] || continue
    case "$d" in */command-guard/*|*/command-guard) continue ;; esac
    out="${out:+$out:}$d"
  done
  JT_PATH="$out"
}

# jt_exec <script> [args...] — runs a jail script (a name under JT_DIR, or an absolute path)
# with a timeout, the extra environment in JT_ENVV (env arguments; cleared afterwards), and
# sets JT_RC, JT_OUT (stdout), JT_ERR (stderr) and JT_ALL (both).
jt_exec() {
  local sp="$JT_DIR/$1"
  [[ "$1" != /* ]] || sp="$1"
  shift
  JT_RC=0
  (cd "$JT_WORK" && env "${JT_ENVV[@]}" PATH="$JT_PATH" bash "$RWT" 100 bash "$sp" "$@") \
    >"$JT_WORK/out.txt" 2>"$JT_WORK/err.txt" || JT_RC=$?
  JT_ENVV=()
  JT_OUT="$(cat "$JT_WORK/out.txt")"
  JT_ERR="$(cat "$JT_WORK/err.txt")"
  JT_ALL="$JT_OUT"$'\n'"$JT_ERR"
}

jt_jail() { jt_exec run-jailed.sh "$@"; }

# jt_sentinel <name> — for the next jt_exec: a fresh sentinel path JT_SENT (absent now) handed to
# the fixture test through JT_ENVV. Call after any JT_ENVV=(...) assignment; it appends.
jt_sentinel() {
  JT_SENT="$TMP_ROOT/sentinel-$1"
  rm -f "$JT_SENT"
  JT_ENVV+=("JT_SENTINEL=$JT_SENT")
}
# jt_ran — yes if the fixture test body left its sentinel, else no.
jt_ran() { have_file "$JT_SENT"; }

# jt_first_pinned — the first PINNED: line of JT_OUT.
jt_first_pinned() { printf '%s\n' "$JT_OUT" | awk '/^PINNED:/{print; exit}'; }

# jt_make_tree <dir> <none-fn|state-fn|full-fn> — a fixture tree whose launcher defines no pin
# function, only the state-dir one, or both (stubs that return 0; no decoy or guard is built).
# It is not a git repo.
jt_make_tree() {
  local d="$1" kind="$2" launch="$1/bin/lib/run-all-launch.sh"
  mkdir -p "$d/bin/lib" "$d/tests" || return 1
  cp "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" "$d/bin/" || return 1
  cp "$SCRIPT_CHECKOUT_ROOT/bin/lib/timed-exec.sh" "$d/bin/lib/" || return 1
  case "$kind" in
    none-fn) printf '%s\n' '# fixture launcher: no pin function' >"$launch" ;;
    state-fn) printf '%s\n' 'run_all_pin_state_dirs() { return 0; }' >"$launch" ;;
    full-fn) printf '%s\n' 'run_all_pin_state_dirs() { return 0; }' 'run_all_pin_test_env() { return 0; }' >"$launch" ;;
    *) return 1 ;;
  esac
  # The fixture test leaves a sentinel file when its body runs (path in JT_SENTINEL, which the
  # jail passes through as it does any variable it does not unset), so "the body did not run"
  # is an assertion on a file that the allowed cases prove can exist.
  printf '%s\n' '[[ -z "${JT_SENTINEL:-}" ]] || : >"$JT_SENTINEL"' 'echo "ok JT_BODY_RAN"' >"$d/tests/ok.sh"
  printf '%s\n' 'for n in ${JT_NAMES:-}; do' '  if [[ -n "${!n+x}" ]]; then echo "$n=set"; else echo "$n=unset"; fi' 'done' \
    >"$d/tests/env-probe.sh"
  # The copied wrapper must work inside the fixture, or every jail run fails for that reason.
  bash "$d/bin/run-with-timeout.sh" 5 true
}

# jt_run_list <list> <run-dir> <tree> [pin=none] [weaker-pin] — run-list.sh with one lane.
jt_run_list() {
  local -a extra=()
  [[ -z "${5:-}" ]] || extra=("$5")
  jt_exec run-list.sh "$1" "$2" "$3" 1 "${4:-none}" 60 "${extra[@]}"
}

# jt_write_marker <dir> <kind> — a hand-made marker, to stand in for another tool's directory.
jt_write_marker() {
  mkdir -p "$1"
  printf '%s\n' 'tool=experimental/test-jail' "kind=$2" 'creator=fixture' 'created=2026-01-01T00:00:00Z' 'format=1' \
    >"$1/.test-jail-dir"
}

# jt_marker_fn <function> [args...] — source jail-marker.sh in a fresh bash and call a function.
jt_marker_fn() {
  JT_RC=0
  env "${JT_ENVV[@]}" PATH="$JT_PATH" bash -c '. "$1"; shift; "$@"' _ "$JT_DIR/jail-marker.sh" "$@" \
    >"$JT_WORK/out.txt" 2>"$JT_WORK/err.txt" || JT_RC=$?
  JT_ENVV=()
  JT_OUT="$(cat "$JT_WORK/out.txt")"
  JT_ERR="$(cat "$JT_WORK/err.txt")"
}

# jt_run_dir <dir> — an empty run dir: results.tsv, logs/, requested.txt, absent.txt.
jt_run_dir() {
  mkdir -p "$1/logs"
  : >"$1/results.tsv"
  : >"$1/requested.txt"
  : >"$1/absent.txt"
}

# jt_add <run-dir> <rc> <test> <pin> [header] [body] — one result row, its log, and the test
# in requested.txt. <pin> is the 4th results.tsv column; "-" writes the old 3-column row. The
# log starts with <header> (default: a PINNED: line that agrees with <pin>; "-" = none), then <body>.
jt_add() {
  local d="$1" rc="$2" rel="$3" pin="$4" hdr="${5-}" body="${6-}" log
  log="$d/logs/${rel//\//__}.log"
  if [[ "$pin" == "-" ]]; then
    printf '%s\t%s\t%s\n' "$rc" 3 "$rel" >>"$d/results.tsv"
  else
    printf '%s\t%s\t%s\t%s\n' "$rc" 3 "$rel" "$pin" >>"$d/results.tsv"
  fi
  if [[ -z "$hdr" && "$pin" != "-" && "$pin" != unknown ]]; then
    hdr="PINNED: obtained=$pin requested=$pin fixture"
  fi
  : >"$log"
  if [[ -n "$hdr" && "$hdr" != "-" ]]; then printf '%s\n' "$hdr" >>"$log"; fi
  if [[ -n "$body" ]]; then printf '%s\n' "$body" >>"$log"; fi
  jt_request "$d" "$rel"
}

# jt_request <run-dir> <test> — list a test in requested.txt (once).
jt_request() { grep -qxF "$2" "$1/requested.txt" 2>/dev/null || printf '%s\n' "$2" >>"$1/requested.txt"; }

# jt_cmp_to <out> <changed> <baseline> — compare-runs.sh; sets JT_RC, JT_ALL.
jt_cmp_to() { jt_exec compare-runs.sh "$2" "$3" "$1"; }

# jt_cmp <changed> <baseline> — compare into a fresh out dir (JT_CMP).
jt_cmp() {
  JT_N=$((JT_N + 1))
  JT_CMP="$TMP_ROOT/cmp$JT_N"
  jt_cmp_to "$JT_CMP" "$1" "$2"
}

# jt_reasons <test> — the not-compared reasons of JT_CMP for one test, space separated.
jt_reasons() { awk -F'\t' -v t="$1" '$2==t{printf "%s ", $1}' "$JT_CMP/not-compared.tsv" 2>/dev/null; }

# jt_summary_rows <test> — summary.tsv rows of JT_CMP whose test column is exactly <test>.
jt_summary_rows() { awk -F'\t' -v t="$1" '$7==t' "$JT_CMP/summary.tsv" 2>/dev/null; }
