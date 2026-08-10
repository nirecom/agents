#!/usr/bin/env bash
# tests/feature-1894-comment-block-size/config-numeric-caps.sh
# Tests: bin/review-comment-block-size
# Tags: comment-block-size, config, env, numeric-caps, staged, all-scan, boundary, scope:issue-specific, scope:feature-1894, layer:TL2

# Part 10 — the two numeric caps. They are compiled-in constants (_MAX_FILES=200,
# _MAX_BYTES=1000000), not knobs: COMMENT_BLOCK_MAX_FILES / COMMENT_BLOCK_MAX_BYTES
# were removed from the configuration surface so .env.example stays small.

# Two things therefore need pinning, and they fail in opposite directions.
# A cap that drifted off its constant reviews the wrong set while the header
# still prints PERFORMED, so nothing looks broken. A cap that stayed readable
# from the environment hands an ambient variable the power to switch the review
# off — the exact coupling the removal was meant to end. Every boundary below is
# pinned from BOTH sides so no assertion can pass against a scanner that simply
# lost the guard.

# Sourced by the dispatcher after config-hostility.sh, whose cpad/ccm helpers
# build the over-threshold fixture bodies used here.

# mk_sized <path> <total-bytes> <comment-lines> — an over-threshold file padded
# with one long non-comment line to an exact byte count. autocrlf=false is
# pinned in every fixture repo, so the index blob is byte-identical and both
# size readers (`git cat-file -s`, `wc -c`) see the same number.
mk_sized() {
    local p="$1" target="$2" nc="$3" cur pad
    { cpad 2; ccm "$nc" note; } > "$p"
    cur="$(wc -c < "$p" | tr -d '[:space:]')"
    pad=$((target - cur - 1))
    head -c "$pad" /dev/zero 2>/dev/null | tr '\0' 'a' >> "$p"
    printf '\n' >> "$p"
}

# ---------------------------------------------------------------------------
# N1 — the file-count cap sits at exactly 200 (--staged)
# ---------------------------------------------------------------------------
# _MAX_FILES is observable only in --staged: run_all applies no count cap at
# all, so there is no symmetric member to drive. The comparison is
# `n -gt _MAX_FILES`, which makes 200 the last count still reviewed and 201 the
# first one that replaces the whole report with emit_skip.
echo ""
echo "=== N1: file-count cap boundary at the built-in 200 ==="
NFR="$(new_repo maxfilescap)"
{ cpad 2; ccm 12 note; } > "$NFR/f001.sh"
for ((_i = 2; _i <= 200; _i++)); do
    printf -v _nm 'f%03d' "$_i"
    printf 'x_%d=%d\n' "$_i" "$_i" > "$NFR/$_nm.sh"
done
git -C "$NFR" add -A >/dev/null 2>&1

run_cb "$NFR" -- --staged
assert_eq "N1/at-cap-rc" "0" "$CB_RC"
assert_eq "N1/at-cap-header-performed" \
    "## Comment-block Size Review: PERFORMED (staged mode)" "$(cb_header)"
assert_contains "N1/at-cap-whole-index-scanned" "Staged code files scanned: 200" "$CB_OUT"
# Vacuity guard: "200 scanned" would also hold for a run that scanned nothing
# but counted. One fixture carries a real over-threshold block, so a finding
# proves the scan actually opened the blobs.
assert_eq "N1/at-cap-finding-still-emitted" "1" "$(cb_warn_count)"

printf 'x_201=201\n' > "$NFR/f201.sh"
git -C "$NFR" add -A >/dev/null 2>&1
run_cb "$NFR" -- --staged
assert_eq "N1/over-cap-rc" "0" "$CB_RC"
assert_contains "N1/over-cap-header-skipped" "SKIPPED" "$(cb_header)"
assert_contains "N1/over-cap-reason-names-the-count" "too many staged files (201)" "$CB_OUT"
assert_eq "N1/over-cap-emits-no-findings" "0" "$(cb_warn_count)"

# ---------------------------------------------------------------------------
# N2 — COMMENT_BLOCK_MAX_FILES is inert
# ---------------------------------------------------------------------------
# Both directions, because a partial revert can reappear as either one: a value
# that would RAISE the cap must not rescue the 201-file index, and a value that
# would LOWER it must not skip an index the constant admits.
echo ""
echo "=== N2: COMMENT_BLOCK_MAX_FILES no longer steers the verdict ==="
run_cb "$NFR" "COMMENT_BLOCK_MAX_FILES=500" -- --staged
assert_eq "N2/raise-rc" "0" "$CB_RC"
assert_contains "N2/raise-cannot-lift-the-cap" "too many staged files (201)" "$CB_OUT"
assert_eq "N2/raise-emits-no-findings" "0" "$(cb_warn_count)"

SMR="$(new_repo capinert)"
{ cpad 2; ccm 12 note; } > "$SMR/a.sh"
{ cpad 2; ccm 12 note; } > "$SMR/b.sh"
git -C "$SMR" add -A >/dev/null 2>&1
run_cb "$SMR" "COMMENT_BLOCK_MAX_FILES=1" -- --staged
assert_eq "N2/lower-rc" "0" "$CB_RC"
assert_absent "N2/lower-cannot-skip-the-scan" "SKIPPED" "$(cb_header)"
assert_absent "N2/lower-emits-no-file-cap-reason" "too many staged files" "$CB_OUT"
assert_eq "N2/lower-both-files-still-reported" "2" "$(cb_warn_count)"

# ---------------------------------------------------------------------------
# N3 — the byte cap sits at exactly 1000000, and skips one file, not the run
# ---------------------------------------------------------------------------
# Both modes are driven because they read the size through different commands —
# `git cat-file -s` on the index blob in --staged, `wc -c` on the worktree file
# in --all — against the same constant. A cap that drifted in only one of them
# would leave half the tool reviewing the wrong set (CPR-ORTH).
echo ""
echo "=== N3: byte cap boundary at the built-in 1000000 ==="
BYR="$(new_repo maxbytescap)"
mk_sized "$BYR/under.sh" 1000000 12
mk_sized "$BYR/over.sh" 1000001 12
{ cpad 2; ccm 12 note; } > "$BYR/small.sh"
git -C "$BYR" add -A >/dev/null 2>&1

# The boundary is only meaningful if the fixture really straddles it.
assert_eq "N3/fixture-under-is-exactly-at-the-cap" \
    "1000000" "$(wc -c < "$BYR/under.sh" | tr -d '[:space:]')"
assert_eq "N3/fixture-over-is-one-byte-past-the-cap" \
    "1000001" "$(wc -c < "$BYR/over.sh" | tr -d '[:space:]')"
assert_eq "N3/fixture-index-blob-agrees-with-worktree" \
    "1000001" "$(git -C "$BYR" cat-file -s ':./over.sh' 2>/dev/null || true)"

# The mixed fixture is what separates this guard from N1's: an oversized file
# drops out on its own while the rest of the run continues, whereas an oversized
# INDEX aborts everything. A regression that turned the per-file skip into a
# whole-scan abort fails the header and small.sh assertions below.
for _mode in --staged --all; do
    run_cb "$BYR" -- "$_mode"
    assert_eq "N3/${_mode#--}-rc" "0" "$CB_RC"
    assert_absent "N3/${_mode#--}-header-not-skipped" "SKIPPED" "$(cb_header)"
    assert_contains "N3/${_mode#--}-file-at-the-cap-is-scanned" "WARN: under.sh" "$CB_OUT"
    assert_absent "N3/${_mode#--}-file-past-the-cap-not-reported" "WARN: over.sh" "$CB_OUT"
    assert_contains "N3/${_mode#--}-oversized-counted-once" "skipped (too large): 1" "$CB_OUT"
    assert_contains "N3/${_mode#--}-rest-of-the-run-continues" "WARN: small.sh" "$CB_OUT"
    assert_eq "N3/${_mode#--}-exactly-two-findings" "2" "$(cb_warn_count)"
done

# ---------------------------------------------------------------------------
# N4 — COMMENT_BLOCK_MAX_BYTES is inert
# ---------------------------------------------------------------------------
echo ""
echo "=== N4: COMMENT_BLOCK_MAX_BYTES no longer steers the verdict ==="
for _mode in --staged --all; do
    run_cb "$BYR" "COMMENT_BLOCK_MAX_BYTES=2000000" -- "$_mode"
    assert_eq "N4/raise-${_mode#--}-rc" "0" "$CB_RC"
    assert_contains "N4/raise-${_mode#--}-oversized-still-skipped" "skipped (too large): 1" "$CB_OUT"
    assert_absent "N4/raise-${_mode#--}-oversized-still-unreported" "WARN: over.sh" "$CB_OUT"
    assert_eq "N4/raise-${_mode#--}-exactly-two-findings" "2" "$(cb_warn_count)"
done
for _mode in --staged --all; do
    run_cb "$SMR" "COMMENT_BLOCK_MAX_BYTES=1" -- "$_mode"
    assert_eq "N4/lower-${_mode#--}-rc" "0" "$CB_RC"
    assert_absent "N4/lower-${_mode#--}-nothing-skipped-as-too-large" "skipped (too large)" "$CB_OUT"
    assert_eq "N4/lower-${_mode#--}-both-files-still-reported" "2" "$(cb_warn_count)"
done
