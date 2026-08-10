#!/usr/bin/env bash
# tests/feature-1894-comment-block-size/degenerate-fallback.sh
# Tests: bin/review-comment-block-size
# Tags: comment-block-size, staged, git, merge, fallback, table-driven, scope:issue-specific, scope:feature-1894, layer:TL2
#
# Part 3 — baseline resolution when HEAD cannot supply one.
#
# Resolution order: HEAD:./<src> -> in-progress heads (MERGE_HEAD up to 8 lines,
# CHERRY_PICK_HEAD, REVERT_HEAD, REBASE_HEAD) -> absolute-state fallback.
#
# Two properties are deliberately separated here (CPR-SC):
#   * the fallback is UNCONDITIONAL — an in-progress merge never suppresses it;
#   * an in-progress head is header-INFORMATIONAL, but its blob is still a real
#     baseline when it has one.
# When one path exists on more than one candidate, the ORDER above is the whole
# observable — D3 stages such a path with candidates that disagree.
# A blob that exists but cannot be read is an ERROR (rc 3), never degenerate —
# on the baseline side (D4) and on the staged side (D5) alike.

fpad() { local n="$1" i; for ((i = 1; i <= n; i++)); do echo "code_$i=$i"; done; }
fcm() { local n="$1" tag="$2" i; for ((i = 1; i <= n; i++)); do echo "# $tag $i"; done; }

echo ""
echo "=== D1: unborn HEAD — every staged file is degenerate ==="
UNBORN="$TMPDIR_BASE/unborn"
init_repo "$UNBORN"
{ fpad 5; fcm 12 alpha; } > "$UNBORN/new.sh"
{ fpad 5; fcm 5 beta; } > "$UNBORN/small.sh"
git -C "$UNBORN" add -A >/dev/null 2>&1
run_cb "$UNBORN" -- --staged
assert_eq "D1/rc" "0" "$CB_RC"
assert_eq "D1/header-plain-staged-mode" \
    "## Comment-block Size Review: PERFORMED (staged mode)" "$(cb_header)"
assert_contains "D1/over-threshold-warns" \
    "WARN: new.sh — longest comment run 12 lines (no baseline: absolute-state fallback)" "$CB_OUT"
assert_absent "D1/sub-threshold-silent" "WARN: small.sh" "$CB_OUT"

echo ""
echo "=== D2: in-progress head is header-informational (all four heads) ==="
HDR="$(new_repo hdr)"
{ fpad 20; fcm 3 note; } > "$HDR/plain.sh"
git -C "$HDR" add -A >/dev/null 2>&1
HDR_SHA="$(git -C "$HDR" rev-parse HEAD)"
while IFS='|' read -r name reffile label; do
    [ -z "${name//[[:space:]]/}" ] && continue
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    reffile="${reffile//[[:space:]]/}"
    label="${label//[[:space:]]/}"
    rm -f "$HDR/.git/MERGE_HEAD" "$HDR/.git/CHERRY_PICK_HEAD" \
          "$HDR/.git/REVERT_HEAD" "$HDR/.git/REBASE_HEAD"
    printf '%s\n' "$HDR_SHA" > "$HDR/.git/$reffile"
    run_cb "$HDR" -- --staged
    assert_eq "D2/$name" \
        "## Comment-block Size Review: PERFORMED (staged mode, $label in progress)" "$(cb_header)"
done <<'TABLE'
merge-head       | MERGE_HEAD       | merge
cherry-pick-head | CHERRY_PICK_HEAD | cherry-pick
revert-head      | REVERT_HEAD      | revert
rebase-head      | REBASE_HEAD      | rebase
TABLE
rm -f "$HDR/.git/MERGE_HEAD" "$HDR/.git/CHERRY_PICK_HEAD" \
      "$HDR/.git/REVERT_HEAD" "$HDR/.git/REBASE_HEAD"

echo ""
echo "=== D3: MERGE_HEAD parents supply baselines; genuinely new files still warn ==="
MRG="$(new_repo mrg)"
git -C "$MRG" checkout -q -b p1
{ fpad 20; fcm 12 par; } > "$MRG/onparent.sh"
{ fpad 20; fcm 12 par; } > "$MRG/onparent2.sh"
# Present on BOTH parents with DIFFERENT blobs — the only shape that can prove
# WHICH candidate the resolution order picks. A path unique to one parent cannot:
# it passes whether the lookup is ordered or merely exhaustive.
{ fpad 20; fcm 12 both; } > "$MRG/onboth.sh"                    # p1: longest 12
{ fpad 10; fcm 12 b2; fpad 10; } > "$MRG/onboth2.sh"            # p1: 1 run
git -C "$MRG" add -A >/dev/null 2>&1
git -C "$MRG" commit -q -m "p1"
P1_SHA="$(git -C "$MRG" rev-parse HEAD)"
git -C "$MRG" checkout -q main
git -C "$MRG" checkout -q -b p2
{ fpad 20; fcm 12 par3; } > "$MRG/onparent3.sh"
{ fpad 20; fcm 12 par4; } > "$MRG/onparent4.sh"
{ fpad 20; fcm 30 both; } > "$MRG/onboth.sh"                    # p2: longest 30
{ fpad 10; fcm 12 b2; fpad 10; fcm 12 b2; fpad 5; } > "$MRG/onboth2.sh"  # p2: 2 runs
git -C "$MRG" add -A >/dev/null 2>&1
git -C "$MRG" commit -q -m "p2"
P2_SHA="$(git -C "$MRG" rev-parse HEAD)"
git -C "$MRG" checkout -q main
printf '%s\n%s\n' "$P1_SHA" "$P2_SHA" > "$MRG/.git/MERGE_HEAD"

{ fpad 20; fcm 12 par; }  > "$MRG/onparent.sh"    # identical to the p1 blob
{ fpad 20; fcm 18 par; }  > "$MRG/onparent2.sh"   # grown vs the p1 blob (12 -> 18)
{ fpad 20; fcm 12 par3; } > "$MRG/onparent3.sh"   # identical to the p2 blob
{ fpad 20; fcm 21 par4; } > "$MRG/onparent4.sh"   # grown vs the p2 blob (12 -> 21)
# Staged longest 20: grown against the p1 blob (12), shrunk against the p2 blob
# (30). The two candidates give OPPOSITE verdicts, so the WARN itself names the
# winner — MERGE_HEAD line 1 (p1) per the documented resolution order.
{ fpad 20; fcm 20 both; } > "$MRG/onboth.sh"
# Same idea on the run-COUNT axis: byte-identical to the p2 blob (2 runs), and a
# count increase against the p1 blob (1 run -> 2 runs).
{ fpad 10; fcm 12 b2; fpad 10; fcm 12 b2; fpad 5; } > "$MRG/onboth2.sh"
{ fpad 7; fcm 12 fresh; } > "$MRG/brandnew.sh"    # on no parent at all
git -C "$MRG" add -A >/dev/null 2>&1
run_cb "$MRG" -- --staged

assert_eq "D3/rc" "0" "$CB_RC"
assert_eq "D3/header-merge-in-progress" \
    "## Comment-block Size Review: PERFORMED (staged mode, merge in progress)" "$(cb_header)"
while IFS='|' read -r name path want; do
    [ -z "${name//[[:space:]]/}" ] && continue
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    path="${path//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    if printf '%s\n' "$CB_OUT" | grep -q "^WARN: $path "; then got="yes"; else got="no"; fi
    assert_eq "D3/$name" "$want" "$got"
done <<'TABLE'
first-parent-baseline-unchanged  | onparent.sh  | no
first-parent-baseline-grown      | onparent2.sh | yes
second-parent-baseline-unchanged | onparent3.sh | no
second-parent-baseline-grown     | onparent4.sh | yes
same-path-on-both-parents-length | onboth.sh    | yes
same-path-on-both-parents-count  | onboth2.sh   | yes
new-on-every-parent-still-warns  | brandnew.sh  | yes
TABLE
assert_contains "D3/parent-baseline-transition" \
    "WARN: onparent2.sh — longest comment run 12 → 18 lines" "$CB_OUT"
# The decisive one: onparent4.sh exists on the SECOND merge parent only. A
# reported 12 → 21 proves the baseline came from that parent — a first-parent
# -only lookup would have found no blob and printed the absolute-state form.
assert_contains "D3/second-parent-supplies-the-baseline" \
    "WARN: onparent4.sh — longest comment run 12 → 21 lines" "$CB_OUT"
assert_absent "D3/second-parent-not-treated-as-new" \
    "WARN: onparent4.sh — longest comment run 21 lines (no baseline" "$CB_OUT"
assert_contains "D3/unconditional-absolute-fallback" \
    "WARN: brandnew.sh — longest comment run 12 lines (no baseline: absolute-state fallback)" "$CB_OUT"

# --- which candidate wins when the SAME path lives on more than one parent ---
# Documented order: HEAD:./<src> -> in-progress heads (MERGE_HEAD lines, in file
# order) -> absolute-state fallback. onboth.sh is absent from HEAD, so the first
# MERGE_HEAD line (p1) must supply the baseline.
assert_contains "D3/both-parents-first-line-wins-on-length" \
    "WARN: onboth.sh — longest comment run 12 → 20 lines" "$CB_OUT"
assert_absent "D3/both-parents-second-line-did-not-win" \
    "WARN: onboth.sh — longest comment run 30 → 20 lines" "$CB_OUT"
assert_absent "D3/both-parents-not-degenerate" \
    "WARN: onboth.sh — longest comment run 20 lines (no baseline" "$CB_OUT"
assert_contains "D3/both-parents-first-line-wins-on-count" \
    "WARN: onboth2.sh — longest comment run 12 → 12 lines (over-threshold runs 1 → 2)" "$CB_OUT"
assert_eq "D3/exactly-5-warn-lines" "5" "$(cb_warn_count)"

echo ""
echo "=== D4: baseline exists but is unreadable -> ERROR (rc 3), not degenerate ==="
ERRREPO="$(new_repo errblob)"
{ fpad 20; fcm 12 note; } > "$ERRREPO/broken.sh"
git -C "$ERRREPO" add -A >/dev/null 2>&1
git -C "$ERRREPO" commit -q -m "baseline"
BLOB="$(git -C "$ERRREPO" rev-parse "HEAD:./broken.sh" 2>/dev/null || true)"
{ fpad 20; fcm 18 note; } > "$ERRREPO/broken.sh"
git -C "$ERRREPO" add -A >/dev/null 2>&1
if [ -n "$BLOB" ] && [ -f "$ERRREPO/.git/objects/${BLOB:0:2}/${BLOB:2}" ]; then
    rm -f "$ERRREPO/.git/objects/${BLOB:0:2}/${BLOB:2}"
fi
if git -C "$ERRREPO" show "HEAD:./broken.sh" >/dev/null 2>&1; then
    skip "D4: could not make the HEAD blob unreadable in this environment"
else
    run_cb "$ERRREPO" -- --staged
    assert_eq "D4/rc-is-3" "3" "$CB_RC"
    assert_contains "D4/error-line" "ERROR: broken.sh" "$CB_OUT"
    assert_contains "D4/header-incomplete" \
        "## Comment-block Size Review: PERFORMED (staged mode, incomplete: 1 file(s) unreadable)" \
        "$CB_OUT"
fi

echo ""
echo "=== D5: unreadable STAGED blob -> ERROR (rc 3), siblings still reported ==="
# D4 breaks the baseline side. The staged side is the symmetric half (CPR-ORTH):
# it is read through the same `git show` seam, and the same rule applies —
# "exists but unreadable" is an internal error, never a degenerate fallback.
# The sibling file proves the error is per-file: one bad blob must not silently
# discard the findings the scanner already has.
SERR="$(new_repo errstaged)"
{ fpad 5; fcm 12 note; } > "$SERR/badstage.sh"
{ fpad 5; fcm 14 note; } > "$SERR/goodstage.sh"
git -C "$SERR" add -A >/dev/null 2>&1
SBLOB="$(git -C "$SERR" rev-parse ":badstage.sh" 2>/dev/null || true)"
if [ -n "$SBLOB" ] && [ -f "$SERR/.git/objects/${SBLOB:0:2}/${SBLOB:2}" ]; then
    rm -f "$SERR/.git/objects/${SBLOB:0:2}/${SBLOB:2}"
fi
if git -C "$SERR" show ":./badstage.sh" >/dev/null 2>&1; then
    skip "D5: could not make the staged blob unreadable in this environment"
else
    run_cb "$SERR" -- --staged
    assert_eq "D5/rc-is-3" "3" "$CB_RC"
    assert_contains "D5/error-line" "ERROR: badstage.sh" "$CB_OUT"
    assert_contains "D5/header-incomplete" \
        "## Comment-block Size Review: PERFORMED (staged mode, incomplete: 1 file(s) unreadable)" \
        "$CB_OUT"
    # Findings for the readable sibling survive the error.
    assert_contains "D5/sibling-finding-still-on-stdout" \
        "WARN: goodstage.sh — longest comment run 14 lines (no baseline: absolute-state fallback)" \
        "$CB_OUT"
fi
