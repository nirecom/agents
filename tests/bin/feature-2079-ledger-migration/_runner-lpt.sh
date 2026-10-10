#!/usr/bin/env bash
# tests/bin/feature-2079-ledger-migration/_runner-lpt.sh
# Tests: tests/run-all.sh
# Tags: tests, bin, ledger, migration, parallel, scope:issue-specific, TL2
# TL3 gap (what this test does NOT catch): owned by the dispatcher header, tests/bin/feature-2079-ledger-migration.sh.
# n17 (14) helper: a real run-all whose measurements exist only in the pre-#2079 format
# must still plan longest-first after its next run. Prints `R14 <name>=<value>` lines;
# the dispatcher asserts them. Real uname/host on purpose: the runner computes its own key.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/tests/feature-1832-run-all-parallel/_lib.sh"
. "$SCRIPT_CHECKOUT_ROOT/bin/lib/run-all-parallelism.sh" || exit 98
. "$SCRIPT_CHECKOUT_ROOT/bin/lib/run-all-durations.sh" || exit 98

fx_init "n17-14-runner-lpt" >/dev/null
r14() { printf 'R14 %s=%s\n' "$1" "$2"; }

# The pre-#2079 key, from the real host: raw `uname -s`, arch, host digest.
os="$(uname -s 2>/dev/null || printf unknown)"; arch="$(uname -m 2>/dev/null || printf unknown)"
host="${HOSTNAME:-}"; [ -n "$host" ] || host="$(uname -n 2>/dev/null || printf unknown)"
oldtok="$(run_all_dur_pad16 "$(run_all_id_digest "$(run_all_id_field "$os")|$(run_all_id_field "$arch")|$(run_all_id_digest "$host")")")"

root="$(fx_new_root)"
fx_add_dummy "$root" z1 --sleep 2
fx_add_dummy "$root" z2 --sleep 8
fx_add_dummy "$root" z3 --sleep 4
FX_LEDGER_KEEP=1
fx_ledger_clear
fx_exec "$root" 120 "$FX_TMP_ROOT/w.out" "$FX_TMP_ROOT/w.err" -j 3 --all
r14 warm "$(fx_contract_field "$FX_TMP_ROOT/w.out" EXECUTED)"

# Rewrite every measured segment as a pre-#2079 one: old name, no header, two hours old.
n=0
for f in "$(fx_ledger_dir)"/dur.*; do
  [ -f "$f" ] || continue
  n=$((n + 1))
  tail="${f##*/}"; tail="${tail#dur.}"; tail="${tail#*.}"; tail="${tail#*.}"
  # The runner closes its segment on exit (#2079 S7b); old-format names never had a state.
  case "$tail" in *.closed.log) tail="${tail%.closed.log}.log" ;; esac
  dest="$(fx_ledger_dir)/dur.1.$oldtok.$tail"
  grep -v '^#' "$f" > "$f.tmp"
  rm -f "$f"
  mv "$f.tmp" "$dest"
  t=$(( $(date +%s) - 7200 ))
  touch -t "$(date -d "@$t" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$t" +%Y%m%d%H%M.%S)" "$dest"
done
r14 planted "$n"

fx_exec "$root" 60 "$FX_TMP_ROOT/r.out" "$FX_TMP_ROOT/r.err" -j 1 "$(fx_tests_dir "$root")/bin/z1.sh"
fx_exec "$root" 60 "$FX_TMP_ROOT/p.out" "$FX_TMP_ROOT/p.err" --print-plan --all
r14 order "$(awk -F'\t' '$1 == "plan" { n = split($4, a, /[\/\\]/); printf "%s ", a[n] }' "$FX_TMP_ROOT/p.out")"
r14 tiers "$(awk -F'\t' '$1 == "plan" { n = split($4, a, /[\/\\]/); printf "%s:%s ", a[n], $5 }' "$FX_TMP_ROOT/p.out")"
left=0
for f in "$(fx_ledger_dir)"/dur.1.*; do [ -e "$f" ] && left=$((left + 1)); done
r14 old_left "$left"
exit 0
