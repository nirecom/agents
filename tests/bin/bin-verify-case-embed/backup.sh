# --backup-dir: an existing backup is never overwritten, an omitted dir is announced on
# stderr, and a SIGKILL mid-run leaves the backup where stage 3 recovers it.
# Sourced by the dispatcher.

echo ""
echo "=== --backup-dir ==="

case_begin "backup-existing-is-exit-2" "bin/verify-case-embed.sh"
# A non-empty backup left by an interrupted run: exit 2, nothing touched.
V_BK="$(mktemp -d "$TMPBASE/bk.XXXXXX")"
printf 'previous backup\n' >"$V_BK/sample.sh"
vce "$VCO" "$WD/good.sh" --relpath tests/bin/sample.sh --backup-dir "$V_BK"
assert_eq "static rc=$V_RC" "static rc=2"
assert_eq "backup kept: $(cat "$V_BK/sample.sh")" "backup kept: previous backup"
if cmp -s "$VCO/tests/bin/sample.sh" "$WD/before.sh"; then pass "relpath untouched"; else fail "relpath untouched" "content differs"; fi
vce "$VCO" "$WD/good.sh" --relpath tests/bin/sample.sh --before tests/bin/sample.sh --backup-dir "$V_BK"
assert_eq "compare rc=$V_RC" "compare rc=2"
assert_eq "backup still kept: $(cat "$V_BK/sample.sh")" "backup still kept: previous backup"
case_end

case_begin "backup-dir-omitted-is-announced" "bin/verify-case-embed.sh"
# Stand-alone use: a mktemp backup dir, its path printed on stderr for manual recovery.
vce "$VCO" "$WD/good.sh" --relpath tests/bin/sample.sh
assert_eq "rc=$V_RC" "rc=0"
if [ -n "$V_ERR" ]; then pass "backup path announced on stderr"; else fail "backup path announced on stderr" "stderr empty"; fi
if cmp -s "$VCO/tests/bin/sample.sh" "$WD/before.sh"; then pass "relpath restored"; else fail "relpath restored" "content differs"; fi
case_end

case_begin "backup-survives-sigkill" "bin/verify-case-embed/run-compare.sh"
# Kill the whole process group while the after run sleeps: no trap runs, so the backup
# must still be in --backup-dir holding the original, and the relpath the after content.
# Not wrapped in run_with_timeout: timeout(1) takes its own process group.
KREL=tests/bin/killme.sh
V_BK="$(mktemp -d "$TMPBASE/bk.XXXXXX")"
set -m
(cd "$VCO" && exec bash "$VCO/bin/verify-case-embed.sh" "$WD/killme-after.sh" --relpath "$KREL" --before "$KREL" --backup-dir "$V_BK" >/dev/null 2>&1) &
kpid=$!
set +m
reached=no
for _i in $(seq 1 75); do
  if [ -f "$V_BK/killme.sh" ] && cmp -s "$VCO/$KREL" "$WD/killme-after.sh"; then reached=yes; break; fi
  kill -0 "$kpid" 2>/dev/null || break
  sleep 0.2
done
kill -KILL -- "-$kpid" 2>/dev/null || kill -KILL "$kpid" 2>/dev/null
wait "$kpid" 2>/dev/null
assert_eq "after run reached before the kill: $reached" "after run reached before the kill: yes"
if [ "$reached" = yes ]; then
  if cmp -s "$V_BK/killme.sh" "$WD/before.sh"; then pass "backup holds the original"; else fail "backup holds the original" "missing or differs"; fi
  if cmp -s "$VCO/$KREL" "$WD/killme-after.sh"; then pass "relpath still holds after"; else fail "relpath still holds after" "differs"; fi
fi
# Manual recovery, as the stand-alone documentation describes.
cp "$WD/before.sh" "$VCO/$KREL"
rm -f "$V_BK/killme.sh"
case_end
