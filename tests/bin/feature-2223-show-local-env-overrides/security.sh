#!/usr/bin/env bash
# tests/feature-2223-show-local-env-overrides/security.sh
# Tests: bin/show-local-env-overrides, hooks/lib/local-env.js, hooks/lib/load-env.js
# Tags: scope:issue-specific, TL2, load-env, local-env, security, secret-leakage, trust-boundary, pwsh-not-required
# Case file for tests/feature-2223-show-local-env-overrides.sh — sourced from it,
# never run standalone (it uses that file's helpers, fixtures and counters).
# Holds the cases where the override file is treated as hostile input: it comes
# from a directory this machine did not necessarily author, and the CLI both
# spawns git in that directory and prints a line-oriented report about it.
# TL3 gap: same as the parent's.
SHOW_LOCAL_ENV_SECURITY_CASES_LOADED=1

# ---------------------------------------------------------------------------
# G3: a hostile override file must not reach the CLI's own `git ls-files` spawn.
# warnIfTracked is the only subprocess in the whole #2223 family and its child
# inherits this process's environment, so the file naming PATH and NODE_OPTIONS
# is the attack. The CLI never calls loadDefaultEnv(), and requiring load-env.js
# has no load-time side effect — these rows pin that.
# ---------------------------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
    fail "T2223S-hostile-env — git unavailable; the spawn under attack cannot be exercised"
else
    S_HOSTILE="SENT2223-hostile-0d47b2"
    new_git_case hostile-env 'CODE_LANG=english' \
      "PATH=/nonexistent@NL@GIT_SSH_COMMAND=touch pwned-2223@NL@NODE_OPTIONS=--require /nonexistent-2223.js@NL@PROJECT_NFR=$S_HOSTILE"
    HOSTILE_ADD_RC=0
    git -C "$CASE_ROOT" add -- "$LOCAL_ENV_BASENAME" >/dev/null 2>&1 || HOSTILE_ADD_RC=$?
    assert_eq "T2223S-hostile-env-fixture-staged" "0" "$HOSTILE_ADD_RC"
    run_cli --repo-root "$CASE_ROOT_NODE"

    assert_eq "T2223S-hostile-env-exit-0" "0" "$CLI_RC"
    # Load-bearing: the warning can only appear if git was still found, i.e. the
    # local PATH never reached the spawn. A NODE_OPTIONS that had reached this
    # process would have aborted node before any of it, so that key rides along.
    assert_contains "T2223S-hostile-env-git-still-ran" "$CLI_ERR" "$WARN_TEXT"
    if [ -e "$CASE_ROOT/pwned-2223" ] || [ -e "$TMP_ROOT/pwned-2223" ] || [ -e "./pwned-2223" ]; then
        fail "T2223S-hostile-env-no-execution — a local override value was executed"
    else
        pass "T2223S-hostile-env-no-execution"
    fi
    # The honest current classification of the process-runtime key class: these
    # keys are reported as applied because the blocklist does not name them.
    # A follow-up that adds them to the blocklist flips this row deliberately.
    assert_eq "T2223S-hostile-env-applied" \
      "$(printf 'GIT_SSH_COMMAND\nNODE_OPTIONS\nPATH\nPROJECT_NFR')" \
      "$(section_keys "$CLI_OUT" applied)"
    assert_report_lacks "T2223S-hostile-env-no-value-leak-stdout" "$CLI_OUT" "SENT2223-"
    assert_not_contains "T2223S-hostile-env-no-value-leak-stderr" "$CLI_ERR" "SENT2223-"
    assert_not_contains "T2223S-hostile-env-no-path-leak-stderr" "$CLI_ERR" "/nonexistent"
fi

# ---------------------------------------------------------------------------
# G5: a project root full of shell metacharacters. Both sibling readers got this
# case in the parent suite (T2223R-meta-path-*) and this is the CLI that hands
# the root to spawnSync, so CPR-ORTH demands it here too.
# ---------------------------------------------------------------------------
new_case meta-root 'CODE_LANG=english@NL@ENFORCE_WORKTREE=on' '__NONE__'
META_PARENT="$CASE_ROOT/holder"
META_ROOT="$META_PARENT/pr oj \$(touch pwned) ;touch pwned& \`touch pwned\`"
mkdir -p "$META_ROOT/.git"
printf 'PROJECT_NFR=SENT2223-meta-nfr-8ea3f1\nENFORCE_WORKTREE=SENT2223-meta-blocked-b52c09\n' \
  > "$META_ROOT/$LOCAL_ENV_BASENAME"
run_cli --repo-root "$(to_node_path "$META_ROOT")"
assert_eq "T2223S-meta-root-exit-0" "0" "$CLI_RC"
assert_eq "T2223S-meta-root-applied" "PROJECT_NFR" "$(section_keys "$CLI_OUT" applied)"
assert_eq "T2223S-meta-root-refused" "ENFORCE_WORKTREE" \
  "$(section_keys "$CLI_OUT" "refused by blocklist")"
if [ -e "$META_PARENT/pwned" ] || [ -e "$META_ROOT/pwned" ] || [ -e "$TMP_ROOT/pwned" ] \
   || [ -e "./pwned" ]; then
    fail "T2223S-meta-root-no-execution — a metacharacter in the project root ran"
else
    pass "T2223S-meta-root-no-execution"
fi
assert_report_lacks "T2223S-meta-root-no-value-leak" "$CLI_OUT" "SENT2223-"

# ---------------------------------------------------------------------------
# G9: a value shaped like the report's own output. For a line-oriented names-only
# report the interesting attack is a legal multi-line quoted value impersonating
# a section heading and an applied-key row.
# ---------------------------------------------------------------------------
new_case injection 'CODE_LANG=english' \
  'PROJECT_NFR="SENT2223-inj-4c70da@NL@  FAKE_APPLIED_KEY@NL@refused by blocklist (99)"@NL@OTHER_KEY=applied (99)'
run_cli --repo-root "$CASE_ROOT_NODE"
assert_eq "T2223S-injection-exit-0" "0" "$CLI_RC"
assert_eq "T2223S-injection-applied-keys" "$(printf 'OTHER_KEY\nPROJECT_NFR')" \
  "$(section_keys "$CLI_OUT" applied)"
assert_eq "T2223S-injection-applied-count" "2" "$(section_count "$CLI_OUT" applied)"
assert_report_lacks "T2223S-injection-no-fake-key" "$CLI_OUT" "FAKE_APPLIED_KEY"
assert_report_lacks "T2223S-injection-no-value-leak" "$CLI_OUT" "SENT2223-"
assert_eq "T2223S-injection-one-applied-heading" "1" \
  "$(printf '%s\n' "$CLI_OUT" | grep -c '^applied (')"
assert_eq "T2223S-injection-one-refused-heading" "1" \
  "$(printf '%s\n' "$CLI_OUT" | grep -c '^refused by blocklist (')"

# ---------------------------------------------------------------------------
# G12: the headline security decision — there is no value-printing door here at
# all. Unnamed, a future edit that adds one would read as a feature.
# ---------------------------------------------------------------------------
new_case no-dump-door 'CODE_LANG=english' 'PROJECT_NFR=SENT2223-door-a90b3e'
for _door in --allow-dump --values --dump --show-values; do
    run_cli_in "$CASE_ROOT" "$_door"
    assert_eq "T2223S-no-door$_door-exit-64" "64" "$CLI_RC"
    assert_eq "T2223S-no-door$_door-empty-stdout" "" "$CLI_OUT"
    # Non-vacuous: the usage line puts real content on this stream.
    assert_contains "T2223S-no-door$_door-usage-stderr" "$CLI_ERR" \
      "usage: show-local-env-overrides"
    assert_not_contains "T2223S-no-door$_door-no-value-leak" "$CLI_ERR" "SENT2223-"
done
