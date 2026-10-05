# shellcheck shell=bash
# tests/bin/feature-2431-run-tests-baseline/ledger.sh
# Tests: bin/lib/run-tests-baseline-ledger.sh
# Tags: run-tests, baseline, ledger, scope:issue-specific, pwsh-not-required, TL2
# Sourced by the dispatcher; never run standalone.
# Plan contract: rtb_ledger_append <sha> <path> <fail|pass>, rtb_ledger_lookup_same_base
# <sha> <path>, rtb_ledger_lookup_inheritable <path>, rtb_ledger_sweep; one append-only
# segment per process at $(run_all_cache_dir)/baseline/<repo_id>/v2.<host>-<epoch>-<pid>.seg,
# lines `v2\t<B1>\t<host>\t<rel-path>\t<fail|pass>\t<epoch>\t<os-attr>` (#2079).

LEDGER_SHA_A="aaaa1111bbbb2222cccc3333dddd4444eeee5555"
LEDGER_SHA_B="bbbb2222cccc3333dddd4444eeee5555ffff6666"
LEDGER_ATTR="Windows/10.0.26300"
LEDGER_ATTR_RE='[A-Za-z0-9._-]{1,32}/[A-Za-z0-9._-]{1,64}'

# ledger_rec <sha> <host> <path> <fail|pass> <epoch> — one synthetic v2 record line.
ledger_rec() { printf 'v2\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$LEDGER_ATTR"; }

# ledger_segments <cache> — every segment file under baseline/, excluding worktrees/ and tmp/.
ledger_segments() {
  find "$1/baseline" -type f -name '*.seg' 2>/dev/null
}

run_ledger_cases() {
  if [ ! -f "$LEDGER_LIB" ]; then
    local id
    for id in L1 L2 L3 L3b L4 L5-candidates L5-pass L6-corrupt L6-unwritable; do
      fail "$id: bin/lib/run-tests-baseline-ledger.sh not found (impl pending)"
    done
    return
  fi
  local repo="$TMPROOT/repo-ledger" t="tests/bin/test-foo.sh"
  mk_fixture_repo "$repo" >/dev/null

  # ---- L1: append writes one v2 record into a segment under baseline/<repo_id>/ ----
  local c1="$TMPROOT/cache-l1" seg rec
  mkdir -p "$c1"
  ledger_call "$c1" "$repo" rtb_ledger_append "$LEDGER_SHA_A" "$t" fail >/dev/null 2>&1
  seg="$(ledger_segments "$c1" | head -1)"
  rec="$(head -1 "$seg" 2>/dev/null)"
  if [ -n "$seg" ] && [ "$(basename "$(dirname "$(dirname "$seg")")")" = "baseline" ] \
    && basename "$seg" | grep -qE '^v2\.[A-Za-z0-9]+-[0-9]+-[0-9]+\.seg$' \
    && printf '%s\n' "$rec" | grep -qE "^v2	$LEDGER_SHA_A	[A-Za-z0-9]+	$t	fail	[0-9]+	$LEDGER_ATTR_RE$"; then
    pass "L1: append writes a 7-field v2 record into baseline/<repo_id>/v2.<host>-<epoch>-<pid>.seg"
  else
    fail "L1: segment/record layout wrong (seg=${seg:-none} rec=$rec)"
  fi

  # ---- L2: both outcomes are recorded ----
  local c2="$TMPROOT/cache-l2"
  mkdir -p "$c2"
  ledger_call "$c2" "$repo" rtb_ledger_append "$LEDGER_SHA_A" "tests/bin/p.sh" pass >/dev/null 2>&1
  ledger_call "$c2" "$repo" rtb_ledger_append "$LEDGER_SHA_A" "tests/bin/f.sh" fail >/dev/null 2>&1
  local all2
  all2="$(ledger_segments "$c2" | xargs cat 2>/dev/null)"
  if printf '%s\n' "$all2" | grep -q "	tests/bin/p.sh	pass	" \
    && printf '%s\n' "$all2" | grep -q "	tests/bin/f.sh	fail	"; then
    pass "L2: ledger records both pass and fail outcomes"
  else
    fail "L2: outcome recording incomplete: $(printf '%s' "$all2" | tr '\n' '|')"
  fi

  # ---- L3 / L3b: same-base lookup reuses fail and pass (record (a)) ----
  local r3 r3b
  r3="$(ledger_call "$c2" "$repo" rtb_ledger_lookup_same_base "$LEDGER_SHA_A" "tests/bin/f.sh" 2>/dev/null)"
  r3b="$(ledger_call "$c2" "$repo" rtb_ledger_lookup_same_base "$LEDGER_SHA_A" "tests/bin/p.sh" 2>/dev/null)"
  [ "$r3" = "fail" ] && pass "L3: same-base lookup returns fail" \
    || fail "L3: same-base lookup expected fail, got: $r3"
  [ "$r3b" = "pass" ] && pass "L3b: same-base lookup returns pass" \
    || fail "L3b: same-base lookup expected pass, got: $r3b"

  # ---- L4: unknown base SHA → nothing ----
  local r4
  r4="$(ledger_call "$c2" "$repo" rtb_ledger_lookup_same_base "$LEDGER_SHA_B" "tests/bin/f.sh" 2>/dev/null)"
  [ -z "$r4" ] && pass "L4: same-base lookup empty for unknown SHA" \
    || fail "L4: unexpected result for unknown SHA: $r4"

  # ---- L5-candidates / L5-pass: inheritable lists fail B1s only ----
  local r5 r5p
  r5="$(ledger_call "$c2" "$repo" rtb_ledger_lookup_inheritable "tests/bin/f.sh" 2>/dev/null)"
  r5p="$(ledger_call "$c2" "$repo" rtb_ledger_lookup_inheritable "tests/bin/p.sh" 2>/dev/null)"
  printf '%s\n' "$r5" | grep -qx "$LEDGER_SHA_A" && pass "L5-candidates: fail record's B1 is an inheritance candidate" \
    || fail "L5-candidates: expected $LEDGER_SHA_A, got: $r5"
  [ -z "$r5p" ] && pass "L5-pass: a pass record is never an inheritance candidate" \
    || fail "L5-pass: pass record offered for inheritance: $r5p"

  # ---- L6-corrupt: broken lines are skipped, valid ones still read ----
  local c6="$TMPROOT/cache-l6" dir6 host6 r6
  mkdir -p "$c6"
  ledger_call "$c6" "$repo" rtb_ledger_append "$LEDGER_SHA_A" "$t" fail >/dev/null 2>&1
  seg="$(ledger_segments "$c6" | head -1)"
  if [ -n "$seg" ]; then
    dir6="$(dirname "$seg")"; host6="$(head -1 "$seg" | cut -f3)"
    # A v1 line is now another version: kept in the file, never read as a verdict.
    printf 'garbage\nv2\tnot-a-sha\nv9\t%s\t%s\t%s\tpass\t1\t%s\nv1\t%s\t%s\t%s\tpass\t1\n' \
      "$LEDGER_SHA_A" "$host6" "$t" "$LEDGER_ATTR" "$LEDGER_SHA_A" "$host6" "$t" \
      > "$dir6/v2.$host6-1-1.seg"
    r6="$(ledger_call "$c6" "$repo" rtb_ledger_lookup_same_base "$LEDGER_SHA_A" "$t" 2>/dev/null)"
    [ "$r6" = "fail" ] && pass "L6-corrupt: corrupt/foreign-version lines skipped" \
      || fail "L6-corrupt: expected fail despite corrupt segment, got: $r6"
  else
    fail "L6-corrupt: append wrote no segment"
  fi

  # ---- L6-unwritable: a write failure warns and lets the caller continue ----
  local c6u="$TMPROOT/cache-l6u-file" out6u
  printf 'not a dir\n' > "$c6u"
  out6u="$( (cd "$repo" && export RUN_ALL_CACHE_DIR="$c6u" && run_with_timeout 30 bash -c \
    '. "$1" || exit 98; rtb_ledger_append "$2" "$3" fail; echo CONTINUED' _ \
    "$LEDGER_LIB" "$LEDGER_SHA_A" "$t") 2>&1)"
  if printf '%s\n' "$out6u" | grep -qx CONTINUED && [ "$(printf '%s\n' "$out6u" | grep -vcx CONTINUED)" -ge 1 ]; then
    pass "L6-unwritable: unwritable cache warns on stderr and caller continues"
  else
    fail "L6-unwritable: expected warning + continuation, got: $(printf '%s' "$out6u" | tr '\n' '|')"
  fi
}

# mk_inherit_repo <repo> — main@B1 holds a test that fails unless ./flag-pass exists;
# feature branches from B1, so the first merge-base is B1. Prints B1.
mk_inherit_repo() {
  local repo="$1"
  git init -q "$repo"
  git -C "$repo" config core.hooksPath /dev/null
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" config core.autocrlf false
  git -C "$repo" symbolic-ref HEAD refs/heads/main
  mkdir -p "$repo/tests/bin"
  printf '#!/usr/bin/env bash\n[ -f flag-pass ] && exit 0\nexit 1\n' > "$repo/tests/bin/test-flag.sh"
  chmod +x "$repo/tests/bin/test-flag.sh"
  git -C "$repo" add tests/
  git -C "$repo" commit -q -m "B1"
  git -C "$repo" rev-parse HEAD
  git -C "$repo" checkout -q -b feature
  printf 'feat\n' > "$repo/feat.txt"
  git -C "$repo" add feat.txt
  git -C "$repo" commit -q -m "feature work"
}

# advance_base <repo> <touch-test:0|1> — main gains B2 (descendant of B1) where the
# test would PASS on re-run; feature merges main so the merge-base becomes B2.
advance_base() {
  local repo="$1" touch_test="$2"
  git -C "$repo" checkout -q main
  printf 'x\n' > "$repo/flag-pass"
  git -C "$repo" add flag-pass
  if [ "$touch_test" = "1" ]; then
    printf '# edited between B1 and B2\n' >> "$repo/tests/bin/test-flag.sh"
    git -C "$repo" add tests/bin/test-flag.sh
  fi
  git -C "$repo" commit -q -m "B2"
  git -C "$repo" checkout -q feature
  git -C "$repo" merge -q --no-edit main
}

run_ledger_inherit_cases() {
  if [ ! -f "$BASELINE_CLI" ]; then
    fail "L5-real: bin/run-tests-baseline not found (impl pending)"
    fail "L5b: bin/run-tests-baseline not found (impl pending)"
    return
  fi
  local variant label repo cache b1 b2 t="tests/bin/test-flag.sh"
  for variant in 0 1; do
    if [ "$variant" = "0" ]; then label="L5-real"; else label="L5b"; fi
    repo="$TMPROOT/repo-inherit-$variant"
    cache="$TMPROOT/cache-inherit-$variant"
    mkdir -p "$cache"
    b1="$(mk_inherit_repo "$repo" | head -1)"
    seed_failing "inh${variant}a-$$" "$t"
    rtb_cli_run "$cache" "$repo" "inh${variant}a-$$"
    if ! printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: preexisting[[:space:]]+$t"; then
      fail "$label: seed run at B1 did not classify $t preexisting (rc=$RTB_CLI_RC)"
      continue
    fi
    advance_base "$repo" "$variant"
    b2="$(git -C "$repo" rev-parse main)"
    if [ "$b1" = "$b2" ] || ! git -C "$repo" merge-base --is-ancestor "$b1" "$b2"; then
      fail "$label: fixture error — B2 is not a strict descendant of B1"
      continue
    fi
    seed_failing "inh${variant}b-$$" "$t"
    rtb_cli_run "$cache" "$repo" "inh${variant}b-$$"
    if [ "$variant" = "0" ]; then
      if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: preexisting-inherited[[:space:]]+$t" \
        && [ "$RTB_CLI_RC" -eq 0 ]; then
        pass "$label: B1 fail record inherited at descendant B2 (test unchanged)"
      else
        fail "$label: expected preexisting-inherited + exit 0 at B2, rc=$RTB_CLI_RC out=$(printf '%s' "$RTB_CLI_OUT" | grep '^BASELINE' | tr '\n' '|')"
      fi
    else
      if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: broken[[:space:]]+$t" \
        && ! printf '%s\n' "$RTB_CLI_OUT" | grep -q "inherited[[:space:]]*$t" \
        && [ "$RTB_CLI_RC" -eq 1 ]; then
        pass "$label: test changed B1..B2 → not inherited, re-run classifies broken"
      else
        fail "$label: expected broken (no inheritance) + exit 1, rc=$RTB_CLI_RC out=$(printf '%s' "$RTB_CLI_OUT" | grep '^BASELINE' | tr '\n' '|')"
      fi
    fi
  done
}

# touch_epoch <file> <epoch> — GNU touch first, BSD fallback.
touch_epoch() {
  touch -d "@$2" "$1" 2>/dev/null || touch -t "$(date -r "$2" +%Y%m%d%H%M.%S)" "$1"
}

run_ledger_prune_cases() {
  if [ ! -f "$LEDGER_LIB" ]; then
    fail "L7-lookup-window: ledger lib not found (impl pending)"
    fail "L7-prune: ledger lib not found (impl pending)"
    fail "L7-keep: ledger lib not found (impl pending)"
    return
  fi
  local repo="$TMPROOT/repo-l7" cache="$TMPROOT/cache-l7" t="tests/bin/test-preexisting.sh"
  local sha_now="1111111111111111111111111111111111111111"
  local sha31="3131313131313131313131313131313131313131"
  local sha29="2929292929292929292929292929292929292929"
  mk_fixture_repo "$repo" >/dev/null
  mkdir -p "$cache"
  ledger_call "$cache" "$repo" rtb_ledger_append "$sha_now" "$t" fail >/dev/null 2>&1
  local seg
  seg="$(ledger_segments "$cache" | head -1)"
  if [ -z "$seg" ]; then
    fail "L7-lookup-window: rtb_ledger_append wrote no segment under baseline/"
    fail "L7-prune: no segment directory to seed"
    fail "L7-keep: no segment directory to seed"
    return
  fi
  local dir host now e31 e29 seg31 seg29
  dir="$(dirname "$seg")"
  host="$(head -1 "$seg" | cut -f3)"
  now="$(date +%s)"
  e31=$((now - 31 * 86400)); e29=$((now - 29 * 86400))
  seg31="$dir/v2.$host-$e31-31031.seg"; seg29="$dir/v2.$host-$e29-29029.seg"
  ledger_rec "$sha31" "$host" "$t" fail "$e31" > "$seg31"
  ledger_rec "$sha29" "$host" "$t" fail "$e29" > "$seg29"
  touch_epoch "$seg31" "$e31"
  touch_epoch "$seg29" "$e29"

  local lk
  lk="$(ledger_call "$cache" "$repo" rtb_ledger_lookup_inheritable "$t" 2>/dev/null)"
  if printf '%s' "$lk" | grep -q "$sha29" && ! printf '%s' "$lk" | grep -q "$sha31"; then
    pass "L7-lookup-window: 29-day fail record inheritable, 31-day record not"
  else
    fail "L7-lookup-window: expected $sha29 only, got: $(printf '%s' "$lk" | tr '\n' ' ')"
  fi

  ledger_call "$cache" "$repo" rtb_ledger_sweep >/dev/null 2>&1
  if [ ! -e "$seg31" ]; then
    pass "L7-prune: segment older than 30 days removed by sweep"
  else
    fail "L7-prune: 31-day segment still present after rtb_ledger_sweep"
  fi
  if [ -e "$seg29" ]; then
    pass "L7-keep: 29-day segment kept (boundary control)"
  else
    fail "L7-keep: 29-day segment wrongly removed"
  fi
}

# pinned_inheritable <cache> <repo> <now> <path> — inheritable lookup with `date +%s` pinned,
# so a record exactly RETENTION_DAYS old sits on the window edge without a clock race.
pinned_inheritable() {
  (cd "$2" && export RUN_ALL_CACHE_DIR="$1" && run_with_timeout 30 bash -c \
    '. "$1" || exit 98; RTB_FIXED_NOW="$2"
date() { if [ "$*" = "+%s" ]; then printf "%s\n" "$RTB_FIXED_NOW"; else command date "$@"; fi; }
rtb_ledger_lookup_inheritable "$3"' _ "$LEDGER_LIB" "$3" "$4" 2>/dev/null)
}

# L8: the exact 30-day edge. Lookup keeps `epoch >= now - 30d` (inclusive); sweep removes
# segments with `find -mmin +43200` (strictly older), so a boundary-mtime segment is gone
# once any time has passed, while one a minute inside the window survives.
run_ledger_boundary_cases() {
  local repo="$TMPROOT/repo-l8" cache="$TMPROOT/cache-l8" t="tests/bin/test-edge.sh"
  local sha30="3030303030303030303030303030303030303030"
  local sha30p="3131303030303030303030303030303030303030"
  mk_fixture_repo "$repo" >/dev/null
  mkdir -p "$cache"
  ledger_call "$cache" "$repo" rtb_ledger_append "$LEDGER_SHA_A" "tests/bin/other.sh" pass >/dev/null 2>&1
  local seg dir host now e30 lk
  seg="$(ledger_segments "$cache" | head -1)"
  [ -n "$seg" ] || { fail "L8: rtb_ledger_append wrote no segment to seed beside"; return; }
  dir="$(dirname "$seg")"; host="$(head -1 "$seg" | cut -f3)"
  now="$(date +%s)"; e30=$((now - 30 * 86400))
  { ledger_rec "$sha30" "$host" "$t" fail "$e30"; ledger_rec "$sha30p" "$host" "$t" fail "$((e30 - 1))"; } \
    > "$dir/v2.$host-$e30-30030.seg"

  lk="$(pinned_inheritable "$cache" "$repo" "$now" "$t")"
  printf '%s\n' "$lk" | grep -qx "$sha30" \
    && pass "L8-lookup-at-30d: a record exactly 30 days old is still inheritable (inclusive edge)" \
    || fail "L8-lookup-at-30d: expected $sha30 inheritable at the edge, got: $(printf '%s' "$lk" | tr '\n' ' ')"
  printf '%s\n' "$lk" | grep -qx "$sha30p" \
    && fail "L8-lookup-past-30d: a record 30 days + 1s old was offered for inheritance" \
    || pass "L8-lookup-past-30d: a record 30 days + 1s old is outside the window"

  local seg_edge="$dir/v2.$host-$e30-30031.seg" seg_in="$dir/v2.$host-$((e30 + 60))-29959.seg"
  ledger_rec "$sha30" "$host" "$t" fail "$e30" > "$seg_edge"
  ledger_rec "$sha30" "$host" "$t" fail "$((e30 + 60))" > "$seg_in"
  now="$(date +%s)"; e30=$((now - 30 * 86400))
  touch_epoch "$seg_edge" "$e30"
  touch_epoch "$seg_in" "$((e30 + 60))"
  ledger_call "$cache" "$repo" rtb_ledger_sweep >/dev/null 2>&1
  [ ! -e "$seg_edge" ] && pass "L8-sweep-at-30d: a segment whose mtime is on the 30-day edge is swept" \
    || fail "L8-sweep-at-30d: boundary segment survived rtb_ledger_sweep"
  [ -e "$seg_in" ] && pass "L8-sweep-inside: a segment one minute inside 30 days is kept" \
    || fail "L8-sweep-inside: segment 1 minute inside the window was removed"
}

# capped_lookup <cache> <repo> <cap> <sha> <path> — same-base lookup under a segment-read cap.
capped_lookup() {
  (cd "$2" && export RUN_ALL_CACHE_DIR="$1" && run_with_timeout 30 bash -c \
    '. "$1" || exit 98; RTB_LEDGER_MAX_SEGMENTS_READ="$2"; rtb_ledger_lookup_same_base "$3" "$4"' \
    _ "$LEDGER_LIB" "$3" "$4" "$5" 2>/dev/null)
}

# L9: the segment-read cap must drop the OLDEST segments, never the newest verdict.
run_ledger_segment_cap_cases() {
  local repo="$TMPROOT/repo-l9" cache="$TMPROOT/cache-l9" p="tests/bin/test-p.sh" q="tests/bin/test-q.sh"
  mk_fixture_repo "$repo" >/dev/null
  mkdir -p "$cache"
  ledger_call "$cache" "$repo" rtb_ledger_append "$LEDGER_SHA_A" "tests/bin/other.sh" pass >/dev/null 2>&1
  local seg dir host now k e
  seg="$(ledger_segments "$cache" | head -1)"
  [ -n "$seg" ] || { fail "L9: rtb_ledger_append wrote no segment to seed beside"; return; }
  dir="$(dirname "$seg")"; host="$(head -1 "$seg" | cut -f3)"; now="$(date +%s)"
  # Five older segments, oldest first: [P fail + Q fail], 3 filler, [P pass]. With the real
  # segment above that is six; a cap of 3 keeps only the newest three.
  for k in 5 4 3 2 1; do
    e=$((now - k * 100))
    case "$k" in
      5) ledger_rec "$LEDGER_SHA_A" "$host" "$p" fail "$e"; ledger_rec "$LEDGER_SHA_A" "$host" "$q" fail "$e" ;;
      1) ledger_rec "$LEDGER_SHA_A" "$host" "$p" pass "$e" ;;
      *) ledger_rec "$LEDGER_SHA_A" "$host" tests/bin/filler.sh pass "$e" ;;
    esac > "$dir/v2.$host-$e-9$k.seg"
  done
  local r
  r="$(capped_lookup "$cache" "$repo" 3 "$LEDGER_SHA_A" "$p")"
  [ "$r" = "pass" ] && pass "L9-newest-wins: cap 3 over 6 segments still returns the newest pass" \
    || fail "L9-newest-wins: expected pass (newest segment) under cap 3, got: ${r:-<empty>}"
  r="$(capped_lookup "$cache" "$repo" 3 "$LEDGER_SHA_A" "$q")"
  [ -z "$r" ] && pass "L9-oldest-dropped: a record only in the oldest segment is outside the cap" \
    || fail "L9-oldest-dropped: cap override not applied, oldest segment read (got: $r)"
  r="$(capped_lookup "$cache" "$repo" 256 "$LEDGER_SHA_A" "$q")"
  [ "$r" = "fail" ] && pass "L9-control: the oldest record is readable when the cap covers it" \
    || fail "L9-control: expected fail with a wide cap, got: ${r:-<empty>}"
}
