# unit-helper.sh — T1–T9, T22, T24, T25, T27: Unit tests for hooks/lib/conv-lang.js
# Tests: hooks/lib/conv-lang.js, hooks/lib/lang-config.js
# Tags: lang, conv-lang, injection, TL2
# Sourced after helpers.sh; inherits all variables and functions.
# Which value shapes are accepted or rejected: hooks/lib/lang-config.js LANGUAGE_NAME_RE.

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
    EXPECTED_TC='"Respond to the user in traditional-chinese. This applies to all text you write, including narration between tool calls."'
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

    # T25 [Security] CONV_LANG with DEL char (\x7f) → null (rejected by shape guard)
    # \x7f is NOT in [\x00-\x1f], but #2278's LANGUAGE_NAME_RE/isPlausibleLanguageName
    # shape validation (hooks/lib/lang-config.js) only allows \p{L}/\p{M}/apostrophe/
    # space/hyphen, so DEL (and other non-printable/control-adjacent bytes outside
    # \x00-\x1f) is rejected there rather than passing the earlier \x00-\x1f check.
    OUT=$(CONV_LANG=$'japanese\x7fevil' node -e "
const { getConvLangInjection } = require(process.argv[1]);
const r = getConvLangInjection();
process.stdout.write(JSON.stringify(r === undefined ? null : r));
" "$NODE_LIB_PATH" 2>/dev/null)
    if [ "$OUT" = "null" ]; then
        pass "T25: CONV_LANG with DEL char → null (rejected by LANGUAGE_NAME_RE shape guard)"
    else
        fail "T25: expected null (DEL rejected by shape guard), got $OUT"
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

    # T-A1 [No-op] CONV_LANG=any → null ("any" added to no-op list)
    OUT=$(call_helper set "any")
    if [ "$OUT" = "null" ]; then
        pass "T-A1: CONV_LANG=any → null (no-op)"
    else
        fail "T-A1: expected null for CONV_LANG=any, got $OUT"
    fi

    # T-A2 [No-op] CONV_LANG=ANY (uppercase) → null (case-insensitive via toLowerCase)
    OUT=$(call_helper set "ANY")
    if [ "$OUT" = "null" ]; then
        pass "T-A2: CONV_LANG=ANY (uppercase) → null (case-insensitive no-op)"
    else
        fail "T-A2: expected null for CONV_LANG=ANY (uppercase), got $OUT"
    fi

    # T-A3 [No-op] CONV_LANG=" any " (whitespace-padded) → null (trim then no-op)
    OUT=$(call_helper set " any ")
    if [ "$OUT" = "null" ]; then
        pass "T-A3: CONV_LANG=' any ' (padded) → null (trim → no-op)"
    else
        fail "T-A3: expected null for padded 'any', got $OUT"
    fi

    # T-A4 [Regression] CONV_LANG=japanese → injection string (still works after adding "any")
    OUT=$(call_helper set "japanese")
    if [ "$OUT" = "\"$EXPECTED_JA\"" ]; then
        pass "T-A4: CONV_LANG=japanese → injection still works (regression)"
    else
        fail "T-A4: regression — expected \"$EXPECTED_JA\", got $OUT"
    fi

    # T-A5 [Regression] CONV_LANG=english → null (existing no-op preserved)
    OUT=$(call_helper set "english")
    if [ "$OUT" = "null" ]; then
        pass "T-A5: CONV_LANG=english → null (existing no-op preserved)"
    else
        fail "T-A5: regression — expected null for CONV_LANG=english, got $OUT"
    fi

    # T-U1 [Regression] native-script CONV_LANG stays injectable: the #2278 shape
    # guard is Unicode-aware, so a language named in its own script must not be
    # rejected alongside the injection-shaped values the guard exists to block.
    OUT=$(call_helper set "日本語")
    if [ "$OUT" != "null" ] && [ "${OUT#*日本語}" != "$OUT" ]; then
        pass "T-U1: CONV_LANG=日本語 (native script) → injected verbatim (shape guard is Unicode-aware)"
    else
        fail "T-U1: expected an injection naming 日本語, got $OUT"
    fi
fi
