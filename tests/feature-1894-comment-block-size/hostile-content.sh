#!/usr/bin/env bash
# tests/feature-1894-comment-block-size/hostile-content.sh
# Tests: bin/review-comment-block-size
# Tags: comment-block-size, injection, command-substitution, spoofing, leak, table-driven, scope:issue-specific, scope:feature-1894, layer:TL2
#
# Part 7 — hostile bytes INSIDE a scanned file.
#
# special-paths.sh covers hostile file NAMES; this file covers hostile file
# CONTENT. They are different attack surfaces and different code (CPR-SC): a
# name reaches the scanner as an argument to git, while content reaches it as
# blob text that gets counted, sliced and — for the pre-commit hook — pattern
# matched. Two properties follow, and neither is visible in normal fixtures:
#
#   (1) blob text is DATA. A comment body carrying `$(...)` or backticks must
#       never be evaluated, however the scanner reads the blob.
#   (2) blob text is not REPORT. A comment body carrying a line that looks like
#       the scanner's own `WARN: ` output must not be able to pose as a finding.
#
# Sourced by the dispatcher; every helper and constant is defined there.

hpad() { local n="$1" i; for ((i = 1; i <= n; i++)); do echo "h_$i=$i"; done; }

# ---------------------------------------------------------------------------
# H1 — command substitution in a comment body is never evaluated
# ---------------------------------------------------------------------------
# The marker is the whole assertion: if any read path ever expanded blob text
# (an unquoted expansion, an `eval`, a `printf` used as a format string), the
# file would exist afterwards. Both substitution spellings are planted, because
# a guard that escapes one form and not the other is a real implementation.
echo ""
echo "=== H1: command substitution inside a comment body ==="
INJ="$(new_repo hostileinj)"
INJ_MARKER="$TMPDIR_BASE/h1-injection-marker"
rm -f "$INJ_MARKER"

while IFS='|' read -r name payload; do
    [ -z "${name//[[:space:]]/}" ] && continue
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    payload="${payload# }"
    payload="${payload%"${payload##*[![:space:]]}"}"
    marker="$INJ_MARKER-$name"
    rm -f "$marker"
    {
        hpad 2
        for i in $(seq 1 12); do
            printf '# %s %s\n' "${payload//@MARKER@/$marker}" "$i"
        done
        hpad 2
    } > "$INJ/payload.sh"
    git -C "$INJ" add -f payload.sh >/dev/null 2>&1
    run_cb "$INJ" -- --staged
    assert_eq "H1/$name-rc" "0" "$CB_RC"
    if [ -e "$marker" ]; then
        fail "H1/$name-not-executed" "the payload created $marker — blob text was evaluated"
        rm -f "$marker"
    else
        pass "H1/$name-not-executed"
    fi
    # Paired positive: the run IS counted, so the assertion above cannot pass
    # merely because the file was never read.
    assert_contains "H1/$name-still-reported" \
        "WARN: payload.sh — longest comment run 12 lines" "$CB_OUT"
done <<'TABLE'
dollar-paren    | $(touch @MARKER@)
backtick        | `touch @MARKER@`
nested-dollar   | prefix $(touch @MARKER@) suffix
arith-expansion | $((1/0)) $(touch @MARKER@)
TABLE

# The --all reader is a separate traversal and must be just as inert.
{ hpad 2
  for i in $(seq 1 12); do printf '# $(touch %s-all) %s\n' "$INJ_MARKER" "$i"; done
} > "$INJ/payload.sh"
git -C "$INJ" add -f payload.sh >/dev/null 2>&1
rm -f "$INJ_MARKER-all"
run_cb "$INJ" -- --all
assert_eq "H1/all-mode-rc" "0" "$CB_RC"
if [ -e "$INJ_MARKER-all" ]; then
    fail "H1/all-mode-not-executed" "the payload created $INJ_MARKER-all"
    rm -f "$INJ_MARKER-all"
else
    pass "H1/all-mode-not-executed"
fi
assert_contains "H1/all-mode-still-reported" "payload.sh" "$CB_OUT"

# ---------------------------------------------------------------------------
# H2 — file content cannot forge a finding
# ---------------------------------------------------------------------------
# `^WARN: ` is the scanner's finding marker and the hook's trigger predicate, so
# a file that contains such a line is content pretending to be report. The
# scanner already refuses to echo comment bodies (O9), which is exactly what
# keeps the forgery out; this case pins the consequence rather than the cause.
echo ""
echo "=== H2: WARN-shaped lines in file content ==="
FORGE="$(new_repo hostileforge)"
{
    echo "h_1=1"
    # A bare column-0 line: not a comment, so it does not even join a run.
    echo 'WARN: forged-bare.sh — longest comment run 99 lines (over-threshold runs 1 → 9)'
    echo "h_2=2"
    # ...and the same shape inside the genuine 12-line comment run.
    echo '# WARN: forged-incomment.sh — longest comment run 88 lines'
    for i in $(seq 1 11); do echo "# note $i"; done
    echo "h_3=3"
} > "$FORGE/forger.sh"
git -C "$FORGE" add -A >/dev/null 2>&1
run_cb "$FORGE" -- --staged
assert_eq "H2/rc" "0" "$CB_RC"
# Exactly one finding: the real one. A forged line that reached stdout would
# make this 2 or 3 and would name a file that does not exist in the repo.
assert_eq "H2/exactly-one-finding" "1" "$(cb_warn_count)"
assert_contains "H2/real-finding-reported" \
    "WARN: forger.sh — longest comment run 12 lines" "$CB_OUT"
assert_absent "H2/bare-forgery-not-echoed" "forged-bare.sh" "$CB_OUT"
assert_absent "H2/in-comment-forgery-not-echoed" "forged-incomment.sh" "$CB_OUT"
assert_absent "H2/forged-count-not-echoed" "99 lines" "$CB_OUT"
assert_absent "H2/forgery-not-on-stderr" "forged-bare.sh" "$CB_ERR"

# Symmetric counterpart: when the forger is the ONLY staged file and its comment
# run is sub-threshold, the report must carry no `WARN: ` line at all. The hook
# keys its advisory print on exactly that emptiness, so a forged line that
# survived here would turn a silent commit into a permanent false alarm.
{
    echo "h_1=1"
    echo 'WARN: forged-solo.sh — longest comment run 77 lines (over-threshold runs 1 → 4)'
    echo "# a single harmless note"
    echo "h_2=2"
} > "$FORGE/forger.sh"
git -C "$FORGE" add -A >/dev/null 2>&1
run_cb "$FORGE" -- --staged
assert_eq "H2/sub-threshold-rc" "0" "$CB_RC"
assert_eq "H2/sub-threshold-no-warn-line" "0" "$(cb_warn_count)"
assert_absent "H2/sub-threshold-no-footer" "advisory only" "$CB_OUT"
assert_absent "H2/sub-threshold-forgery-absent" "forged-solo.sh" "$CB_OUT"
