# unit-helper.sh — T1–T9, T22, T24, T25, T27: Unit tests for hooks/lib/conv-lang.js
# Sourced after helpers.sh; inherits all variables and functions.
#
# Intentionally N/A (not tested):
# - Non-ASCII CONV_LANG values (e.g. "日本語"): pass-through is correct;
#   the guard is ASCII-control-only by design. .env is operator-controlled.
# - Extremely long CONV_LANG: no length cap exists; verbatim pass-through
#   is the intended behavior. No truncation threshold to test against.

# ===========================================================================
# Unit tests for hooks/lib/conv-lang.js (T1–T9)
# ===========================================================================
if [ ! -f "$CONV_LANG_LIB" ]; then
    skip "T1-T9: $CONV_LANG_LIB does not exist yet (pre-implementation)"
else
    # T1 [Normal] CONV_LANG=japanese → injection string
    OUT=$(call_helper set "japanese")
    if [ "$OUT" = "\"$EXPECTED_JA\"" ]; then
        pass "T1: CONV_LANG=japanese → \"$EXPECTED_JA\""
    else
        fail "T1: expected \"$EXPECTED_JA\", got $OUT"
    fi

    # T2 [Normal] CONV_LANG unset → null
    OUT=$(call_helper unset)
    if [ "$OUT" = "null" ]; then
        pass "T2: CONV_LANG unset → null"
    else
        fail "T2: expected null, got $OUT"
    fi

    # T3 [Normal] CONV_LANG=english → null (noop)
    OUT=$(call_helper set "english")
    if [ "$OUT" = "null" ]; then
        pass "T3: CONV_LANG=english → null"
    else
        fail "T3: expected null, got $OUT"
    fi

    # T4 [Edge] CONV_LANG=ENGLISH (uppercase) → null (case-insensitive)
    OUT=$(call_helper set "ENGLISH")
    if [ "$OUT" = "null" ]; then
        pass "T4: CONV_LANG=ENGLISH (uppercase) → null"
    else
        fail "T4: expected null, got $OUT"
    fi

    # T5 [Edge] CONV_LANG="  japanese  " (padded) → injected (trimmed)
    OUT=$(call_helper set "  japanese  ")
    if [ "$OUT" = "\"$EXPECTED_JA\"" ]; then
        pass "T5: CONV_LANG padded → trimmed injection"
    else
        fail "T5: expected \"$EXPECTED_JA\", got $OUT"
    fi

    # T6 [Edge] CONV_LANG="" (empty) → null
    OUT=$(call_helper set "")
    if [ "$OUT" = "null" ]; then
        pass "T6: CONV_LANG empty → null"
    else
        fail "T6: expected null, got $OUT"
    fi

    # T7 [Edge] CONV_LANG=" " (whitespace only) → null
    OUT=$(call_helper set "   ")
    if [ "$OUT" = "null" ]; then
        pass "T7: CONV_LANG whitespace-only → null"
    else
        fail "T7: expected null, got $OUT"
    fi

    # T8 [Edge] CONV_LANG=traditional-chinese → injected as-is
    OUT=$(call_helper set "traditional-chinese")
    EXPECTED_TC='"Respond to the user in traditional-chinese."'
    if [ "$OUT" = "$EXPECTED_TC" ]; then
        pass "T8: CONV_LANG=traditional-chinese → multi-word injection"
    else
        fail "T8: expected $EXPECTED_TC, got $OUT"
    fi

    # T9 [Security] CONV_LANG with control char \x01 → null (injection guard)
    OUT=$(CONV_LANG=$'japanese\x01evil' node -e "
const { getConvLangInjection } = require(process.argv[1]);
const r = getConvLangInjection();
process.stdout.write(JSON.stringify(r === undefined ? null : r));
" "$NODE_LIB_PATH" 2>/dev/null)
    if [ "$OUT" = "null" ]; then
        pass "T9: CONV_LANG with control char → null (guard)"
    else
        fail "T9: expected null, got $OUT"
    fi

    # T27 [Edge] CONV_LANG=JAPANESE (uppercase non-english) → lowercased injection
    OUT=$(call_helper set "JAPANESE")
    if [ "$OUT" = "\"$EXPECTED_JA\"" ]; then
        pass "T27: CONV_LANG=JAPANESE (uppercase) → lowercased injection \"$EXPECTED_JA\""
    else
        fail "T27: expected \"$EXPECTED_JA\", got $OUT"
    fi

    # T24 [Edge] CONV_LANG="  english  " (padded) → null (case-insensitive noop)
    OUT=$(call_helper set "  english  ")
    if [ "$OUT" = "null" ]; then
        pass "T24: CONV_LANG padded english → null"
    else
        fail "T24: expected null, got $OUT"
    fi

    # T25 [Security] CONV_LANG with DEL char (\x7f) → injected as-is
    # \x7f is NOT in [\x00-\x1f]; the guard is intentionally conservative.
    # This documents the known behavior: DEL passes through. Acceptable because
    # the value goes to LLM text (no shell eval) and .env is operator-controlled.
    OUT=$(CONV_LANG=$'japanese\x7fevil' node -e "
const { getConvLangInjection } = require(process.argv[1]);
const r = getConvLangInjection();
process.stdout.write(JSON.stringify(r === undefined ? null : r));
" "$NODE_LIB_PATH" 2>/dev/null)
    if [ "$OUT" != "null" ]; then
        pass "T25: CONV_LANG with DEL char passes through (guard covers \\x00-\\x1f only)"
    else
        fail "T25: DEL char unexpectedly returned null — guard scope may have changed"
    fi

    # T22 [Security] CONV_LANG with newline (\x0a) → null (prompt-split guard)
    # \n is in \x00-\x1f; a newline in additionalContext could split the injection
    # into separate semantic lines, enabling prompt injection.
    OUT=$(CONV_LANG=$'japanese\nevil' node -e "
const { getConvLangInjection } = require(process.argv[1]);
const r = getConvLangInjection();
process.stdout.write(JSON.stringify(r === undefined ? null : r));
" "$NODE_LIB_PATH" 2>/dev/null)
    if [ "$OUT" = "null" ]; then
        pass "T22: CONV_LANG with newline → null (prompt-split guard)"
    else
        fail "T22: expected null, got $OUT"
    fi
fi
