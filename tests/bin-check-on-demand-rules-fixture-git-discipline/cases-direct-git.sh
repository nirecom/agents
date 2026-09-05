# shellcheck shell=bash
# Tests: tests/bin-check-on-demand-rules/cases-staged.sh, tests/bin-check-on-demand-rules.sh
# Tags: rules-injection, on-demand-rules, fixtures, git-discipline, static-check, positive-control, TL2, scope:common
# D1 is the rule (no case file calls git itself); D5 proves D1 looked at a full file
# list; D3/D4/D3b are the scanner's own controls, because a scan that finds nothing
# proves nothing about whether it can see anything at all.

echo ""
echo "=== D1: no direct git outside fixtures.sh ==="
d1_cases="$(scan_direct_git "$SUITE_DIR" fixtures.sh)"
d1_disp="$(scan_file_direct_git "$DISPATCHER")"
d1_all="$(printf '%s\n%s\n' "$d1_cases" "$d1_disp" | grep -v '^$' || true)"
if [[ -z "$d1_all" ]]; then
    pass "D1: no case file and not the dispatcher calls git directly"
else
    fail "D1: $(printf '%s\n' "$d1_all" | wc -l | tr -d '[:space:]') direct git call(s) outside fixtures.sh — each must go through fx_stage/fx_ensure_git: $(brief "$d1_all")"
fi


# D5 is D1's anti-vacuity partner. D3 proves the scanner sees a planted call; it says
# nothing about whether D1 pointed the scanner at anything. Rename cases-*.sh, move the
# suite, or break the glob and D1 goes green over an empty file list. The count is exact,
# not a floor: a floor of 8 still goes green after two case files silently vanish. When a
# case file is legitimately added or removed, update D5_EXPECT_FILES in the same commit.
D5_EXPECT_FILES=10
d5_files=$(ls "$SUITE_DIR"/*.sh 2>/dev/null | grep -cv '/fixtures\.sh$' || true)
d5_staged=0
[[ -f "$SUITE_DIR/cases-staged.sh" ]] && d5_staged=1
if [[ "$d5_files" -eq "$D5_EXPECT_FILES" ]] && [[ "$d5_staged" -eq 1 ]]; then
    pass "D5: D1 scanned all $d5_files non-exempt suite files, cases-staged.sh among them"
else
    fail "D5: D1 scanned $d5_files non-exempt file(s), want exactly $D5_EXPECT_FILES (cases-staged.sh present: $d5_staged) — fewer means D1 above is passing over a truncated list; more means a new case file joined the suite and D5_EXPECT_FILES was not updated with it"
fi

echo ""
echo "=== D3/D4/D3b: controls for the D1 scan itself ==="
D3="$WORK/planted"
mkdir -p "$D3"
cat > "$D3/fixtures.sh" <<'EOF'
mk_tree() { git -C "$1" init -q; }
EOF
cat > "$D3/cases-planted.sh" <<'EOF'
# prose that names git -C "$d" add -A and must never be detected
fx_stage "$d" rules/cond.md
git -C "$d" add rules/cond.md >/dev/null 2>&1
EOF
d3_hits="$(scan_direct_git "$D3" fixtures.sh)"
d3_n="$(printf '%s\n' "$d3_hits" | grep -c . || true)"
if [[ "$d3_n" == "1" ]] && printf '%s' "$d3_hits" | grep -Fq 'cases-planted.sh'; then
    pass "D3: the scan fires on exactly the one planted direct call"
else
    fail "D3: want exactly 1 hit naming cases-planted.sh, got $d3_n — $(brief "$d3_hits") (>1 means fixtures.sh or the prose line leaked in; 0 means the scan is blind and D1 is a false green)"
fi

D4="$WORK/clean"
mkdir -p "$D4"
cat > "$D4/fixtures.sh" <<'EOF'
mk_tree() { git -C "$1" init -q; }
git_commit_all() { git -C "$1" commit -q --no-verify -m baseline; }
EOF
cat > "$D4/cases-clean.sh" <<'EOF'
# prose that names git diff --cached and must never be detected
fx_stage "$d" rules/cond.md
git_commit_all "$d"
EOF
d4_hits="$(scan_direct_git "$D4" fixtures.sh)"
if [[ -z "$d4_hits" ]]; then
    pass "D4: the scan stays silent on a tree that only routes through fixtures.sh"
else
    fail "D4: want no hits on a compliant tree, got: $(brief "$d4_hits")"
fi

# D3b is D3 for the two spellings a `git`-only scanner waves through: `git.exe`, which is
# the same binary on #2111's Git Bash host, and the alias assignment that turns every
# later `$GIT add` into an invisible call. Without this control the C8 widening could be
# reverted in scanners.sh and D1/D3/D4 would all stay green.
D3B="$WORK/planted-indirect"
mkdir -p "$D3B"
cat > "$D3B/fixtures.sh" <<'EOF'
mk_tree() { git -C "$1" init -q; }
EOF
cat > "$D3B/cases-exe.sh" <<'EOF'
fx_stage "$d" rules/cond.md
git.exe -C "$d" add rules/cond.md >/dev/null 2>&1
EOF
cat > "$D3B/cases-alias.sh" <<'EOF'
GIT=/usr/bin/git.exe
fx_stage "$d" rules/cond.md
"$GIT" -C "$d" add rules/cond.md >/dev/null 2>&1
EOF
d3b_hits="$(scan_direct_git "$D3B" fixtures.sh)"
d3b_n="$(printf '%s\n' "$d3b_hits" | grep -c . || true)"
d3b_exe=0
d3b_alias=0
printf '%s\n' "$d3b_hits" | grep -Fq 'cases-exe.sh' && d3b_exe=1
printf '%s\n' "$d3b_hits" | grep -Fq 'cases-alias.sh' && d3b_alias=1
if [[ "$d3b_n" == "2" ]] && [[ "$d3b_exe" == "1" ]] && [[ "$d3b_alias" == "1" ]]; then
    pass "D3b: the scan fires on the planted git.exe call and on the planted GIT= alias assignment"
else
    fail "D3b: want 1 hit in each of cases-exe.sh/cases-alias.sh (got $d3b_n hits, exe=$d3b_exe alias=$d3b_alias) — a miss here means D1 is blind to Git-Bash git.exe or to \$GIT indirection: $(brief "$d3b_hits")"
fi
