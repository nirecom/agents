# Part of tests/feature-review-code-codex/path-priority.sh (sourced, not standalone).
# Tests: bin/review-code-codex, bin/get-config-var, hooks/lib/load-env.js, .env.example
# Tags: codex, review, config, env, threshold, precedence, edge-cases, scope:issue-specific, pwsh-not-required, TL2
# G: a configurable cap only helps if it actually takes effect. G1 sets the cap ONLY in a real .env (never the process env) so the row fails if the get-config-var lookup breaks; G2 pins process-env-over-.env precedence; G3 pins the unset default; G4/G5 pin the default's boundaries. G6 sweeps hand-typed input (empty, padded, decimal, signed, overflow) — none may produce an arithmetic error or an empty review.
# TL3 gap: real ~/.claude .env precedence is untested (fixture .env only), and node's absence (get-config-var shells out to it) takes an unexercised path. Mitigation: WORKFLOW_USER_VERIFIED preflight, category merge-base-suspect.

G_MID="$(pp_new_repo pp-g-mid)"
pp_gen "$G_MID/mid.txt" 200 "pp-g-mid-marker"
git -C "$G_MID" add mid.txt
git -C "$G_MID" commit -q -m "200-line file"

G_BIG="$(pp_new_repo pp-g-big)"
pp_gen "$G_BIG/big.txt" 6000 "pp-g-big-marker"
git -C "$G_BIG" add big.txt
git -C "$G_BIG" commit -q -m "6000-line file"

G_CFG="$TMPDIR_BASE/pp-g-cfg"

# ---------------------------------------------------------------------------
# G1 — the .env branch, exercised with the process environment deliberately empty of the key.
# ---------------------------------------------------------------------------
pp_make_cfg_dir "$G_CFG" "CODEX_REVIEW_MAX_DIFF_LINES=50" >/dev/null
PP_ENV=(AGENTS_CONFIG_DIR="$G_CFG")
PP_OUT="$(pp_run "$G_MID" --base main --no-log)"
if printf '%s\n' "$PP_OUT" | grep -E "^## Codex Review Scope: TRUNCATED" | grep -q "50"; then
    pass "G1: a cap of 50 set only in a real .env is read through get-config-var and applied"
else
    fail "G1: the .env-only cap of 50 never took effect — the config lookup is not wired. Output: $PP_OUT"
fi
g_n="$(pp_diff_body_lines "$PP_CAPTURE")"
if [ "${g_n:-0}" -gt 0 ] && [ "$g_n" -le 50 ]; then
    pass "G1-budget: and $g_n lines were actually sent under it"
else
    fail "G1-budget: the .env cap of 50 let $g_n lines of diff body through"
fi

# ---------------------------------------------------------------------------
# G2 — precedence. A caller who exports the variable for one run must not be overruled by the
#      file, or the per-run override is unusable.
# ---------------------------------------------------------------------------
PP_ENV=(AGENTS_CONFIG_DIR="$G_CFG" CODEX_REVIEW_MAX_DIFF_LINES=6000)
PP_OUT="$(pp_run "$G_MID" --base main --no-log)"
if pp_has "$PP_OUT" "^## Codex Review Scope: TRUNCATED"; then
    fail "G2: the .env value of 50 overruled the process environment's 6000 and truncated a 200-line diff. Output: $PP_OUT"
elif pp_has "$PP_OUT" "^## Codex Review: PERFORMED"; then
    pass "G2: the process environment wins over .env — 6000 beats the file's 50 and nothing is truncated"
else
    fail "G2: the precedence run produced no verdict. Output: $PP_OUT"
fi

# ---------------------------------------------------------------------------
# G3 — nothing set anywhere. The default has to be a real default, not an accident of the
#      ambient environment the suite happens to run in.
# ---------------------------------------------------------------------------
pp_make_cfg_dir "$G_CFG" >/dev/null
PP_ENV=(AGENTS_CONFIG_DIR="$G_CFG")
PP_OUT="$(pp_run "$G_MID" --base main --no-log)"
if pp_has "$PP_OUT" "^## Codex Review Scope: TRUNCATED"; then
    fail "G3: a 200-line diff was truncated with no cap configured anywhere. Output: $PP_OUT"
else
    pass "G3: with the key absent from both .env and the environment, a 200-line diff passes whole"
fi
PP_OUT="$(pp_run "$G_BIG" --base main --no-log)"
if printf '%s\n' "$PP_OUT" | grep -E "^## Codex Review Scope: TRUNCATED" | grep -q "5000"; then
    pass "G3-default: and a 6000-line diff is truncated at the built-in default of 5000"
else
    fail "G3-default: the unset default did not resolve to 5000. Output: $PP_OUT"
fi

# ---------------------------------------------------------------------------
# G4 — a cap ABOVE the old hardcoded 5000. This is the whole point of making it configurable:
#      a repo that wants its 6000-line diff reviewed whole must be able to ask for that. A
#      residual `head -n 5000` anywhere in the path fails here and nowhere else.
# ---------------------------------------------------------------------------
PP_ENV=(AGENTS_CONFIG_DIR="$G_CFG" CODEX_REVIEW_MAX_DIFF_LINES=8000)
PP_OUT="$(pp_run "$G_BIG" --base main --no-log)"
if pp_has "$PP_OUT" "^## Codex Review Scope: TRUNCATED"; then
    fail "G4: a 6000-line diff was still truncated under a cap of 8000 — 5000 is still hardcoded somewhere. Output: $PP_OUT"
else
    pass "G4: raising the cap to 8000 lets a 6000-line diff be reviewed whole"
fi
g_n="$(pp_diff_body_lines "$PP_CAPTURE")"
if [ "${g_n:-0}" -gt 5000 ]; then
    pass "G4-budget: and $g_n lines really were sent — past the old 5000 ceiling"
else
    fail "G4-budget: only $g_n lines reached the model under a cap of 8000"
fi

# ---------------------------------------------------------------------------
# G5 — malformed values fall back to the default, and the fallback is EXACTLY 5000. Measured
#      on a 6000-line fixture, because on anything smaller "fell back to 5000" and "fell back
#      to no limit at all" look identical.
# ---------------------------------------------------------------------------
for g_bad in abc "5000; rm -rf /" "0" "-1"; do
    PP_ENV=(AGENTS_CONFIG_DIR="$G_CFG" CODEX_REVIEW_MAX_DIFF_LINES="$g_bad")
    PP_OUT="$(pp_run "$G_BIG" --base main --no-log)"
    g_n="$(pp_diff_body_lines "$PP_CAPTURE")"
    if ! printf '%s\n' "$PP_OUT" | grep -E "^## Codex Review Scope: TRUNCATED" | grep -q "5000"; then
        fail "G5[$g_bad]: a malformed cap did not fall back to a reported 5000. Output: $PP_OUT"
    elif [ "${g_n:-0}" -gt 0 ] && [ "$g_n" -le 5000 ]; then
        pass "G5[$g_bad]: a malformed cap falls back to exactly 5000, and $g_n lines were sent under it"
    else
        fail "G5[$g_bad]: the fallback reported 5000 but sent $g_n lines of diff body"
    fi
done

# G6 — every hand-typeable value must resolve deterministically to a usable cap or the
# default: no arithmetic error, no crash, no empty review. C4 (#1976 gap): run against G_BIG
# (6000 lines), not 200, so "accepted as huge" (untruncated) and "fell back to 5000"
# (TRUNCATED) are distinguishable; use pp_exec (not pp_run) so stderr is captured, not discarded.
G_LONG="$(awk 'BEGIN { s = "9"; for (i = 0; i < 999; i++) s = s "9"; print s }')"
for g_edge in "" "   " "12.5" "+50" "1e4" "0x1F" "9223372036854775807" "99999999999999999999" "$G_LONG"; do
    PP_ENV=(AGENTS_CONFIG_DIR="$G_CFG" CODEX_REVIEW_MAX_DIFF_LINES="$g_edge")
    pp_exec "$G_BIG" --base main --no-log
    PP_ENV=()
    g_n="$(pp_diff_body_lines "$PP_CAPTURE")"
    g_label="${g_edge:-<empty>}"
    if [ ${#g_label} -gt 24 ]; then g_label="<${#g_edge}-digit number>"; fi
    if pp_has "$PP_ERR_TEXT" "arithmetic\|integer expression\|value too great"; then
        fail "G6[$g_label]: a shell arithmetic error surfaced on stderr: $PP_ERR_TEXT"
    elif ! pp_has "$PP_OUT_TEXT" "^## Codex Review: PERFORMED"; then
        fail "G6[$g_label]: the run produced no PERFORMED verdict — a config value broke the review. stdout: $PP_OUT_TEXT stderr: $PP_ERR_TEXT"
    elif [ "${g_n:-0}" -eq 0 ]; then
        fail "G6[$g_label]: the review completed with an empty diff body"
    elif pp_has "$PP_OUT_TEXT" "^## Codex Review Scope: TRUNCATED"; then
        if printf '%s\n' "$PP_OUT_TEXT" | grep -E "^## Codex Review Scope: TRUNCATED" | grep -q "5000"; then
            pass "G6[$g_label]: the value falls back to the reported 5000 default, truncating the 6000-line fixture"
        else
            fail "G6[$g_label]: the diff was truncated but not at the reported 5000 default. Output: $PP_OUT_TEXT"
        fi
    elif [ "$g_n" -eq 6000 ]; then
        pass "G6[$g_label]: the value is accepted as a literal cap large enough to send the whole 6000-line fixture untruncated"
    else
        fail "G6[$g_label]: untruncated, but only $g_n of 6000 lines were sent — neither the default nor a working large cap. Output: $PP_OUT_TEXT"
    fi
done
PP_ENV=()

# G8 (C3, #1976 gap) — malformed values read from a REAL .env, not just PP_ENV (G5/G6 only
# prove shell-export parsing). Written into a real .env with the key absent from the process
# env (G1 arrangement), so only the .env-reading branch can pass. Measured on G_BIG for the
# same reason as G5: on a smaller fixture "fell back to 5000" and "no limit" look identical.
G8_CANARY="$TMPDIR_BASE/pp-g8-canary-marker"
rm -f "$G8_CANARY"
for g8_bad in "0" "-1" "99999999999999999999" "5000; rm -rf /" '$(whoami)' "0; touch $G8_CANARY" "abc"; do
    pp_make_cfg_dir "$G_CFG" "CODEX_REVIEW_MAX_DIFF_LINES=$g8_bad" >/dev/null
    PP_ENV=(AGENTS_CONFIG_DIR="$G_CFG")
    pp_exec "$G_BIG" --base main --no-log
    PP_ENV=()
    g8_label="$g8_bad"
    if [ ${#g8_label} -gt 24 ]; then g8_label="<${#g8_bad}-char value>"; fi

    if [ -f "$G8_CANARY" ]; then
        fail "G8[.env=$g8_label]: a malformed .env value executed a command — the canary marker file was created"
        rm -f "$G8_CANARY"
    else
        pass "G8[.env=$g8_label]: no command executed from the malformed .env value"
    fi

    if [ -n "$PP_ERR_TEXT" ]; then
        fail "G8[.env=$g8_label]: stderr is not clean: $PP_ERR_TEXT"
    else
        pass "G8[.env=$g8_label]: stderr is clean — no crash or error spew from the malformed .env value"
    fi

    if ! printf '%s\n' "$PP_OUT_TEXT" | grep -E "^## Codex Review Scope: TRUNCATED" | grep -q "5000"; then
        fail "G8[.env=$g8_label]: a malformed value read from a real .env did not fall back to a reported cap of 5000. Output: $PP_OUT_TEXT"
    else
        g8_n="$(pp_diff_body_lines "$PP_CAPTURE")"
        if [ "${g8_n:-0}" -gt 0 ] && [ "$g8_n" -le 5000 ]; then
            pass "G8[.env=$g8_label]: falls back to exactly 5000 when read from a real .env file, and $g8_n lines were sent, non-empty and capped"
        else
            fail "G8[.env=$g8_label]: the fallback reported 5000 but sent $g8_n lines of diff body. Output: $PP_OUT_TEXT"
        fi
    fi
done
PP_ENV=()

# ---------------------------------------------------------------------------
# G7 — the setting has to be discoverable, and discoverable means a canonical `KEY=` entry
#      with real documentation next to it, not just the substring appearing somewhere (an
#      unrelated comment, or a malformed example would satisfy a bare `grep -q`). MERGE_BASE_
#      MAX_DIFF_LINES already sets the convention this file follows: a `KEY=` assignment line,
#      preceded by a comment block that states the built-in default and the value's format.
# ---------------------------------------------------------------------------
if [ ! -f "$AGENTS_ROOT/.env.example" ]; then
    fail "G7: .env.example is missing, so the new setting cannot be documented where users look"
elif ! grep -qE "^CODEX_REVIEW_MAX_DIFF_LINES=" "$AGENTS_ROOT/.env.example"; then
    fail "G7: .env.example has no canonical 'CODEX_REVIEW_MAX_DIFF_LINES=' entry — a bare mention elsewhere (comment, unrelated text) does not make the setting discoverable. Matches the convention MERGE_BASE_MAX_DIFF_LINES already sets in this file."
else
    g7_context="$(grep -B5 -E "^CODEX_REVIEW_MAX_DIFF_LINES=" "$AGENTS_ROOT/.env.example")"
    if ! printf '%s' "$g7_context" | grep -q "5000"; then
        fail "G7-default: the CODEX_REVIEW_MAX_DIFF_LINES entry's documentation never states the built-in default of 5000. Context: $g7_context"
    elif ! printf '%s' "$g7_context" | grep -qiE "format|integer"; then
        fail "G7-format: the CODEX_REVIEW_MAX_DIFF_LINES entry never documents the value's format. Context: $g7_context"
    else
        pass "G7: .env.example carries a canonical CODEX_REVIEW_MAX_DIFF_LINES= entry documenting both the 5000 default and the value's format"
    fi
fi
