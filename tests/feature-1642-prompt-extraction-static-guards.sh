#!/usr/bin/env bash
# tests/feature-1642-prompt-extraction-static-guards.sh
# Tests: .prompt-extraction-allowlist, install/path-exposed-commands.txt, docs/architecture/claude-code/marker-bypass-contract.md, bin/check-prompt-extraction
# Tags: prompt-extraction, allowlist, ratchet, installer, docs, static, scope:issue-specific, scope:feature-1642, layer:TL1
#
# Issue #1642 — static guards for the extraction gate. No temp repos, no CLI
# spawning against fixtures: these assertions run against the real checkout.
#
# The ratchet (T01/T02) is the mechanism that makes the gate *strengthen* over
# time: the committed allowlist may shrink but never grow, so debt can only be
# paid down. Without it the allowlist silently becomes a permanent exemption list.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOWLIST_REL=".prompt-extraction-allowlist"
ALLOWLIST="$AGENTS_DIR/$ALLOWLIST_REL"
CLI="$AGENTS_DIR/bin/check-prompt-extraction"
MERGE_BASE_HELPER="$AGENTS_DIR/bin/resolve-merge-base.sh"
PATH_COMMANDS="$AGENTS_DIR/install/path-exposed-commands.txt"
BYPASS_DOC="$AGENTS_DIR/docs/architecture/claude-code/marker-bypass-contract.md"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

# ---------------------------------------------------------------------------
# The CLI is the single owner of the arithmetic (CPR-2). Its contracted output
# (detail plan C3 決定) is exactly one line:
#
#     TOTAL <n> WILDCARD <m> ENTRIES <e>
#
#   TOTAL    = sum of the <count> field over NON-wildcard entries (not the row count)
#   WILDCARD = number of entries whose <count> is '*'
#   ENTRIES  = total entry rows — DIAGNOSTIC ONLY; the ratchet deliberately does not
#              judge on it, because merging two entries for the same (kind, path)
#              lowers ENTRIES without paying down any debt, and splitting a file
#              raises ENTRIES while TOTAL stays flat. TOTAL and WILDCARD are the
#              only monotonic debt measures.
#
# allowlist_line: reads the allowlist text on stdin, prints the contracted line.
# The awk fallback reproduces it for pre-implementation runs only.
# ---------------------------------------------------------------------------
allowlist_line() {
    if [ -f "$CLI" ]; then
        local out
        out="$(bash "$CLI" --allowlist-total --allowlist-file - 2>/dev/null | grep -m1 '^TOTAL ')"
        if [ -n "$out" ]; then
            echo "$out"
            return 0
        fi
        return 1
    fi
    awk '
        /^[[:space:]]*#/ { next }
        NF < 3           { next }
        { e += 1 }
        $3 == "*"        { w += 1; next }
        $3 ~ /^[0-9]+$/  { t += $3 }
        END              { printf "TOTAL %d WILDCARD %d ENTRIES %d\n", t + 0, w + 0, e + 0 }
    '
}

# allowlist_field <field-name> <line> -> the integer following that field name.
allowlist_field() {
    printf '%s\n' "$2" | awk -v k="$1" '{ for (i = 1; i < NF; i++) if ($i == k) { print $(i + 1); exit } }'
}

resolve_merge_base() {
    if [ -x "$MERGE_BASE_HELPER" ]; then
        bash "$MERGE_BASE_HELPER" -C "$AGENTS_DIR" --format base --no-fetch 2>/dev/null | head -n1
        return 0
    fi
    git -C "$AGENTS_DIR" merge-base HEAD origin/main 2>/dev/null \
        || git -C "$AGENTS_DIR" merge-base HEAD main 2>/dev/null \
        || true
}

# Emits the merge-base version of the allowlist on stdout; returns 1 when the
# file did not exist at the base (first-landing case).
allowlist_at_base() {
    local base="$1"
    [ -n "$base" ] || return 1
    git -C "$AGENTS_DIR" show "$base:$ALLOWLIST_REL" 2>/dev/null
}

# ============================================================================
# T01 / T02 — ratchet
# ============================================================================

BASE_REV=""
BASE_CONTENT=""
BASE_AVAILABLE=0

setup_base() {
    BASE_REV="$(resolve_merge_base)"
    if [ -z "$BASE_REV" ]; then
        return
    fi
    if BASE_CONTENT="$(allowlist_at_base "$BASE_REV")"; then
        BASE_AVAILABLE=1
    fi
}

CUR_LINE=""
BASE_LINE=""

setup_lines() {
    [ -f "$ALLOWLIST" ] || return 0
    CUR_LINE="$(allowlist_line < "$ALLOWLIST")" || CUR_LINE=""
    [ "$BASE_AVAILABLE" -eq 1 ] || return 0
    BASE_LINE="$(printf '%s\n' "$BASE_CONTENT" | allowlist_line)" || BASE_LINE=""
}

# ratchet_check <label> <field> <hint>
# One implementation for both monotonic measures (CPR-4/CPR-5: TOTAL and WILDCARD
# are symmetric members of the same "debt may shrink, never grow" class).
ratchet_check() {
    local label="$1" field="$2" hint="$3"
    if [ ! -f "$ALLOWLIST" ]; then
        skip "$label: $ALLOWLIST_REL not present yet (issue #1642 not implemented)"
        return
    fi
    if [ "$BASE_AVAILABLE" -ne 1 ]; then
        skip "$label: $ALLOWLIST_REL absent from merge-base ${BASE_REV:-<unresolved>} — first landing, nothing to ratchet against"
        return
    fi
    if [ -z "$CUR_LINE" ] || [ -z "$BASE_LINE" ]; then
        fail "$label: could not compute the $field line" "cur='$CUR_LINE' base='$BASE_LINE'"
        return
    fi
    local cur base
    cur="$(allowlist_field "$field" "$CUR_LINE")"
    base="$(allowlist_field "$field" "$BASE_LINE")"
    if [ -z "$cur" ] || [ -z "$base" ]; then
        fail "$label: $field field missing from the --allowlist-total line" \
             "cur='$CUR_LINE' base='$BASE_LINE'"
        return
    fi
    if [ "$cur" -le "$base" ]; then
        pass "$label: allowlist $field ratchet holds (base=$base, current=$cur)"
    else
        fail "$label: allowlist $field grew from $base to $cur — the ratchet only allows shrinking" "$hint"
    fi
}

t01_total_ratchet() {
    ratchet_check "T01" "TOTAL" \
        "Extract the offending content instead of raising the allowlist count."
}

t02_wildcard_ratchet() {
    ratchet_check "T02" "WILDCARD" \
        "A '*' entry is an unlimited exemption — new ones must not be introduced."
}

# ============================================================================
# T03 — installer wiring
# ============================================================================

t03_path_exposed() {
    if [ ! -f "$PATH_COMMANDS" ]; then
        skip "T03: install/path-exposed-commands.txt not present"
        return
    fi
    if grep -qx "check-prompt-extraction" "$PATH_COMMANDS"; then
        pass "T03: check-prompt-extraction is PATH-exposed by the installer"
    else
        fail "T03: install/path-exposed-commands.txt lacks a 'check-prompt-extraction' line" \
             "Skills invoke the CLI by bare name; without this line it is unreachable on PATH."
    fi
}

# ============================================================================
# T04 — marker-bypass contract documentation
# ============================================================================

t04_bypass_contract_documented() {
    if [ ! -f "$BYPASS_DOC" ]; then
        skip "T04: docs/architecture/claude-code/marker-bypass-contract.md not present"
        return
    fi
    if grep -qi "prompt-extraction" "$BYPASS_DOC"; then
        pass "T04: marker-bypass-contract.md documents the prompt-extraction backstop"
    else
        fail "T04: marker-bypass-contract.md does not mention prompt-extraction" \
             "The doc is the SSOT for which hooks honour .workflow-off; the new pre-commit backstop must be listed."
    fi
}

# ============================================================================
# T05 — execute bit recorded in the git index
# ============================================================================

t05_cli_mode_100755() {
    if [ ! -f "$CLI" ]; then
        skip "T05: bin/check-prompt-extraction not present yet (issue #1642)"
        return
    fi
    local entry mode
    entry="$(git -C "$AGENTS_DIR" ls-files -s bin/check-prompt-extraction 2>/dev/null)"
    if [ -z "$entry" ]; then
        fail "T05: bin/check-prompt-extraction is not tracked by git" \
             "Run: git add bin/check-prompt-extraction && git update-index --chmod=+x bin/check-prompt-extraction"
        return
    fi
    mode="$(printf '%s\n' "$entry" | awk '{print $1}')"
    if [ "$mode" = "100755" ]; then
        pass "T05: bin/check-prompt-extraction recorded as mode 100755"
    else
        fail "T05: bin/check-prompt-extraction has git mode $mode, expected 100755" \
             "Run: git update-index --chmod=+x bin/check-prompt-extraction (rules/coding.md)"
    fi
}

# ============================================================================
# T06 — --allowlist-total output-format contract (+ ENTRIES diagnostic)
# ============================================================================

t06_total_line_contract() {
    if [ ! -f "$CLI" ]; then
        skip "T06: bin/check-prompt-extraction not present yet (issue #1642)"
        return
    fi
    if [ ! -f "$ALLOWLIST" ]; then
        skip "T06: $ALLOWLIST_REL not present yet (issue #1642 not implemented)"
        return
    fi
    if [ -z "$CUR_LINE" ]; then
        fail "T06: --allowlist-total produced no 'TOTAL ' line for the committed allowlist"
        return
    fi
    # Contracted shape (detail plan C3 決定): TOTAL <n> WILDCARD <m> ENTRIES <e>
    if printf '%s\n' "$CUR_LINE" \
        | grep -qE '^TOTAL [0-9]+ WILDCARD [0-9]+ ENTRIES [0-9]+$'; then
        pass "T06: --allowlist-total emits the contracted 'TOTAL <n> WILDCARD <m> ENTRIES <e>' line"
    else
        fail "T06: --allowlist-total line does not match the contract" \
             "got: '$CUR_LINE' — expected 'TOTAL <n> WILDCARD <m> ENTRIES <e>' (space-separated, no '=')"
        return
    fi
    # ENTRIES is diagnostic only — reported, never ratcheted (see allowlist_line).
    local cur_e base_e
    cur_e="$(allowlist_field ENTRIES "$CUR_LINE")"
    if [ "$BASE_AVAILABLE" -eq 1 ] && [ -n "$BASE_LINE" ]; then
        base_e="$(allowlist_field ENTRIES "$BASE_LINE")"
        echo "    diagnostic: ENTRIES base=$base_e current=$cur_e (not ratcheted by design)"
    else
        echo "    diagnostic: ENTRIES current=$cur_e (no merge-base to compare against)"
    fi
}

setup_base
setup_lines
t01_total_ratchet
t02_wildcard_ratchet
t03_path_exposed
t04_bypass_contract_documented
t05_cli_mode_100755
t06_total_line_contract

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
