#!/usr/bin/env bash
# tests/feature-1894-comment-block-size/staged-regression.sh
# Tests: bin/review-comment-block-size
# Tags: comment-block-size, staged, git, regression, table-driven, scope:issue-specific, scope:feature-1894, layer:TL2
#
# Part 2 — the two-blob comparison that makes --staged a *regression* check
# rather than an absolute-size check:
#   WARN iff  n_staged > n_head  OR  m_staged > m_head
# (n = number of over-threshold runs, m = longest over-threshold run).
#
# All scenarios are staged into ONE index and judged by a single CLI run, so a
# scenario that leaks into another file is visible as an unexpected WARN.

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
{ pad 20; cmt 10; pad 5; } > "$REG/shrink.sh"          # m: 12 -> 10 (still >= T)
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
assert_eq "R0/rc-is-0-despite-findings" "0" "$CB_RC"

# has_warn <path> -> yes|no
has_warn() {
    if printf '%s\n' "$CB_OUT" | grep -q "^WARN: $1 "; then echo "yes"; else echo "no"; fi
}

echo ""
echo "=== R1: WARN verdict per scenario (both verdicts covered — CPR-ORTH) ==="
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
    "WARN: grow.sh — longest comment run 12 → 15 lines (over-threshold runs 1 → 1)" "$CB_OUT"
assert_contains "R3/count-transition" \
    "WARN: count.sh — longest comment run 12 → 12 lines (over-threshold runs 1 → 2)" "$CB_OUT"
assert_contains "R3/rename-baseline-is-old-path" \
    "WARN: renmod2.sh — longest comment run 12 → 18 lines" "$CB_OUT"
assert_contains "R3/advisory-footer" \
    "WARN findings are advisory only — this check never blocks a commit." "$CB_OUT"

echo ""
echo "=== R4: cross-file extraction is reported at the destination ==="
# dst.sh is a brand-new file: no baseline exists, so it takes the absolute-state
# fallback wording rather than the two-blob transition wording.
assert_contains "R4/dst-absolute-fallback" \
    "WARN: dst.sh — longest comment run 20 lines (no baseline: absolute-state fallback)" "$CB_OUT"

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
assert_absent "R5/no-footer-without-findings" "advisory only" "$CB_OUT"
assert_eq "R5/rc" "0" "$CB_RC"
assert_contains "R5/summary-line" \
    "Staged code files scanned: 1 (extensions: js;sh;py; threshold: >= 10 consecutive comment lines)" \
    "$CB_OUT"
