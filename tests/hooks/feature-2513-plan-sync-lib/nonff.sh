# Non-fast-forward rebuild, recovery and CAS cases (detail.md S1-7).
# Sourced by ../feature-2513-plan-sync-lib.sh after sync.sh (needs M1, M2, BARE).

echo "=== F3: non-ff rebuild keeps the remote-only file ==="
printf 'X\n' > "$M2/sX-intent.md"
OUT="$(sync_local "$M2" sX-intent.md)"
expect_eq "F3 clone2 pushes X first" "${OUT%%|*}" "pushed"
printf 'T\n' > "$M1/sT-intent.md"
OUT="$(sync_local "$M1" sT-intent.md)"
expect_eq "F3 behind clone still pushes (non-ff path)" "${OUT%%|*}" "pushed"
expect_eq "F3 remote keeps X and gains T" "$(tree_of "$BARE")" \
  ".gitignore s1-intent.md s2-outline.md s3-detail.md sT-intent.md sX-intent.md "
if [ "${OUT%%|*}" = "pushed" ]; then
  no_index_or_checkout "F3 X not checked out locally, no index" "$M1" sX-intent.md
else
  fail "F3 X not checked out locally, no index" "sync did not push: $OUT"
fi

echo "=== F4: non-ff rebuild recovers an earlier failed local commit ==="
mv "$BARE" "$BARE.off"
printf 'Y\n' > "$M1/sY-intent.md"
OUT="$(sync_local "$M1" sY-intent.md)"
mv "$BARE.off" "$BARE"
expect_eq "F4 push fails while the remote is gone" "${OUT%%|*}" "failed"
case "$(tree_of "$M1")" in
  *sY-intent.md*) pass "F4 local main keeps Y after the failed push" ;;
  *) fail "F4 local main keeps Y after the failed push" "local tree: $(tree_of "$M1")" ;;
esac
printf 'Z\n' > "$M2/sZ-intent.md"
expect_eq "F4 clone2 pushes Z" "$(sync_local "$M2" sZ-intent.md | cut -d'|' -f1)" "pushed"
printf 'W\n' > "$M1/sW-intent.md"
OUT="$(sync_local "$M1" sW-intent.md)"
expect_eq "F4 next sync pushes through non-ff" "${OUT%%|*}" "pushed"
TREE="$(tree_of "$BARE")"
MISSING=""
for f in sW-intent.md sX-intent.md sY-intent.md sZ-intent.md sT-intent.md; do
  case " $TREE" in *" $f "*) ;; *) MISSING="$MISSING $f" ;; esac
done
expect_eq "F4 remote holds W, X, Y, Z, T" "${MISSING:-none}" "none"

echo "=== F5: concurrent syncPlanFile calls on one plansDir (CAS) ==="
printf 'C1\n' > "$M1/sC1-intent.md"; printf 'C2\n' > "$M1/sC2-intent.md"
sync_local "$M1" sC1-intent.md > "$PSF_ROOT/f5-C1.out" 2>&1 &
P1=$!
sync_local "$M1" sC2-intent.md > "$PSF_ROOT/f5-C2.out" 2>&1 &
P2=$!
wait "$P1"; wait "$P2"
# A loser may report failed; the contract is that the next call recovers it.
for c in C1 C2; do
  st="$(cut -d'|' -f1 < "$PSF_ROOT/f5-$c.out")"
  [ "$st" = "pushed" ] || sync_local "$M1" "s$c-intent.md" >/dev/null 2>&1
done
TREE="$(tree_of "$BARE")"
case "$TREE" in
  *sC1-intent.md*sC2-intent.md*)
    if [ -e "$M1/.git/index" ]; then fail "F5 both concurrent files reach the remote" ".git/index exists"
    else pass "F5 both concurrent files reach the remote, no .git/index"; fi ;;
  *) fail "F5 both concurrent files reach the remote" "bare tree: $TREE; c1=$(cat "$PSF_ROOT/f5-C1.out") c2=$(cat "$PSF_ROOT/f5-C2.out")" ;;
esac
