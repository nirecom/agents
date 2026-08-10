#!/usr/bin/env bash
# tests/feature-1894-comment-block-size/scanner-core.sh
# Tests: bin/review-comment-block-size
# Tags: comment-block-size, parser, table-driven, scope:issue-specific, scope:feature-1894, layer:TL2
#
# Part 1 of tests/feature-1894-comment-block-size.sh — the comment-line
# recognition rule and the run-length decision boundary.
#
# Every case is probed through the contracted CLI output: a NEW file (absent
# from HEAD) is staged, so the scanner falls back to absolute state and reports
#   WARN: probe.sh — longest comment run <N> lines (no baseline: ...)
# The reported <N> is the whole observable under test here.

CORE_REPO="$(new_repo probe)"

# probe_longest <spec> [threshold] -> longest flagged run, or "none"
probe_longest() {
    # ${2-10}: an explicitly-passed empty string must reach the CLI as an empty
    # COMMENT_BLOCK_WARN_LINES (that is its own branch), so ${2:-10} is wrong.
    local spec="$1" t="${2-10}"
    render_spec "$spec" > "$CORE_REPO/probe.sh"
    git -C "$CORE_REPO" add -f probe.sh >/dev/null 2>&1
    run_cb "$CORE_REPO" "COMMENT_BLOCK_WARN_LINES=$t" -- --staged
    cb_longest
}

# ---------------------------------------------------------------------------
# C1 — comment-line rule + run-length boundary (threshold fixed at 10)
# ---------------------------------------------------------------------------
echo ""
echo "=== C1: comment-line rule / run-length boundary (T=10) ==="
while IFS='|' read -r name spec want; do
    [ -z "${name//[[:space:]]/}" ] && continue
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    got="$(probe_longest "$spec")"
    assert_eq "C1/$name" "$want" "$got"
done <<'TABLE'
run-9-silent                  | //a*9 x=1                       | none
run-10-flagged                | //a*10 x=1                      | 10
run-11-flagged                | //a*11 x=1                      | 11
hash-run-10                   | #a*10 x=1                       | 10
shebang-line1-not-counted     | #!/bin/sh #a*9 x=1              | none
shebang-plus-10-flagged       | #!/bin/sh #a*10 x=1             | 10
hashbang-not-on-line1-counts  | x=1 #!/bin/sh #a*9              | 10
leading-whitespace-stripped   | ^^//a*10 x=1                    | 10
mixed-markers-one-run         | //a*5 #b*5 x=1                  | 10
blank-terminates-outside-block| //a*5 _ //a*5 x=1               | none
run-flushed-at-eof            | x=1 //a*10                      | 10
block-open-close              | /*a *b*8 */ x=1                 | 10
block-blank-inside-continues  | /*a *b*4 _ *c*4 */ x=1          | 11
block-unterminated-to-eof     | /*a *b*10                       | 11
block-close-with-trailing-code| /*a *b*9 */^x=1                 | 11
oneline-block-no-block-state  | /*a*/*5 x=1 //b*5               | none
close-marker-at-top-level     | */*10 x=1                       | 10
star-space-is-comment         | *^a*10 x=1                      | 10
star-eol-is-comment           | **10 x=1                        | 10
case-arm-star-paren-not-comment| *)*10 x=1                      | none
star-word-not-comment         | *b*10 x=1                       | none
dashdash-unsupported          | --a*10 x=1                      | none
semicolon-unsupported         | ;a*10 x=1                       | none
percent-unsupported           | %a*10 x=1                       | none
python-triple-quote-unsupported| """*10 x=1                     | none
no-comments-at-all            | x=1*20                          | none
single-line-file              | //a                             | none
TABLE

# ---------------------------------------------------------------------------
# C2 — COMMENT_BLOCK_WARN_LINES branches (config-dependent, pinned per case)
# Invalid values fall back to the default 10 and CONTINUE (they must not skip,
# and must not degrade to a threshold of 1).
# ---------------------------------------------------------------------------
echo ""
echo "=== C2: COMMENT_BLOCK_WARN_LINES branches ==="
while IFS='|' read -r name thr spec want; do
    [ -z "${name//[[:space:]]/}" ] && continue
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    thr="${thr//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    got="$(probe_longest "$spec" "$thr")"
    assert_eq "C2/$name" "$want" "$got"
done <<'TABLE'
t5-run4-silent      | 5   | //a*4 x=1   | none
t5-run5-flagged     | 5   | //a*5 x=1   | 5
t20-run19-silent    | 20  | //a*19 x=1  | none
t20-run20-flagged   | 20  | //a*20 x=1  | 20
t-abc-defaults-10   | abc | //a*10 x=1  | 10
t-abc-9-still-silent| abc | //a*9 x=1   | none
t-zero-defaults-10  | 0   | //a*10 x=1  | 10
t-zero-9-still-silent| 0  | //a*9 x=1   | none
t-negative-defaults-10| -3| //a*10 x=1  | 10
t-empty-defaults-10 |     | //a*10 x=1  | 10
TABLE

# ---------------------------------------------------------------------------
# C3 — hanging L<start>-L<end> detail lines
# ---------------------------------------------------------------------------
echo ""
echo "=== C3: run location detail lines ==="
render_spec "x=1 //a*12 x=1" > "$CORE_REPO/probe.sh"
git -C "$CORE_REPO" add -f probe.sh >/dev/null 2>&1
run_cb "$CORE_REPO" -- --staged
assert_contains "C3/detail-range" "  L2-L13 (12 lines)" "$CB_OUT"
assert_contains "C3/hint-line" \
    "Compress to a one-line summary + a pointer to the authoritative doc (CPR-SSOT)." "$CB_OUT"

# ---------------------------------------------------------------------------
# C4 — file-shape edge cases
# ---------------------------------------------------------------------------
echo ""
echo "=== C4: file-shape edge cases ==="

: > "$CORE_REPO/probe.sh"
git -C "$CORE_REPO" add -f probe.sh >/dev/null 2>&1
run_cb "$CORE_REPO" -- --staged
assert_eq "C4/empty-file-no-finding" "none" "$(cb_longest)"
assert_eq "C4/empty-file-rc" "0" "$CB_RC"

# 12 comment lines, no trailing newline: the final run must still be flushed.
{ for i in $(seq 1 11); do echo "#c$i"; done; printf '#c12'; } > "$CORE_REPO/probe.sh"
git -C "$CORE_REPO" add -f probe.sh >/dev/null 2>&1
run_cb "$CORE_REPO" -- --staged
assert_eq "C4/no-trailing-newline-flushes-run" "12" "$(cb_longest)"

# CRLF line endings must not defeat the "* " / "*/" recognition.
{ for i in $(seq 1 12); do printf '// c%s\r\n' "$i"; done; } > "$CORE_REPO/probe.sh"
git -C "$CORE_REPO" add -f probe.sh >/dev/null 2>&1
run_cb "$CORE_REPO" -- --staged
assert_eq "C4/crlf-line-endings" "12" "$(cb_longest)"
