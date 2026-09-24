#!/bin/bash
# tests/feature-review-env-example/legacy-prefix-continuation-cases.sh
# Tests: bin/review-env-example
# Tags: env-example, bin, style-check, legacy-prefix, continuation, scope:common
# Sourced by ../feature-review-env-example.sh — helpers come from there.
# The two newest HARD checks and their shared negative control.

# ---------------------------------------------------------------------------
# Case 22: HARD — legacy "What you can (do|'t do):" prefix on a comment line.
# Both spellings live in the same fixture: one finding each proves the single
# regex catches the affirmative and the negative form alike.
# ---------------------------------------------------------------------------
REPO22=$(make_repo)
git -C "$REPO22" checkout -q -b feature22
cat > "$REPO22/.env.example" <<'EOF'
# What you can do: enable widget mode.
# Format: 0 (off) | 1 (on).
MYVAR=0

# What you can't do: change the server-side default.
# Format: 0 (off) | 1 (on).
OTHERVAR=0
EOF
git -C "$REPO22" add "$REPO22/.env.example"
git -C "$REPO22" commit -q -m "add .env.example with legacy What-you-can prefixes"

EXIT_CODE=0
OUTPUT=$(cd "$REPO22" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Case 22: exits 1 for legacy 'What you can ...' prefix"
else
    fail "Case 22: expected exit 1, got $EXIT_CODE. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -E '^HARD:' | grep -q "legacy"; then
    pass "Case 22: HARD finding names the legacy prefix"
else
    fail "Case 22: no HARD: finding mentioning 'legacy'. Output: $OUTPUT"
fi

LEGACY_HITS=$(echo "$OUTPUT" | grep -E '^HARD:' | grep -c "legacy" || true)
if [[ "$LEGACY_HITS" -ge 2 ]]; then
    pass "Case 22: both \"can do:\" and \"can't do:\" spellings are flagged ($LEGACY_HITS findings)"
else
    fail "Case 22: expected >=2 legacy findings (affirmative + negative), got $LEGACY_HITS. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 23: HARD — wrapped continuation line ("#" then 2+ spaces, then content)
# ---------------------------------------------------------------------------
REPO23=$(make_repo)
git -C "$REPO23" checkout -q -b feature23
cat > "$REPO23/.env.example" <<'EOF'
# Enable widget mode.
#   continued here.
# Format: 0 (off) | 1 (on).
MYVAR=0
EOF
git -C "$REPO23" add "$REPO23/.env.example"
git -C "$REPO23" commit -q -m "add .env.example with a wrapped continuation line"

EXIT_CODE=0
OUTPUT=$(cd "$REPO23" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Case 23: exits 1 for a wrapped continuation line"
else
    fail "Case 23: expected exit 1, got $EXIT_CODE. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -E '^HARD:' | grep -q "continuation"; then
    pass "Case 23: HARD finding names the wrapped continuation line"
else
    fail "Case 23: no HARD: finding mentioning 'continuation'. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 24: negative control for both new checks. New-style-only content —
# a category heading (single space after #), a "You can't do:" line, and a
# one-line description inside an #@if windows block — must stay HARD-free.
# ---------------------------------------------------------------------------
REPO24=$(make_repo)
git -C "$REPO24" checkout -q -b feature24
cat > "$REPO24/.env.example" <<'EOF'
# --- Widget behaviour ---

# Enable widget mode.
# You can't do: does not change the server-side default.
# Format: 0 (off) | 1 (on). Default: 0.
MYVAR=0

#@if windows
# Point the widget cache at a Windows path.
# Format: absolute path. Default: empty.
WIDGET_CACHE_DIR=C:\example
#@endif
EOF
git -C "$REPO24" add "$REPO24/.env.example"
git -C "$REPO24" commit -q -m "add new-style .env.example (negative control)"

EXIT_CODE=0
OUTPUT=$(cd "$REPO24" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 24: expected exit 0 for new-style-only content, got $EXIT_CODE. Output: $OUTPUT"
else
    pass "Case 24: exits 0 for new-style-only content"
fi

if echo "$OUTPUT" | grep -qE '^HARD:'; then
    fail "Case 24: new-style content produced a HARD finding (false positive). Output: $OUTPUT"
else
    pass "Case 24: no HARD finding — neither new check false-positives on new-style content"
fi

# ---------------------------------------------------------------------------
# Case 25: the near-miss table for both new regexes. Cases 22-24 pin one clear
# hit and one clear miss each, which any looser regex ("contains What you", "#
# followed by whitespace") would also satisfy. Each row below sits one character
# away from a boundary, so the table is what fixes where the boundary is.
# ---------------------------------------------------------------------------
lpc_probe() {
    local line="$1" repo out probe_exit=0 legacy=no cont=no
    repo=$(make_repo)
    git -C "$repo" checkout -q -b lpc-probe
    printf '%s\n' "$line" '# Format: 0 (off) | 1 (on). Default: 0.' 'MYVAR=0' > "$repo/.env.example"
    git -C "$repo" add ".env.example"
    git -C "$repo" commit -q -m "probe"
    out=$(cd "$repo" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || probe_exit=$?
    if echo "$out" | grep -E '^HARD:' | grep -q 'legacy'; then legacy=yes; fi
    if echo "$out" | grep -E '^HARD:' | grep -q 'continuation'; then cont=yes; fi
    printf 'legacy=%s continuation=%s' "$legacy" "$cont"
}

LPC_REPORT=""
lpc_row() { LPC_REPORT="$LPC_REPORT$1 -> $(lpc_probe "$2")"$'\n'; }

# --- legacy-prefix boundary ---
lpc_row hit-spaced        '# What you can do: enable widget mode.'
lpc_row hit-unspaced      '#What you can do: enable widget mode.'
lpc_row hit-negative-form "# What you can't do: change the server-side default."
lpc_row miss-whatever     '# Whatever you can set here is applied at startup.'
lpc_row miss-not-can      '# What you configure here is the widget display mode.'
lpc_row miss-new-style    "# You can't do: does not change the server-side default."
lpc_row miss-mid-sentence '# The format decides what you can set for this widget.'
# --- wrapped-continuation boundary ---
lpc_row hit-two-spaces    '#  continued from the line above.'
lpc_row miss-one-space    '# One space after the hash is the normal form.'
lpc_row miss-one-tab      $'#\tOne tab is still a single whitespace character.'
lpc_row miss-blank-hash   '#'

LPC_EXPECTED="hit-spaced -> legacy=yes continuation=no
hit-unspaced -> legacy=yes continuation=no
hit-negative-form -> legacy=yes continuation=no
miss-whatever -> legacy=no continuation=no
miss-not-can -> legacy=no continuation=no
miss-new-style -> legacy=no continuation=no
miss-mid-sentence -> legacy=no continuation=no
hit-two-spaces -> legacy=no continuation=yes
miss-one-space -> legacy=no continuation=no
miss-one-tab -> legacy=no continuation=no
miss-blank-hash -> legacy=no continuation=no
"

if [[ "$LPC_REPORT" == "$LPC_EXPECTED" ]]; then
    pass "Case 25: near-miss table — both regexes fire only on the real pattern"
else
    fail "Case 25: near-miss table mismatch.
--- expected ---
$LPC_EXPECTED
--- got ---
$LPC_REPORT"
fi
