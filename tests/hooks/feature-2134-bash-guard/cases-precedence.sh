# tests/feature-2134-bash-guard/cases-precedence.sh
# Tests: hooks/bash-guard/judge.js, hooks/bash-guard/detect.js, hooks/bash-guard/allow.js
# Tags: hook, bash-guard, precedence, verdict-order, fail-open, scope:issue-specific, pwsh-not-required, TL2
# Q1: the 4-value verdict order deny > notify > allow > passThrough. Sourced AFTER cases-interlock.sh.

# WHY PIN THE ORDER (#2264). allow skips the permission prompt, so any path that lets allow win
# over a deny, or lets a fail-open land on allow, turns a presentation guard into a bypass. Each
# row combines two verdict sources in one command and names which one must win. The pre-verdict
# gates (interlock, parse failure) outrank all four and resolve to passThrough, never allow.

q1_precedence_rows() {
    local name cmd sid want got
    while IFS='~' read -r name cmd sid want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        sid="${sid//[[:space:]]/}"
        want="${want//[[:space:]]/}"
        cmd="$(mkcmd "$cmd")"
        [ "$sid" = "-" ] && sid=""
        [ "$sid" = "ARMED" ] && sid="$BG_SID_ARMED"
        ROWS=$((ROWS + 1))

        got="$(verdict_code_of "$cmd" "$sid")"
        assert_eq "Q1/$name: verdict|code" "$want" "$got"
    done <<'TABLE'
# --- deny beats notify ---
deny-over-l2      ~ echo "<<WORKFLOW_MARK_STEP_x>>" && ls                           ~ -     ~ deny|BG-CHAIN-AND
deny-over-l3      ~ "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --list | cat        ~ -     ~ deny|BG-PIPE
# --- deny beats allow: a self-script plus one forbidden literal is a deny, not an allow ---
deny-over-allow-a ~ node "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --list && ls   ~ -     ~ deny|BG-CHAIN-AND
deny-over-allow-r ~ node "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --list > o.txt ~ -     ~ deny|BG-REDIRECT-OUT
# --- notify beats allow: the exec-position self-script is notified, never allowed ---
notify-over-allow ~ "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --list              ~ -     ~ notify|BG-NOTIFY-SCRIPT-NO-INTERPRETER
# --- allow beats passThrough ---
allow-over-pass   ~ node "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --list         ~ -     ~ allow|BG-ALLOW-SELF-SCRIPT
# --- pre-verdict gates: never allow ---
interlock-quiet   ~ node "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --list         ~ ARMED ~ passThrough|BG-INTERLOCK-QUIET
parse-fail-open   ~ node "$AGENTS_CONFIG_DIR/bin/workflow/next-step" "unterminated  ~ -     ~ passThrough|BG-PARSE-FAILURE
TABLE
}

case_begin "verdict-precedence" "hooks/bash-guard/judge.js"
q1_precedence_rows
case_end

# notify-over-allow is the only reachable notify/allow overlap: matchSelfScript needs cmd0 to be
# bash/node while L3 needs a path-shaped cmd0, so the same segment cannot satisfy both unless the
# interpreter itself were an allow-list entry. The row pins that the exec form is not allowed.
