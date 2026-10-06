# Tests: bin/verify-case-embed.sh
# Tags: TL2, sweep-tests, verifier, scope:common
# Fixture before/after test files for the verifier cases, written into $WD. Every marker
# lives in a heredoc body, so this file itself carries none. Each fixture sources the
# shared harness relative to its own location, so it runs once placed at
# tests/bin/<name>.sh inside a fixture checkout. Sourced by the dispatcher.

# before — the pre-rewrite file: no markers, two assertions, the conventional trailer.
cat >"$WD/before.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: TL2, scope:common
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../tests/lib/harness.sh"
pass "a works"
pass "b works"
echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
FX

# before-nores — the same assertions without a Results line (counts unavailable).
cat >"$WD/before-nores.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: TL2, scope:common
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../tests/lib/harness.sh"
pass "a works"
pass "b works"
exit "$FAIL"
FX

# good — the faithful rewrite: one case per header token, same assertions.
cat >"$WD/good.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: TL2, scope:common
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../tests/lib/harness.sh"

case_begin "a" "bin/a.sh"
pass "a works"
case_end

case_begin "b" "bin/b.sh"
pass "b works"
case_end

echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
FX

# good-fails — conforming, but an assertion now fails (class pass -> fail).
cat >"$WD/good-fails.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: TL2, scope:common
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../tests/lib/harness.sh"

case_begin "a" "bin/a.sh"
pass "a works"
case_end

case_begin "b" "bin/b.sh"
fail "b works" "broken by the rewrite"
case_end

echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
FX

# good-three — conforming and passing, but one assertion more (count differs).
cat >"$WD/good-three.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: TL2, scope:common
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../tests/lib/harness.sh"

case_begin "a" "bin/a.sh"
pass "a works"
pass "a works twice"
case_end

case_begin "b" "bin/b.sh"
pass "b works"
case_end

echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
FX

# slow — conforming, but sleeps past a 2-second launch timeout.
cat >"$WD/slow.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: TL2, scope:common
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../tests/lib/harness.sh"
sleep 8

case_begin "a" "bin/a.sh"
pass "a works"
case_end

case_begin "b" "bin/b.sh"
pass "b works"
case_end

echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
FX

# killme-after — conforming, sleeps long enough for the kill case to catch the after run.
cat >"$WD/killme-after.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: TL2, scope:common
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../tests/lib/harness.sh"
sleep 6

case_begin "a" "bin/a.sh"
pass "a works"
case_end

case_begin "b" "bin/b.sh"
pass "b works"
case_end

echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
FX

# malformed — an indented marker (grammar).
cat >"$WD/malformed.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: TL2, scope:common
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../tests/lib/harness.sh"
  case_begin "a" "bin/a.sh"
pass "a works"
case_end
echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
FX

# uncertain2 / uncertain1 — a quote risk then a marker inside an if block (state
# uncertain), with two header paths and with one.
cat >"$WD/uncertain2.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: TL2, scope:common
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../tests/lib/harness.sh"
echo "multi
line"
if true; then
case_begin "a" "bin/a.sh"
pass "a works"
case_end
fi
echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
FX
cat >"$WD/uncertain1.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh
# Tags: TL2, scope:common
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../tests/lib/harness.sh"
echo "multi
line"
if true; then
case_begin "a" "bin/a.sh"
pass "a works"
case_end
fi
echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
FX

# leftover — good plus a top-level function nothing calls any more.
cat >"$WD/leftover.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: TL2, scope:common
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../tests/lib/harness.sh"
orphan_fn() { echo orphan; }

case_begin "a" "bin/a.sh"
pass "a works"
case_end

case_begin "b" "bin/b.sh"
pass "b works"
case_end

echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
FX

# deleted-not-target / deleted-is-target — bin/gone.sh is absent from the checkout; its
# token stays in H, so a case must target it.
cat >"$WD/deleted-not-target.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/gone.sh
# Tags: TL2, scope:common
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../tests/lib/harness.sh"

case_begin "a" "bin/a.sh"
pass "a works"
case_end

echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
FX
cat >"$WD/deleted-is-target.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/gone.sh
# Tags: TL2, scope:common
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../tests/lib/harness.sh"

case_begin "a" "bin/a.sh"
pass "a works"
case_end

case_begin "gone" "bin/gone.sh"
pass "gone was covered"
case_end

echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
FX

# target-not-in-header — a case targets bin/c.sh, which the header does not name.
cat >"$WD/target-not-in-header.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: TL2, scope:common
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../tests/lib/harness.sh"

case_begin "a" "bin/a.sh"
pass "a works"
case_end

case_begin "b" "bin/b.sh"
pass "b works"
case_end

case_begin "c" "bin/c.sh"
pass "c works"
case_end

echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
FX

# merged-abc — header a,b,c; case "ab" merged onto bin/a.sh, case "c" targets bin/c.sh.
cat >"$WD/merged-abc.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh, bin/c.sh
# Tags: TL2, scope:common
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../tests/lib/harness.sh"

case_begin "ab" "bin/a.sh"
pass "a and b work together"
case_end

case_begin "c" "bin/c.sh"
pass "c works"
case_end

echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
FX

# merged-csv — header a,b,c; one case "abc" merged onto bin/a.sh (two dropped tokens).
cat >"$WD/merged-csv.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh, bin/c.sh
# Tags: TL2, scope:common
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../tests/lib/harness.sh"

case_begin "abc" "bin/a.sh"
pass "a, b and c work together"
case_end

echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
FX

# merged-missing — header a,b,c; case "ab" onto bin/a.sh; bin/c.sh is nowhere.
cat >"$WD/merged-missing.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh, bin/c.sh
# Tags: TL2, scope:common
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../tests/lib/harness.sh"

case_begin "ab" "bin/a.sh"
pass "a and b work together"
case_end

echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
FX

# no-harness — conforming markers, but its own reporters instead of the shared harness.
cat >"$WD/no-harness.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: TL2, scope:common
PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

case_begin "a" "bin/a.sh"
pass "a works"
case_end

case_begin "b" "bin/b.sh"
pass "b works"
case_end

echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
FX

# unguarded — sources the shared harness, then resets its counters unguarded.
cat >"$WD/unguarded.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: TL2, scope:common
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../tests/lib/harness.sh"
PASS=0

case_begin "a" "bin/a.sh"
pass "a works"
case_end

case_begin "b" "bin/b.sh"
pass "b works"
case_end

echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
FX

# Merged reports: name|MERGED_TARGET line (\t as <TAB>, empty = an empty report).
while IFS='|' read -r rname rline; do
  [ -n "$rname" ] || continue
  printf '%s\n' "${rline//<TAB>/$T}" >"$WD/report-$rname.txt"
done <<'ROWS'
ok|MERGED_TARGET<TAB>ab<TAB>bin/a.sh<TAB>bin/b.sh
csv|MERGED_TARGET<TAB>abc<TAB>bin/a.sh<TAB>bin/b.sh,bin/c.sh
kept-not-target|MERGED_TARGET<TAB>ab<TAB>bin/c.sh<TAB>bin/b.sh
unknown-case|MERGED_TARGET<TAB>zz<TAB>bin/a.sh<TAB>bin/b.sh
dropped-not-in-header|MERGED_TARGET<TAB>ab<TAB>bin/a.sh<TAB>bin/z.sh
dropped-is-target|MERGED_TARGET<TAB>ab<TAB>bin/a.sh<TAB>bin/c.sh
ROWS
: >"$WD/report-empty.txt"
