# shellcheck shell=bash
# tests/bin/feature-2079-ledger-migration/_lib.sh
# Tests: bin/lib/run-all-ledger-migrate.sh
# Tags: tests, bin, ledger, migration, helpers, scope:issue-specific, TL2
# TL3 gap (what this test does NOT catch): owned by the dispatcher header, tests/bin/feature-2079-ledger-migration.sh.
# Helpers for the #2079 ledger-migration dispatcher; sourced, never run standalone.
# Parent side (LM_CHILD unset): temp root, the uname stub, lm_run, ck, lm_v.
# Child side (LM_CHILD=1, via _driver.sh): helpers that need the libraries loaded.

LM_ARCH="x86_64"
__LIB_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LM_PARTS="$__LIB_SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2079-ledger-migration"
# The pre-#2079 OS field is the raw `uname -s`; these are the four spellings the issue names.
LM_W26300="MINGW64_NT-10.0-26300"
LM_M26300="MSYS_NT-10.0-26300"
LM_M26200="MSYS_NT-10.0-26200"

if [ "${LM_CHILD:-0}" != "1" ]; then
  LM_TMP="$(mktemp -d)"
  trap 'chmod -R u+rwx "$LM_TMP" >/dev/null 2>&1 || true; rm -rf "$LM_TMP"' EXIT
  harness_isolate "$LM_TMP/iso"
  mkdir -p "$LM_TMP/stubbin" "$LM_TMP/repo"
  # The stub answers each flag from the environment, so one case pins one host exactly.
  printf '%s\n' '#!/bin/sh' \
    'case "${1:-}" in' \
    '  -s) printf "%s\n" "$LM_STUB_S" ;;' \
    '  -m) printf "%s\n" "$LM_STUB_M" ;;' \
    '  -n) printf "%s\n" "$LM_STUB_N" ;;' \
    '  -r) printf "%s\n" "$LM_STUB_R" ;;' \
    '  *)  printf "%s\n" "$LM_STUB_S" ;;' \
    'esac' > "$LM_TMP/stubbin/uname"
  chmod +x "$LM_TMP/stubbin/uname"
  LM_REPO="$LM_TMP/repo"
  LM_S="$LM_W26300"; LM_R="3.5.4-0.x86_64"; LM_HOST="stubhost"; LM_LIBSET="dur"
  # Every part file only defines functions, so the child loads them all (dispatchers append).
  LM_PART_DIRS="${LM_PART_DIRS:-$LM_PARTS}"
  # Planted stamps must stay inside the 30-day retention whatever day the suite runs, so they
  # are relative: computed once here (UTC, GNU `date -u -d @` or BSD `date -u -r`) and handed
  # to every child. 2 days apart keeps each far from the 30-day and the 6-hour boundaries,
  # and the order older < day < newer < now holds. Never plant a fixed calendar stamp.
  lm_day_ago() {
    local t; t=$(( $(date -u +%s) - $1 * 86400 ))
    date -u -d "@$t" +%Y%m%d 2>/dev/null || date -u -r "$t" +%Y%m%d
  }
  LM_DAY="$(lm_day_ago 4)"; LM_DAY_OLDER="$(lm_day_ago 6)"; LM_DAY_NEWER="$(lm_day_ago 2)"
fi

# lm_cache — a fresh, empty cache root for one case.
lm_cache() { mktemp -d "$LM_TMP/cacheXXXXXX"; }

# lm_run <cache> <fn> [args] — runs a part-file function in a child bash whose uname,
# HOSTNAME and cache root are pinned; a child process gives every run its own $$ and memo.
# LM_XVAR is one free-form value a case may hand to its child (e.g. a seam's epoch).
lm_run() {
  local cache="$1"; shift
  run_with_timeout 60 env -u RUN_ALL_DUR_REPO_ID -u RUN_ALL_DUR_HOST_TOKEN -u RTB_LEDGER_REPO \
    PATH="$LM_TMP/stubbin:$PATH" HOSTNAME="$LM_HOST" \
    LM_STUB_S="$LM_S" LM_STUB_R="$LM_R" LM_STUB_M="$LM_ARCH" LM_STUB_N="$LM_HOST" \
    RUN_ALL_CACHE_DIR="$cache" LM_CHILD=1 LM_TMP="$LM_TMP" LM_REPO="$LM_REPO" LM_HOST="$LM_HOST" \
    LM_LIBSET="$LM_LIBSET" LM_PART_DIRS="$LM_PART_DIRS" LM_XVAR="${LM_XVAR:-}" \
    LM_DAY="$LM_DAY" LM_DAY_OLDER="$LM_DAY_OLDER" LM_DAY_NEWER="$LM_DAY_NEWER" \
    bash "$LM_PARTS/_driver.sh" "$@" 2>/dev/null
}

ck() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=[$2] got=[$3]"; fi; }
# lm_v <child-output> <name> — the value of the first `name=value` line.
lm_v() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }

# ---- child side ---------------------------------------------------------------

say() { printf '%s=%s\n' "$1" "$2"; }
lm_dur_dir() { printf '%s/durations' "$(run_all_cache_dir)"; }
lm_rid() { run_all_dur_repo_id "$LM_REPO"; }
lm_tok() { run_all_dur_host_token; }
# lm_oldtok <raw-uname-s> [host] — the pre-#2079 token: digest of `<raw os>|<arch>|<host digest>`.
lm_oldtok() {
  run_all_dur_pad16 "$(run_all_id_digest "$(run_all_id_field "$1")|$(run_all_id_field "$LM_ARCH")|$(run_all_id_digest "${2:-$LM_HOST}")")"
}
# lm_age <path> <minutes> — set mtime N minutes back; `date -d @` is GNU, `date -r <epoch>` BSD.
lm_age() {
  local t s; t=$(( $(date +%s) - $2 * 60 ))
  s="$(date -d "@$t" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$t" +%Y%m%d%H%M.%S)"
  touch -t "$s" "$1"
}
lm_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo none; }
lm_sum() { if [ -f "$1" ]; then cksum < "$1"; else echo none; fi; }

# lm_plant_dur <name> <age-min> <header|-> <secs:key>... — one segment in this repo's ledger.
lm_plant_dur() {
  local name="$1" age="$2" hdr="$3" rid f kv; shift 3
  rid="$(lm_rid)"; f="$(lm_dur_dir)/$name"
  mkdir -p "$(lm_dur_dir)"
  : > "$f"
  [ "$hdr" = "-" ] || printf '#os %s\n' "$hdr" >> "$f"
  for kv in "$@"; do printf '%s|%s|%s\n' "$rid" "${kv%%:*}" "${kv#*:}" >> "$f"; done
  lm_age "$f" "$age"
}

# lm_get <key>... — the values the reader resolves, space-separated, `-` when unresolved.
lm_get() {
  local k i=0 kf="$LM_TMP/keys.$$" of="$LM_TMP/vals.$$"
  : > "$kf"
  for k in "$@"; do i=$((i + 1)); printf '%s\t%s\n' "$i" "$k" >> "$kf"; done
  run_all_dur_lookup "$LM_REPO" "$kf" "$of"
  awk -F '\t' '{ printf "%s%s", (NR > 1 ? " " : ""), ($2 == "" ? "-" : $2) } END { print "" }' "$of"
}

# S7 claims and publishes with `mv`; these shadow it inside one child (assumes plain `mv`).
# lm_mv_fail_claim — renaming the file named $LM_XVAR to `.migrating` fails (file held open).
lm_mv_fail_claim() {
  mv() { local a=("$@"); case "${a[$# - 1]}" in */"$LM_XVAR.migrating") return 1 ;; esac; command mv "$@"; }
}
# lm_mv_cut_publish — the first non-claim `mv` records its source (the temp file) in the file
# $LM_XVAR and ends the child: an interruption between writing the temp and publishing it.
lm_mv_cut_publish() {
  mv() {
    local a=("$@"); case "${a[$# - 1]}" in *.migrating) command mv "$@"; return ;; esac
    printf '%s\n' "${a[$# - 2]}" > "$LM_XVAR"; exit 0
  }
}

# lm_ls — the ledger directory's entries (files and dirs), C-sorted, space-separated.
lm_ls() { (cd "$(lm_dur_dir)" 2>/dev/null && LC_ALL=C ls -A) | tr '\n' ' '; }
lm_count() { local n=0 f; for f in "$(lm_dur_dir)"/$1; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
