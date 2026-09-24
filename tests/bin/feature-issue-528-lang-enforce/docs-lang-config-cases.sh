#!/bin/bash
# tests/feature-issue-528-lang-enforce/docs-lang-config-cases.sh
# Tests: hooks/lib/lang-config.js
# Tags: worktree, docs, lang-config, scope:issue-specific
# Sourced by ../feature-issue-528-lang-enforce.sh — helpers come from there.

# ============================================================================
# Group 1' — lang-config.js loadDocsLangConfig() .env-only loader (post-#619)
# ============================================================================
# Replaces the old fenced-block parser tests. After #619, loadDocsLangConfig()
# is zero-arg and reads ONLY from $AGENTS_CONFIG_DIR/.env via loadDefaultEnv().

echo "=== Group 1': lang-config.js loadDocsLangConfig() .env-only ==="

if [ "$(src_present "$CONFIG_LIB")" != "ok" ]; then
    echo "SKIP G1': hooks/lib/lang-config.js not yet implemented (RED phase)"
else
    # T_new_1: both DOCS_LANG_ keys in .env → loaded correctly
    _tnew1_env=$'DOCS_LANG_PUBLIC=english\nDOCS_LANG_PRIVATE=english\n'
    _tnew1_json="$(load_config_json_env "$_tnew1_env")"
    if echo "$_tnew1_json" | grep -q '"public":"english"' && \
       echo "$_tnew1_json" | grep -q '"private":"english"'; then
        pass "T_new_1: both DOCS_LANG_ keys in .env → loaded correctly"
    else
        fail "T_new_1: expected both keys from .env, got: $_tnew1_json"
    fi

    # T_new_2: partial .env (only DOCS_LANG_PUBLIC set) → the other defaults to 'any'
    _tnew2_env=$'DOCS_LANG_PUBLIC=english\n'
    _tnew2_json="$(load_config_json_env "$_tnew2_env")"
    if echo "$_tnew2_json" | grep -q '"public":"english"' && \
       echo "$_tnew2_json" | grep -q '"private":"any"'; then
        pass "T_new_2: partial .env → set key honored, the other defaults to 'any'"
    else
        fail "T_new_2: expected partial load with defaults, got: $_tnew2_json"
    fi

    # T_new_3: missing .env → all 'any' (fail-open)
    _tnew3_json="$(load_config_json_env "" "no_env")"
    if echo "$_tnew3_json" | grep -q '"public":"any"' && \
       echo "$_tnew3_json" | grep -q '"private":"any"'; then
        pass "T_new_3: missing .env → all 'any' (fail-open)"
    else
        fail "T_new_3: expected all 'any' for missing .env, got: $_tnew3_json"
    fi

    # T_new_4: .env with empty value → treated as empty/default ('any')
    _tnew4_env=$'DOCS_LANG_PUBLIC=\n'
    _tnew4_json="$(load_config_json_env "$_tnew4_env")"
    if echo "$_tnew4_json" | grep -q '"public":"any"'; then
        pass "T_new_4: empty value in .env → default ('any')"
    else
        fail "T_new_4: expected 'any' for empty value, got: $_tnew4_json"
    fi

    # ---- legacy-key warning (the 4 retired DOCS_LANG_HISTORY_*/CHANGELOG_* keys) ----

    # T_new_5: a legacy key in .env is ignored for VALUE purposes and warned about.
    # Both halves matter: adopting the value silently would be the regression, and
    # dropping it silently would leave a stale .env invisible.
    _tnew5_env=$'DOCS_LANG_HISTORY_PUBLIC=english\n'
    _tnew5_json="$(load_config_json_env "$_tnew5_env")"
    _tnew5_err="$(load_config_stderr_env "$_tnew5_env")"
    if echo "$_tnew5_json" | grep -q '"public":"any"' && \
       echo "$_tnew5_json" | grep -q '"private":"any"'; then
        pass "T_new_5: legacy DOCS_LANG_HISTORY_PUBLIC value is NOT adopted (config stays 'any')"
    else
        fail "T_new_5: legacy value leaked into config, got: $_tnew5_json"
    fi
    if echo "$_tnew5_err" | grep -q 'DOCS_LANG_HISTORY_PUBLIC'; then
        pass "T_new_5: stderr warning names the legacy key"
    else
        fail "T_new_5: expected a stderr warning naming DOCS_LANG_HISTORY_PUBLIC, got: $_tnew5_err"
    fi

    # T_new_6: two loads in ONE process → exactly one warning (module-scope dedup).
    # Cross-process dedup is deliberately NOT asserted: the warning is meant to
    # reappear on every new hook run until .env is migrated.
    _tnew6_err="$(load_config_stderr_env $'DOCS_LANG_HISTORY_PUBLIC=english\n' 2)"
    _tnew6_hits="$(printf '%s\n' "$_tnew6_err" | grep -c 'DOCS_LANG_HISTORY_PUBLIC')"
    if [ "$_tnew6_hits" = "1" ]; then
        pass "T_new_6: two loads in one process → warning emitted exactly once"
    else
        fail "T_new_6: expected exactly 1 warning line, got $_tnew6_hits: $_tnew6_err"
    fi

    # T_new_7: negative control — a .env with only new keys warns about nothing.
    _tnew7_err="$(load_config_stderr_env $'DOCS_LANG_PUBLIC=english\nDOCS_LANG_PRIVATE=any\n')"
    if [ -z "$_tnew7_err" ]; then
        pass "T_new_7: no legacy key in .env → stderr empty"
    else
        fail "T_new_7: expected empty stderr, got: $_tnew7_err"
    fi

    # T_new_8: both new keys with different values → both carried through verbatim.
    _tnew8_json="$(load_config_json_env $'DOCS_LANG_PUBLIC=english\nDOCS_LANG_PRIVATE=any\n')"
    if echo "$_tnew8_json" | grep -q '"public":"english"' && \
       echo "$_tnew8_json" | grep -q '"private":"any"'; then
        pass "T_new_8: DOCS_LANG_PUBLIC=english + DOCS_LANG_PRIVATE=any → {public:english, private:any}"
    else
        fail "T_new_8: expected {public:english, private:any}, got: $_tnew8_json"
    fi

    # T_new_9 (regression guard): detection source must be the .env FILE, not
    # process.env. Here .env is already migrated but the shell still exports a
    # legacy key — a process.env-based implementation warns and this fails.
    _tnew9_env=$'DOCS_LANG_PUBLIC=english\nDOCS_LANG_PRIVATE=any\n'
    _tnew9_err="$(load_config_stderr_env "$_tnew9_env" 1 DOCS_LANG_HISTORY_PUBLIC=english)"
    _tnew9_json="$(load_config_json_ext "$_tnew9_env" DOCS_LANG_HISTORY_PUBLIC=english)"
    if [ -z "$_tnew9_err" ]; then
        pass "T_new_9: legacy key exported in the SHELL (clean .env) → no warning"
    else
        fail "T_new_9: warning fired on a shell-only legacy key — detection reads process.env, not .env: $_tnew9_err"
    fi
    if echo "$_tnew9_json" | grep -q '"public":"english"' && \
       echo "$_tnew9_json" | grep -q '"private":"any"'; then
        pass "T_new_9: config still comes from the .env file, not the shell legacy key"
    else
        fail "T_new_9: expected the .env-derived config, got: $_tnew9_json"
    fi

    # T_new_5b: the same contract as T_new_5, for EVERY member of LEGACY_KEYS.
    # T_new_5 covers only DOCS_LANG_HISTORY_PUBLIC, so a LEGACY_KEYS list that
    # dropped or misspelled one of the other three would still read as green
    # (CPR-ORTH: one member tested, the class assumed).
    _t5b_report=""
    for _t5b_key in DOCS_LANG_HISTORY_PUBLIC DOCS_LANG_HISTORY_PRIVATE \
                    DOCS_LANG_CHANGELOG_PUBLIC DOCS_LANG_CHANGELOG_PRIVATE; do
        _t5b_env="$_t5b_key=english"$'\n'
        _t5b_json="$(load_config_json_env "$_t5b_env")"
        _t5b_err="$(load_config_stderr_env "$_t5b_env")"
        _t5b_adopted=no
        echo "$_t5b_json" | grep -q '"public":"any"' || _t5b_adopted=yes
        echo "$_t5b_json" | grep -q '"private":"any"' || _t5b_adopted=yes
        _t5b_warned=no
        echo "$_t5b_err" | grep -q "$_t5b_key" && _t5b_warned=yes
        _t5b_report+="$_t5b_key adopted=$_t5b_adopted warned=$_t5b_warned"$'\n'
    done
    _t5b_expected="DOCS_LANG_HISTORY_PUBLIC adopted=no warned=yes
DOCS_LANG_HISTORY_PRIVATE adopted=no warned=yes
DOCS_LANG_CHANGELOG_PUBLIC adopted=no warned=yes
DOCS_LANG_CHANGELOG_PRIVATE adopted=no warned=yes
"
    if [ "$_t5b_report" = "$_t5b_expected" ]; then
        pass "T_new_5b: all 4 legacy keys — value never adopted, each named in the warning"
    else
        fail "T_new_5b: legacy-key table mismatch. expected:
$_t5b_expected
got:
$_t5b_report"
    fi

    # T_new_5c: several legacy keys at once. The warning is ONE line listing every
    # key present, so a per-key early return would leave the later ones invisible.
    _t5c_env=$'DOCS_LANG_HISTORY_PRIVATE=japanese\nDOCS_LANG_CHANGELOG_PUBLIC=english\n'
    _t5c_err="$(load_config_stderr_env "$_t5c_env")"
    _t5c_json="$(load_config_json_env "$_t5c_env")"
    _t5c_lines="$(printf '%s\n' "$_t5c_err" | grep -c 'lang-config: ignoring legacy key')"
    if [ "$_t5c_lines" = "1" ] && \
       echo "$_t5c_err" | grep -q 'DOCS_LANG_HISTORY_PRIVATE' && \
       echo "$_t5c_err" | grep -q 'DOCS_LANG_CHANGELOG_PUBLIC'; then
        pass "T_new_5c: two legacy keys → a single warning line naming both"
    else
        fail "T_new_5c: expected one warning line naming both keys, got ($_t5c_lines lines): $_t5c_err"
    fi
    if echo "$_t5c_json" | grep -q '"public":"any"' && \
       echo "$_t5c_json" | grep -q '"private":"any"'; then
        pass "T_new_5c: neither legacy value reaches the config"
    else
        fail "T_new_5c: a legacy value leaked into the config, got: $_t5c_json"
    fi

    # T_new_10: an empty legacy value is "not set" (load-env.js convention) → no warning.
    _tnew10_err="$(load_config_stderr_env $'DOCS_LANG_CHANGELOG_PRIVATE=\n')"
    if [ -z "$_tnew10_err" ]; then
        pass "T_new_10: empty legacy value counts as unset → no warning"
    else
        fail "T_new_10: expected no warning for an empty legacy value, got: $_tnew10_err"
    fi
fi
