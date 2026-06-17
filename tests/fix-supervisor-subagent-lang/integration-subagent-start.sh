# integration-subagent-start.sh — Integration tests for hooks/subagent-start.js
# Sourced after helpers.sh; inherits all variables and functions.
#
# Entire file SKIPs when hooks/subagent-start.js does not exist (Phase 2a gate).

if [ ! -f "$SUBAGENT_START" ]; then
    skip "integration-subagent-start: hooks/subagent-start.js missing (Phase 2a not yet adopted) — entire file skipped"
    return 0 2>/dev/null || true
else

# ---------------------------------------------------------------------------
# T5 [Integration] CONV_LANG=japanese → additionalContext carries injection
# ---------------------------------------------------------------------------
T5_RAW=$(printf '{}' | \
    CONV_LANG="japanese" \
    AGENTS_CONFIG_DIR="$EMPTY_CFG" \
    run_with_timeout 30 node "$SUBAGENT_START" 2>/dev/null)
T5_RC=$?
if [ "$T5_RC" -ne 0 ]; then
    fail "T5: subagent-start exited non-zero ($T5_RC) with CONV_LANG=japanese"
else
    T5_CTX=$(node -e "
try {
  const o = JSON.parse(process.argv[1]);
  process.stdout.write(o.additionalContext || '');
} catch (e) {}
" "$T5_RAW" 2>/dev/null)
    if echo "$T5_CTX" | grep -qF "$EXPECTED_JA"; then
        pass "T5: subagent-start CONV_LANG=japanese → additionalContext includes injection"
    else
        fail "T5: additionalContext missing '$EXPECTED_JA' (got raw: $T5_RAW)"
    fi
fi

# ---------------------------------------------------------------------------
# T6 [Integration] CONV_LANG unset → output is {} (no additionalContext)
# ---------------------------------------------------------------------------
T6_RAW=$(printf '{}' | (
    unset CONV_LANG
    AGENTS_CONFIG_DIR="$EMPTY_CFG" \
    run_with_timeout 30 node "$SUBAGENT_START" 2>/dev/null
))
T6_RC=$?
if [ "$T6_RC" -ne 0 ]; then
    fail "T6: subagent-start exited non-zero ($T6_RC) with CONV_LANG unset"
else
    T6_CHECK=$(node -e "
try {
  const o = JSON.parse(process.argv[1]);
  const keys = Object.keys(o);
  process.stdout.write(keys.length === 0 ? 'empty' : ('keys:' + keys.join(',')));
} catch (e) { process.stdout.write('parse-error'); }
" "$T6_RAW" 2>/dev/null)
    if [ "$T6_CHECK" = "empty" ]; then
        pass "T6: subagent-start with CONV_LANG unset → output is {}"
    else
        fail "T6: expected empty {}, got: $T6_RAW (check=$T6_CHECK)"
    fi
fi

# ---------------------------------------------------------------------------
# T7 [Integration] CONV_LANG=english → output is {} (english bypass)
# ---------------------------------------------------------------------------
T7_RAW=$(printf '{}' | \
    CONV_LANG="english" \
    AGENTS_CONFIG_DIR="$EMPTY_CFG" \
    run_with_timeout 30 node "$SUBAGENT_START" 2>/dev/null)
T7_RC=$?
if [ "$T7_RC" -ne 0 ]; then
    fail "T7: subagent-start exited non-zero ($T7_RC) with CONV_LANG=english"
else
    T7_CHECK=$(node -e "
try {
  const o = JSON.parse(process.argv[1]);
  const keys = Object.keys(o);
  process.stdout.write(keys.length === 0 ? 'empty' : ('keys:' + keys.join(',')));
} catch (e) { process.stdout.write('parse-error'); }
" "$T7_RAW" 2>/dev/null)
    if [ "$T7_CHECK" = "empty" ]; then
        pass "T7: subagent-start with CONV_LANG=english → output is {}"
    else
        fail "T7: expected empty {} for english bypass, got: $T7_RAW (check=$T7_CHECK)"
    fi
fi

# ---------------------------------------------------------------------------
# T8 [Error] Malformed stdin → exit 0, output parseable as JSON
# ---------------------------------------------------------------------------
T8_RAW=$(printf 'not-json' | \
    CONV_LANG="japanese" \
    AGENTS_CONFIG_DIR="$EMPTY_CFG" \
    run_with_timeout 30 node "$SUBAGENT_START" 2>/dev/null)
T8_RC=$?
if [ "$T8_RC" -ne 0 ]; then
    fail "T8: subagent-start exited non-zero ($T8_RC) on malformed stdin"
else
    T8_CHECK=$(node -e "
try {
  JSON.parse(process.argv[1]);
  process.stdout.write('valid-json');
} catch (e) { process.stdout.write('parse-error'); }
" "$T8_RAW" 2>/dev/null)
    if [ "$T8_CHECK" = "valid-json" ]; then
        pass "T8: subagent-start malformed stdin → exit 0, valid JSON output"
    else
        fail "T8: expected valid JSON output on malformed stdin, got: $T8_RAW (check=$T8_CHECK)"
    fi
fi

# ---------------------------------------------------------------------------
# T9 [Exit code] CONV_LANG=japanese happy path → exit 0
# (Distinct from T5: explicitly observes the exit code in isolation.)
# ---------------------------------------------------------------------------
printf '{}' | \
    CONV_LANG="japanese" \
    AGENTS_CONFIG_DIR="$EMPTY_CFG" \
    run_with_timeout 30 node "$SUBAGENT_START" >/dev/null 2>&1
T9_RC=$?
if [ "$T9_RC" -eq 0 ]; then
    pass "T9: subagent-start CONV_LANG=japanese exit code is 0"
else
    fail "T9: subagent-start CONV_LANG=japanese exit code is $T9_RC (expected 0)"
fi

fi  # end Phase 2a gate
