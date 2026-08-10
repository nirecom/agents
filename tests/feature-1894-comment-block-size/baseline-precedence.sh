#!/usr/bin/env bash
# tests/feature-1894-comment-block-size/baseline-precedence.sh
# Tests: bin/review-comment-block-size
# Tags: comment-block-size, staged, git, baseline, precedence, cherry-pick, revert, rebase, scope:issue-specific, scope:feature-1894, layer:TL2

# Part 12 - which candidate find_baseline actually picks (review concern C3).

# degenerate-fallback.sh D2 pins the four in-progress pseudo-refs as HEADER
# labels, and D3 pins the ORDER among MERGE_HEAD's own lines. Neither pins the
# two facts find_baseline is actually built out of:
#   * a CHERRY_PICK_HEAD / REVERT_HEAD / REBASE_HEAD blob is a real baseline,
#     not merely a label - the verdict changes when it is consulted;
#   * HEAD wins whenever HEAD resolves, whatever the pseudo-refs say.

# find_baseline returns "HEAD:./$src" as soon as HEAD_OK and tree_has HEAD $src
# both hold, and only otherwise iterates BASE_REFS. So the observable split is:
# a path ABSENT from HEAD's tree exposes the in-progress blob (B1/B2), and a path
# PRESENT in both exposes the precedence (B3/B4). Each direction is asserted
# twice with the expected number swapped, so neither can pass by coincidence.

# The arrow in the WARN line is non-ASCII, so every assertion here matches the
# ASCII text before it ("longest comment run <bm> ") or reads the staged-side
# number through the dispatcher's cb_longest helper.

bpad() { local n="$1" i; for ((i = 1; i <= n; i++)); do echo "b_$i=$i"; done; }
bcm() { local n="$1" tag="$2" i; for ((i = 1; i <= n; i++)); do echo "# $tag $i"; done; }

bp_clear() {
    rm -f "$1/.git/MERGE_HEAD" "$1/.git/CHERRY_PICK_HEAD" \
          "$1/.git/REVERT_HEAD" "$1/.git/REBASE_HEAD"
}

# bp_tree <repo> <rev> <path> - what tree_has looks at, spelled the same way.
bp_tree() {
    git -C "$1" ls-tree --name-only "$2" -- ":(literal)$3" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# B1 - an in-progress blob is a real baseline (path absent from HEAD)
# ---------------------------------------------------------------------------
echo ""
echo "=== B1: CHERRY_PICK_HEAD supplies the baseline numbers ==="
BPA="$(new_repo baseabsent)"
{ bpad 5; bcm 12 side; } > "$BPA/b.sh"
git -C "$BPA" add -A >/dev/null 2>&1
git -C "$BPA" commit -q -m "side"
BPA_SIDE="$(git -C "$BPA" rev-parse HEAD)"
git -C "$BPA" rm -q -- b.sh >/dev/null 2>&1
git -C "$BPA" commit -q -m "drop b.sh"

# Fixture premise, asserted rather than assumed: a broken construction here would
# otherwise make every B1/B2 assertion pass for the wrong reason.
assert_eq "B1/premise-head-lacks-the-path" "" "$(bp_tree "$BPA" HEAD b.sh)"
assert_eq "B1/premise-side-commit-has-the-path" "b.sh" "$(bp_tree "$BPA" "$BPA_SIDE" b.sh)"

bp_clear "$BPA"
printf '%s\n' "$BPA_SIDE" > "$BPA/.git/CHERRY_PICK_HEAD"
{ bpad 5; bcm 18 side; } > "$BPA/b.sh"
git -C "$BPA" add -A >/dev/null 2>&1
run_cb "$BPA" -- --staged
assert_eq "B1/rc" "0" "$CB_RC"
assert_contains "B1/reported-at-all" "WARN: b.sh" "$CB_OUT"
assert_contains "B1/baseline-number-comes-from-the-in-progress-blob" \
    "longest comment run 12 " "$CB_OUT"
assert_eq "B1/staged-side-number" "18" "$(cb_longest)"
assert_absent "B1/not-the-absolute-state-fallback" "no baseline" "$CB_OUT"

# ---------------------------------------------------------------------------
# B2 - symmetric direction: consulting that baseline can also SILENCE a file
# ---------------------------------------------------------------------------
# Same fixture, staged content whose runs did not grow against the in-progress
# blob while still sitting far over the threshold in absolute terms. The
# absolute-state fallback would report it, so silence is the proof.
echo ""
echo "=== B2: no growth against the in-progress baseline is silent ==="
{ bpad 5; bcm 12 side; } > "$BPA/b.sh"
git -C "$BPA" add -A >/dev/null 2>&1
run_cb "$BPA" -- --staged
assert_eq "B2/rc" "0" "$CB_RC"
assert_absent "B2/not-reported" "WARN: b.sh" "$CB_OUT"
assert_eq "B2/no-warn-lines-at-all" "0" "$(cb_warn_count)"

# Anti-vacuity for B2: with the pseudo-ref removed there is no baseline left, so
# the very same index must now produce the absolute-state finding. If it does
# not, B2's silence was never attributable to the in-progress baseline.
bp_clear "$BPA"
run_cb "$BPA" -- --staged
assert_eq "B2/without-the-ref-rc" "0" "$CB_RC"
assert_contains "B2/without-the-ref-the-same-index-warns" "WARN: b.sh" "$CB_OUT"
assert_contains "B2/without-the-ref-it-is-the-absolute-state-shape" \
    "longest comment run 12 lines (no baseline: absolute-state fallback)" "$CB_OUT"

# ---------------------------------------------------------------------------
# B3 - HEAD wins when both candidates resolve
# ---------------------------------------------------------------------------
# REVERT_HEAD on purpose: B1 already exercised CHERRY_PICK_HEAD, and the point
# here is the ordering inside find_baseline, not one particular ref file.
echo ""
echo "=== B3: HEAD outranks REVERT_HEAD ==="
BPH="$(new_repo basehead)"
git -C "$BPH" checkout -q -b side
{ bpad 5; bcm 30 alt; } > "$BPH/c.sh"
git -C "$BPH" add -A >/dev/null 2>&1
git -C "$BPH" commit -q -m "alt c.sh (30)"
BPH_ALT="$(git -C "$BPH" rev-parse HEAD)"
git -C "$BPH" checkout -q main
{ bpad 5; bcm 12 head; } > "$BPH/c.sh"
git -C "$BPH" add -A >/dev/null 2>&1
git -C "$BPH" commit -q -m "head c.sh (12)"

assert_eq "B3/premise-head-has-the-path" "c.sh" "$(bp_tree "$BPH" HEAD c.sh)"
assert_eq "B3/premise-alt-commit-has-the-path" "c.sh" "$(bp_tree "$BPH" "$BPH_ALT" c.sh)"

bp_clear "$BPH"
printf '%s\n' "$BPH_ALT" > "$BPH/.git/REVERT_HEAD"
{ bpad 5; bcm 20 head; } > "$BPH/c.sh"
git -C "$BPH" add -A >/dev/null 2>&1
run_cb "$BPH" -- --staged
assert_eq "B3/rc" "0" "$CB_RC"
assert_eq "B3/warn-count-is-1" "1" "$(cb_warn_count)"
assert_contains "B3/head-supplied-the-baseline" "longest comment run 12 " "$CB_OUT"
assert_eq "B3/staged-side-number" "20" "$(cb_longest)"
assert_absent "B3/in-progress-blob-did-not-win" "longest comment run 30 " "$CB_OUT"
bp_clear "$BPH"

# ---------------------------------------------------------------------------
# B4 - same shape, measurements swapped, so the expected number moves
# ---------------------------------------------------------------------------
# HEAD now measures 30 and the in-progress commit 12, and the staged blob is
# larger than both so BOTH candidates would produce a WARN. The only difference
# left is the number that gets printed - which is exactly the thing B3 asserts,
# and the reason a coincidence cannot satisfy both cases.
echo ""
echo "=== B4: HEAD outranks REBASE_HEAD (swapped measurements) ==="
BPS="$(new_repo baseheadswap)"
git -C "$BPS" checkout -q -b side
{ bpad 5; bcm 12 alt; } > "$BPS/d.sh"
git -C "$BPS" add -A >/dev/null 2>&1
git -C "$BPS" commit -q -m "alt d.sh (12)"
BPS_ALT="$(git -C "$BPS" rev-parse HEAD)"
git -C "$BPS" checkout -q main
{ bpad 5; bcm 30 head; } > "$BPS/d.sh"
git -C "$BPS" add -A >/dev/null 2>&1
git -C "$BPS" commit -q -m "head d.sh (30)"

assert_eq "B4/premise-head-has-the-path" "d.sh" "$(bp_tree "$BPS" HEAD d.sh)"
assert_eq "B4/premise-alt-commit-has-the-path" "d.sh" "$(bp_tree "$BPS" "$BPS_ALT" d.sh)"

bp_clear "$BPS"
printf '%s\n' "$BPS_ALT" > "$BPS/.git/REBASE_HEAD"
{ bpad 5; bcm 40 head; } > "$BPS/d.sh"
git -C "$BPS" add -A >/dev/null 2>&1
run_cb "$BPS" -- --staged
assert_eq "B4/rc" "0" "$CB_RC"
assert_eq "B4/warn-count-is-1" "1" "$(cb_warn_count)"
assert_contains "B4/head-supplied-the-baseline" "longest comment run 30 " "$CB_OUT"
assert_eq "B4/staged-side-number" "40" "$(cb_longest)"
assert_absent "B4/in-progress-blob-did-not-win" "longest comment run 12 " "$CB_OUT"
bp_clear "$BPS"
