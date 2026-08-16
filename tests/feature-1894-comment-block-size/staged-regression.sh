#!/usr/bin/env bash
# tests/feature-1894-comment-block-size/staged-regression.sh
# Tests: bin/review-comment-block-size
# Tags: comment-block-size, staged, git, regression, table-driven, scope:issue-specific, scope:feature-1894, layer:TL2

# Part 2 — the two-blob comparison that makes --staged a *regression* check,
# not an absolute-size check: finding iff n_staged>n_head OR m_staged>m_head
# (n = over-threshold run count, m = longest over-threshold run; strictly
# `run > T`, so a run of exactly T contributes to neither). --staged is the
# BLOCKING mode: findings prefix `BLOCK: `, CLI exits 1 — never hardcoded
# here, $CB_FIND carries it, so cases keep working if re-run under --all.
# All scenarios stage into ONE index and one CLI run, so a scenario leaking
# into another file shows up as an unexpected finding.

REG="$(new_repo reg)"

pad() { local n="$1" i; for ((i = 1; i <= n; i++)); do echo "code_$i=$i"; done; }
cmt() { local n="$1" i; for ((i = 1; i <= n; i++)); do echo "# note $i"; done; }
# Deliberately disjoint text for the extraction destination: dst.sh is an ADDED
# path in the same diff as the DELETED del.sh, and `-M` would happily pair them
# as a rename if their contents overlapped — which would silently change the
# baseline this case is about.
dpad() { local n="$1" i; for ((i = 1; i <= n; i++)); do echo "zeta_$i()"; done; }
dcmt() { local n="$1" i; for ((i = 1; i <= n; i++)); do echo "// extracted detail $i"; done; }

# --- HEAD state -------------------------------------------------------------
mkdir -p "$REG/node_modules" "$REG/_archive"
for f in same grow shrink move count del; do
    { pad 20; cmt 12; pad 5; } > "$REG/$f.sh"
done
{ pad 20; cmt 3; pad 5; } > "$REG/sub.sh"
{ pad 40; cmt 20; pad 40; } > "$REG/src.sh"
{ pad 40; cmt 12; pad 40; } > "$REG/ren.sh"
{ pad 40; cmt 12; pad 40; } > "$REG/renmod.sh"
{ pad 5; } > "$REG/doc.md"
{ pad 5; } > "$REG/node_modules/vendor.sh"
{ pad 5; } > "$REG/_archive/old.sh"
git -C "$REG" add -A >/dev/null 2>&1
git -C "$REG" commit -q -m "baseline"

# --- staged state -----------------------------------------------------------
{ pad 21; cmt 12; pad 5; } > "$REG/same.sh"            # code-only edit
{ pad 20; cmt 15; pad 5; } > "$REG/grow.sh"            # m: 12 -> 15
{ pad 20; cmt 10; pad 5; } > "$REG/shrink.sh"          # m: 12 -> 10 (now exactly T: allowed)
{ cmt 12; pad 25; } > "$REG/move.sh"                   # same run, new location
{ pad 20; cmt 12; pad 5; cmt 12; } > "$REG/count.sh"   # n: 1 -> 2
{ pad 20; cmt 7; pad 5; } > "$REG/sub.sh"              # 3 -> 7, still sub-threshold
{ pad 40; pad 40; } > "$REG/src.sh"                    # block removed here...
{ dpad 3; dcmt 20; dpad 3; } > "$REG/dst.sh"           # ...and re-appears here
{ cmt 20; } > "$REG/doc.md"                            # non-code extension
{ cmt 25; } > "$REG/node_modules/vendor.sh"            # excluded path
{ cmt 25; } > "$REG/_archive/old.sh"                   # excluded path
git -C "$REG" rm -q del.sh
git -C "$REG" mv ren.sh ren2.sh
git -C "$REG" mv renmod.sh renmod2.sh
{ pad 40; cmt 18; pad 40; } > "$REG/renmod2.sh"        # renamed AND grown
git -C "$REG" add -A >/dev/null 2>&1

run_cb "$REG" -- --staged

echo ""
echo "=== R0: header / exit code ==="
assert_eq "R0/header" "## Comment-block Size Review: PERFORMED (staged mode)" "$(cb_header)"
# Pinned as a literal, not via cb_expect_rc: this is THE rc contract case for
# staged mode, so it must not derive its expectation from the same output it
# is meant to police.
assert_eq "R0/rc-is-1-with-findings" "1" "$CB_RC"

# has_warn <path> -> yes|no
has_warn() {
    if printf '%s\n' "$CB_OUT" | grep -q "^$CB_FIND: $1 "; then echo "yes"; else echo "no"; fi
}

echo ""
echo "=== R1: finding verdict per scenario (both verdicts covered — CPR-ORTH) ==="
while IFS='|' read -r name path want; do
    [ -z "${name//[[:space:]]/}" ] && continue
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    path="${path//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    assert_eq "R1/$name" "$want" "$(has_warn "$path")"
done <<'TABLE'
unchanged-block            | same.sh             | no
longest-run-grew           | grow.sh             | yes
longest-run-shrunk         | shrink.sh           | no
relocated-within-same-file | move.sh             | no
run-count-grew             | count.sh            | yes
sub-threshold-growth       | sub.sh              | no
deleted-file-not-scanned   | del.sh              | no
extraction-source-silent   | src.sh              | no
extraction-destination     | dst.sh              | yes
whole-file-rename          | ren2.sh             | no
rename-plus-growth         | renmod2.sh          | yes
non-code-extension         | doc.md              | no
excluded-node-modules      | node_modules/vendor.sh | no
excluded-archive-dir       | _archive/old.sh     | no
TABLE

echo ""
echo "=== R2: no extra findings leaked ==="
assert_eq "R2/exactly-4-warn-lines" "4" "$(cb_warn_count)"

echo ""
echo "=== R3: finding-line shape ==="
assert_contains "R3/grow-transition" \
    "$CB_FIND: grow.sh — longest comment run 12 → 15 lines (over-threshold runs 1 → 1)" "$CB_OUT"
assert_contains "R3/count-transition" \
    "$CB_FIND: count.sh — longest comment run 12 → 12 lines (over-threshold runs 1 → 2)" "$CB_OUT"
assert_contains "R3/rename-baseline-is-old-path" \
    "$CB_FIND: renmod2.sh — longest comment run 12 → 18 lines" "$CB_OUT"
assert_contains "R3/guidance-footer" \
    "Compress to a one-line summary" "$CB_OUT"
# The advisory disclaimer is the single sentence the WARN→BLOCK conversion
# retires. Its survival anywhere in staged output would be the loudest possible
# contradiction of the rc=1 contract asserted in R0, so it is pinned by absence.
assert_absent "R3/no-advisory-disclaimer" "advisory" "$CB_OUT"
assert_absent "R3/no-never-blocks-claim" "never blocks a commit" "$CB_OUT"

echo ""
echo "=== R4: cross-file extraction is reported at the destination ==="
# dst.sh is a brand-new file: no baseline exists, so it takes the absolute-state
# fallback wording rather than the two-blob transition wording.
assert_contains "R4/dst-absolute-fallback" \
    "$CB_FIND: dst.sh — longest comment run 20 lines (no baseline: absolute-state fallback)" "$CB_OUT"

echo ""
echo "=== R5: clean index emits header + summary only ==="
CLEAN="$(new_repo regclean)"
{ pad 20; cmt 12; pad 5; } > "$CLEAN/keep.sh"
git -C "$CLEAN" add -A >/dev/null 2>&1
git -C "$CLEAN" commit -q -m "baseline"
{ pad 21; cmt 12; pad 5; } > "$CLEAN/keep.sh"
git -C "$CLEAN" add -A >/dev/null 2>&1
run_cb "$CLEAN" -- --staged
assert_eq "R5/no-warn-line" "0" "$(cb_warn_count)"
assert_absent "R5/no-footer-without-findings" "Compress to a one-line summary" "$CB_OUT"
# Symmetric counterpart to R0: staged mode exits 0 when it finds nothing, so
# rc=1 is caused by findings and not by the mode itself.
assert_eq "R5/rc-is-0-without-findings" "0" "$CB_RC"
assert_contains "R5/summary-line" \
    "Staged code files scanned: 1 (extensions: js;sh;py; threshold: > 10 consecutive comment lines)" \
    "$CB_OUT"
