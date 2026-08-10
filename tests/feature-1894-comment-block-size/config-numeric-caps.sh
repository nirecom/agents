#!/usr/bin/env bash
# tests/feature-1894-comment-block-size/config-numeric-caps.sh
# Tests: bin/review-comment-block-size
# Tags: comment-block-size, config, env, numeric-caps, staged, all-scan, table-driven, scope:issue-specific, scope:feature-1894, layer:TL2

# Part 10 — the two numeric cap knobs. COMMENT_BLOCK_WARN_LINES is validated
# with the same regex-then-fall-back shape and already owns an invalid-value
# table (scanner-core.sh C2); its symmetric siblings COMMENT_BLOCK_MAX_FILES /
# COMMENT_BLOCK_MAX_BYTES had none (CPR-ORTH gap). A cap that lost its
# fallback fails in the worst direction: the header still prints PERFORMED, so
# nothing looks broken while the review silently reviews nothing.

# Sourced by the dispatcher after config-hostility.sh, whose cpad/ccm helpers
# build the over-threshold fixture bodies used below.

# ---------------------------------------------------------------------------
# C4 — invalid COMMENT_BLOCK_MAX_FILES falls back to the default (200)
# ---------------------------------------------------------------------------
# _MAX_FILES is observable only in --staged mode (--all has no file cap at
# all): a staged-file count above it replaces the entire report with
# emit_skip. The fixture stages 2 files, far under 200, so a working fallback
# is indistinguishable from "no cap" — which is what the vacuity guard at the
# end of the case exists to separate.
echo ""
echo "=== C4: invalid COMMENT_BLOCK_MAX_FILES falls back to the default ==="
MFR="$(new_repo maxfiles)"
{ cpad 2; ccm 12 note; } > "$MFR/a.sh"
{ cpad 2; ccm 12 note; } > "$MFR/b.sh"
git -C "$MFR" add -A >/dev/null 2>&1

while IFS='|' read -r name val; do
    [ -z "${name//[[:space:]]/}" ] && continue
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    val="${val# }"
    val="${val%"${val##*[![:space:]]}"}"
    run_cb "$MFR" "COMMENT_BLOCK_MAX_FILES=$val" -- --staged
    assert_eq "C4/$name-rc" "0" "$CB_RC"
    assert_contains "C4/$name-reports-a.sh" "WARN: a.sh" "$CB_OUT"
    assert_eq "C4/$name-both-files-reported" "2" "$(cb_warn_count)"
    assert_absent "C4/$name-no-file-cap-skip" "too many staged files" "$CB_OUT"
    # emit_skip interpolates its reason into a header joined by an em-dash;
    # the two halves are asserted separately so no assertion depends on that
    # character surviving the host encoding.
    assert_absent "C4/$name-header-not-skipped" "SKIPPED" "$(cb_header)"
done <<'TABLE'
alpha      | abc
negative   | -1
fractional | 1.5
empty      |
TABLE

# Vacuity guard: every absence assertion above would also pass against a
# scanner with no file cap whatsoever. 0 is a VALID value (it matches the
# validating regex, so no fallback applies), which makes it the one input that
# proves the cap is still wired to emit_skip.
run_cb "$MFR" "COMMENT_BLOCK_MAX_FILES=0" -- --staged
assert_eq "C4/cap-zero-rc" "0" "$CB_RC"
assert_contains "C4/cap-zero-header-skipped" "SKIPPED" "$(cb_header)"
assert_contains "C4/cap-zero-reason" "too many staged files" "$CB_OUT"
assert_eq "C4/cap-zero-emits-no-findings" "0" "$(cb_warn_count)"

# Off-by-one pin: the comparison is `n -gt _MAX_FILES`, so a cap EQUAL to the
# staged count must still review, and one below it must skip. The 0-vs-200 span
# above is satisfied by either comparison operator; only this pair is not.
run_cb "$MFR" "COMMENT_BLOCK_MAX_FILES=2" -- --staged
assert_eq "C4/cap-equals-count-rc" "0" "$CB_RC"
assert_absent "C4/cap-equals-count-not-skipped" "SKIPPED" "$(cb_header)"
assert_eq "C4/cap-equals-count-both-files-reported" "2" "$(cb_warn_count)"
run_cb "$MFR" "COMMENT_BLOCK_MAX_FILES=1" -- --staged
assert_contains "C4/cap-below-count-skipped" "too many staged files (2)" "$CB_OUT"

# ---------------------------------------------------------------------------
# C5 — invalid COMMENT_BLOCK_MAX_BYTES falls back to the default (1000000)
# ---------------------------------------------------------------------------
# Both modes are driven for every row because they read the size through
# different commands — `git cat-file -s` on the index blob in --staged,
# `wc -c` on the worktree file in --all — and each compares it against the
# same _MAX_BYTES. A fallback that survived in only one of them would leave
# half the tool skipping every file, so neither mode may stand in for the
# other (CPR-ORTH).
echo ""
echo "=== C5: invalid COMMENT_BLOCK_MAX_BYTES falls back to the default ==="
MBR="$(new_repo maxbytes)"
{ cpad 2; ccm 12 note; } > "$MBR/a.sh"
git -C "$MBR" add -A >/dev/null 2>&1

while IFS='|' read -r name val; do
    [ -z "${name//[[:space:]]/}" ] && continue
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    val="${val# }"
    val="${val%"${val##*[![:space:]]}"}"
    for _mode in --staged --all; do
        run_cb "$MBR" "COMMENT_BLOCK_MAX_BYTES=$val" -- "$_mode"
        assert_eq "C5/$name-${_mode#--}-rc" "0" "$CB_RC"
        assert_contains "C5/$name-${_mode#--}-reports-a.sh" "WARN: a.sh" "$CB_OUT"
        assert_absent "C5/$name-${_mode#--}-not-too-large" "skipped (too large)" "$CB_OUT"
    done
done <<'TABLE'
alpha      | abc
negative   | -1
fractional | 1.5
empty      |
TABLE

# Vacuity guard, same shape as C4's: 1 is a valid cap that the few-hundred-byte
# fixture must exceed, so the too-large branch has to fire in BOTH modes. This
# is also what pins each mode's size source as actually being consulted.
for _mode in --staged --all; do
    run_cb "$MBR" "COMMENT_BLOCK_MAX_BYTES=1" -- "$_mode"
    assert_eq "C5/cap-one-${_mode#--}-rc" "0" "$CB_RC"
    assert_contains "C5/cap-one-${_mode#--}-too-large" "skipped (too large): 1" "$CB_OUT"
    assert_eq "C5/cap-one-${_mode#--}-emits-no-findings" "0" "$(cb_warn_count)"
done

# Off-by-one pin, and a cross-check that the two size sources agree on a byte
# count: the comparison is `sz -gt _MAX_BYTES`, so a cap EQUAL to the fixture's
# size must still review it in both modes, and one below must skip it in both.
MB_SZ="$(wc -c < "$MBR/a.sh" | tr -d '[:space:]')"
for _mode in --staged --all; do
    run_cb "$MBR" "COMMENT_BLOCK_MAX_BYTES=$MB_SZ" -- "$_mode"
    assert_contains "C5/cap-equals-size-${_mode#--}-reports-a.sh" "WARN: a.sh" "$CB_OUT"
    assert_absent "C5/cap-equals-size-${_mode#--}-not-too-large" "skipped (too large)" "$CB_OUT"
    run_cb "$MBR" "COMMENT_BLOCK_MAX_BYTES=$((MB_SZ - 1))" -- "$_mode"
    assert_contains "C5/cap-below-size-${_mode#--}-too-large" "skipped (too large): 1" "$CB_OUT"
done
