# Tests: hooks/enforce-worktree.js
# Tags: TL2, worktree, enforce, hook, env, scope:common
# Sourced by tests/main-enforce-worktree-guard.sh
# Origin: tests/fix-enforce-worktree-hooks-bypass.sh (all cases).
# Cases: U1-U39 (unit, hasGitHooksBypass) and I1-I13 (hook + linked worktree).
# Illegitimate bypass attempts only; sanctioned routes live in sanctioned-bypass.sh
# at opposite polarity, so a regression in one cannot mask the other. Every form
# that disables hooks must be caught and blocked even from a linked worktree.

# Returns "bypass", "clean", or "UNDEFINED" if the export is missing.
# The guard path travels as an argument, never spliced into the program text.
hb_bypass_check() {
    run_with_timeout 30 node -e "
      const m = require(process.argv[1]);
      const fn = m.hasGitHooksBypass;
      if (typeof fn !== 'function') { console.log('UNDEFINED'); process.exit(0); }
      console.log(fn(process.argv[2]) ? 'bypass' : 'clean');
    " -- "$GUARD_JS" "$1" 2>/dev/null
}

hb_expect_bypass() {
    local label="$1" cmd="$2"
    local r; r="$(hb_bypass_check "$cmd")"
    if [ "$r" = "bypass" ]; then pass "$label"
    else fail "$label (expected bypass, got $r)"
    fi
}

hb_expect_clean() {
    local label="$1" cmd="$2"
    local r; r="$(hb_bypass_check "$cmd")"
    if [ "$r" = "clean" ]; then pass "$label"
    else fail "$label (expected clean, got $r)"
    fi
}

hb_expect_block() {
    local label="$1" cmd="$2" cwd="$3"
    local out; out="$(run_bash_guard "$cmd" "$cwd")"
    if guard_decision "$out"; then fail "$label (expected block, got allow: $out)"
    else pass "$label"
    fi
}

hb_expect_allow() {
    local label="$1" cmd="$2" cwd="$3"
    local out; out="$(run_bash_guard "$cmd" "$cwd")"
    if guard_decision "$out"; then pass "$label"
    else fail "$label (expected allow, got block: $out)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Section U: Unit tests (hasGitHooksBypass) ==="

# Should return bypass
hb_expect_bypass "U1: -c core.hooksPath=/dev/null commit" \
    'git -c core.hooksPath=/dev/null commit -m "msg"'
hb_expect_bypass "U2: -c core.hooksPath= commit (empty value)" \
    'git -c core.hooksPath= commit -m "msg"'
hb_expect_bypass "U3: -c core.hooksPath=/tmp/empty commit" \
    'git -c core.hooksPath=/tmp/empty commit'
hb_expect_bypass "U4: git -C /repo -c core.hooksPath=/dev/null commit" \
    'git -C /repo -c core.hooksPath=/dev/null commit'
hb_expect_bypass "U5: -c \"core.hooksPath=/dev/null\" commit" \
    'git -c "core.hooksPath=/dev/null" commit'
hb_expect_bypass "U6: -c '\''core.hooksPath=/dev/null'\'' commit" \
    "git -c 'core.hooksPath=/dev/null' commit"
hb_expect_bypass "U7: case-insensitive CORE.HOOKSPATH" \
    'git -c CORE.HOOKSPATH=/dev/null commit'
hb_expect_bypass "U8: -c core.hooksPath=/dev/null push" \
    'git -c core.hooksPath=/dev/null push'
hb_expect_bypass "U9: --config-env=core.hooksPath=ENV_VAR" \
    'git --config-env=core.hooksPath=ENV_VAR commit'
hb_expect_bypass "U10: --config-env core.hooksPath=ENV_VAR (space form)" \
    'git --config-env core.hooksPath=ENV_VAR commit'
hb_expect_bypass "U11: -C /repo --config-env=core.hooksPath=X commit" \
    'git -C /repo --config-env=core.hooksPath=X commit'

# Should return clean
hb_expect_clean "U12: literal in commit message (-m)" \
    'git commit -m "use git -c core.hooksPath=/dev/null"'
hb_expect_clean "U13: literal core.hooksPath in -m text" \
    "git commit -m 'core.hooksPath=foo'"
hb_expect_clean "U14: plain commit" \
    'git commit -m "msg"'
hb_expect_clean "U15: unrelated -c (user.name)" \
    'git -c user.name=foo commit -m "msg"'
hb_expect_clean "U16: git config core.hooksPath (subcommand, not -c)" \
    'git config core.hooksPath /dev/null'
hb_expect_clean "U17: -ccore.hooksPath=... (attached, out-of-scope)" \
    'git -ccore.hooksPath=/dev/null commit'
hb_expect_clean "U18: empty string" \
    ''
hb_expect_clean "U19: --config-env literal in -m" \
    'git commit -m "see --config-env=core.hooksPath=X"'

# GIT_CONFIG_PARAMETERS env-var prefix forms
hb_expect_bypass "U20: GIT_CONFIG_PARAMETERS unquoted" \
    "GIT_CONFIG_PARAMETERS='core.hooksPath=/dev/null' git commit"
hb_expect_bypass "U21: GIT_CONFIG_PARAMETERS double-quoted" \
    'GIT_CONFIG_PARAMETERS="core.hooksPath=/dev/null" git commit'
hb_expect_bypass "U22: GIT_CONFIG_PARAMETERS no quotes" \
    'GIT_CONFIG_PARAMETERS=core.hooksPath=/dev/null git commit'
hb_expect_bypass "U23: GIT_CONFIG_PARAMETERS nested single quotes" \
    'GIT_CONFIG_PARAMETERS="'"'"'core.hooksPath=/dev/null'"'"'" git commit'

# GIT_CONFIG_COUNT/KEY_N/VALUE_N
hb_expect_bypass "U24: GIT_CONFIG_COUNT=1 with KEY_0=core.hooksPath" \
    'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit'
hb_expect_bypass "U25: GIT_CONFIG_KEY_5=core.hooksPath (non-zero index)" \
    'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_5=core.hooksPath GIT_CONFIG_VALUE_5=/tmp git push'
hb_expect_bypass "U26: GIT_CONFIG_COUNT=2 mixed entries (one is hooksPath)" \
    "GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0='core.hooksPath' GIT_CONFIG_VALUE_0=/dev/null GIT_CONFIG_KEY_1=user.name GIT_CONFIG_VALUE_1=foo git commit"
hb_expect_bypass "U27: GIT_CONFIG_PARAMETERS list w/ hooksPath" \
    'GIT_CONFIG_PARAMETERS="'"'"'a=b'"'"' '"'"'core.hooksPath=/dev/null'"'"'" git commit'
hb_expect_bypass "U28: GIT_CONFIG_KEY_0 with extra env after" \
    'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath FOO=bar git push'
hb_expect_bypass "U28b: bare GIT_CONFIG_KEY_0 (no COUNT)" \
    'GIT_CONFIG_KEY_0=core.hooksPath git commit'
hb_expect_bypass "U29: trailing command after literal echo" \
    'echo "GIT_CONFIG_PARAMETERS=other"; GIT_CONFIG_PARAMETERS='"'"'core.hooksPath=/dev/null'"'"' git commit'

# Clean: literal-text false positives
hb_expect_clean "U30: -m literal with quoted -c" \
    "git commit -m 'use git -c \"core.hooksPath=/dev/null\"'"
hb_expect_clean "U31: -m double-quoted with literal single quotes" \
    'git commit -m "use git -c '"'"'core.hooksPath=/dev/null'"'"'"'
hb_expect_clean "U32: echo literal text (no git invocation)" \
    'echo "GIT_CONFIG_PARAMETERS='"'"'core.hooksPath=...'"'"' git"'
hb_expect_clean "U33: GIT_CONFIG_PARAMETERS unrelated key" \
    "GIT_CONFIG_PARAMETERS='user.name=foo' git commit"
hb_expect_clean "U34: GIT_CONFIG_KEY_0=user.name" \
    'GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=foo git commit'
hb_expect_clean "U35: literal key name inside -m" \
    "git commit -m 'GIT_CONFIG_KEY_0=core.hooksPath ...'"
hb_expect_clean "U36: GIT_CONFIG_COUNT=0" \
    'GIT_CONFIG_COUNT=0 git commit'
hb_expect_clean "U37: env-var prefixes echo, separator before git push" \
    "GIT_CONFIG_PARAMETERS='core.hooksPath=/dev/null' echo hi; git push"
hb_expect_clean "U38: env-var after && does not prefix git" \
    'cmd1 && GIT_CONFIG_KEY_0=core.hooksPath foo'
hb_expect_clean "U39: unrelated GIT_CONFIG_PARAMETERS + literal -m text" \
    "GIT_CONFIG_PARAMETERS='user.name=x' git commit -m \"core.hooksPath\""

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Section I: Integration tests (hook + linked worktree) ==="

# setup_linked_worktree echoes "<main_repo>|<wt_path>"; only the worktree side
# is the CWD these cases run from.
HB_PAIR="$(setup_linked_worktree 'int')"
HB_WT="${HB_PAIR#*|}"
if [ -z "$HB_WT" ] || [ ! -d "$HB_WT" ]; then
    fail "Section I: linked worktree setup failed"
else
    hb_expect_block "I1: -c core.hooksPath=/dev/null commit blocks" \
        'git -c core.hooksPath=/dev/null commit -m "msg"' "$HB_WT"
    hb_expect_block "I2: -c core.hooksPath= (empty) blocks" \
        'git -c core.hooksPath= commit' "$HB_WT"
    hb_expect_block "I3: --config-env=core.hooksPath=X blocks" \
        'git --config-env=core.hooksPath=X commit' "$HB_WT"
    hb_expect_block "I4: -c \"core.hooksPath=/dev/null\" blocks" \
        'git -c "core.hooksPath=/dev/null" commit' "$HB_WT"
    hb_expect_allow "I5: literal in -m message allows" \
        'git commit -m "git -c core.hooksPath=/dev/null"' "$HB_WT"
    hb_expect_allow "I6: literal in nested-quote -m message allows" \
        "git commit -m 'use git -c \"core.hooksPath=/dev/null\"'" "$HB_WT"
    hb_expect_block "I7: GIT_CONFIG_PARAMETERS env bypass blocks" \
        "GIT_CONFIG_PARAMETERS='core.hooksPath=/dev/null' git commit" "$HB_WT"
    hb_expect_block "I8: GIT_CONFIG_COUNT/KEY_N env bypass blocks" \
        'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit' "$HB_WT"
    hb_expect_block "I9: GIT_CONFIG_PARAMETERS list bypass blocks" \
        'GIT_CONFIG_PARAMETERS="'"'"'a=b'"'"' '"'"'core.hooksPath=/dev/null'"'"'" git commit' "$HB_WT"
    hb_expect_allow "I10: env-var prefixes echo (not git) allows" \
        "GIT_CONFIG_PARAMETERS='core.hooksPath=/dev/null' echo hi; git push" "$HB_WT"
    hb_expect_allow "I11: unrelated GIT_CONFIG_PARAMETERS + literal -m allows" \
        "GIT_CONFIG_PARAMETERS='user.name=x' git commit -m \"core.hooksPath\"" "$HB_WT"
    hb_expect_allow "I12: plain commit allows" \
        'git commit -m "msg"' "$HB_WT"
    hb_expect_allow "I13: git status (read) allows" \
        'git status' "$HB_WT"
fi

# Completion marker (dispatcher FRAG2) — must remain the last line.
frag_done "hooks-bypass-detection.sh"
