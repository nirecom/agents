#!/usr/bin/env bash
# tests/feature-2223-show-local-env-overrides/degradation.sh
# Tests: bin/show-local-env-overrides, hooks/lib/load-env.js, hooks/lib/local-env.js
# Tags: scope:issue-specific, TL2, load-env, local-env, degradation, cli, pwsh-not-required
# Case file for tests/feature-2223-show-local-env-overrides.sh — sourced from it,
# never run standalone (it uses that file's helpers, fixtures and counters).
# Holds the cases where something about the environment is degraded: a malformed
# or Windows-native override file, and a host with no git on PATH.
# TL3 gap: same as the parent's.
SHOW_LOCAL_ENV_DEGRADATION_CASES_LOADED=1

# ---------------------------------------------------------------------------
# G7: a malformed override file. An unterminated quote discards that key and
# silently absorbs every following line to the next quote, so keys the human
# wrote appear in NEITHER section — which is exactly the question this tool
# answers, and the one shape the report cannot express.
# ---------------------------------------------------------------------------
new_case malformed 'CODE_LANG=english' \
  'EARLY_KEY=SENT2223-early-6f1ad8@NL@PROJECT_NFR="SENT2223-unterminated-2be904@NL@SWALLOWED_KEY=SENT2223-swallowed-c37f10@NL@LATER_KEY=SENT2223-later-90d6bb'
run_cli --repo-root "$CASE_ROOT_NODE"
assert_eq "T2223S-malformed-exit-0" "0" "$CLI_RC"
assert_contains "T2223S-malformed-early-key-applied" "$(section_keys "$CLI_OUT" applied)" "EARLY_KEY"
assert_contains "T2223S-malformed-diagnostic-names-key" "$CLI_ERR" "PROJECT_NFR discarded"
# Non-vacuous: the diagnostic above put real content on this stream.
assert_not_contains "T2223S-malformed-no-value-leak-stderr" "$CLI_ERR" "SENT2223-"
assert_report_lacks "T2223S-malformed-no-value-leak-stdout" "$CLI_OUT" "SENT2223-"
# The swallow window: everything after the opening quote is gone from both
# sections, so exactly one key survives.
assert_eq "T2223S-malformed-applied-count" "1" "$(section_count "$CLI_OUT" applied)"
assert_report_lacks "T2223S-malformed-swallowed-key-absent" "$CLI_OUT" "SWALLOWED_KEY"
assert_report_lacks "T2223S-malformed-later-key-absent" "$CLI_OUT" "LATER_KEY"

# ---------------------------------------------------------------------------
# G15: a Windows-native override file — CRLF line endings and a Notepad UTF-8
# BOM. On this repo's primary host that is the ordinary shape of the file. If
# the normalization regressed, the failure is a blocklist bypass: an
# ENFORCE_WORKTREE carrying a trailing CR misses the exact set.
# ---------------------------------------------------------------------------
new_case crlf-bom 'CODE_LANG=english@NL@ENFORCE_WORKTREE=on' '__NONE__'
printf '\xEF\xBB\xBFBOM_FIRST_KEY=SENT2223-bom-4a02c6\r\nPROJECT_NFR=SENT2223-crlf-nfr-e71b35\r\nENFORCE_WORKTREE=SENT2223-crlf-blocked-18d7fa\r\n' \
  > "$CASE_ROOT/$LOCAL_ENV_BASENAME"
run_cli --repo-root "$CASE_ROOT_NODE"
assert_eq "T2223S-crlf-bom-exit-0" "0" "$CLI_RC"
assert_eq "T2223S-crlf-bom-refused" "ENFORCE_WORKTREE" \
  "$(section_keys "$CLI_OUT" "refused by blocklist")"
# The BOM did not eat the first key's name.
assert_eq "T2223S-crlf-bom-applied" "$(printf 'BOM_FIRST_KEY\nPROJECT_NFR')" \
  "$(section_keys "$CLI_OUT" applied)"
assert_report_lacks "T2223S-crlf-bom-no-carriage-return" "$CLI_OUT" "$(printf '\r')"
assert_report_lacks "T2223S-crlf-bom-no-value-leak" "$CLI_OUT" "SENT2223-"

# ---------------------------------------------------------------------------
# G17: a duplicate key and lines the KEY=VALUE grammar cannot parse. The last
# spelling of a duplicate wins and the key is named once; an unparsable line is
# dropped outright, never reclassified as refused.
# ---------------------------------------------------------------------------
new_case duplicate-and-unparsable 'CODE_LANG=english' \
  'PROJECT_NFR=a@NL@PROJECT_NFR=b@NL@2BAD_KEY=x@NL@BAD-KEY=y@NL@ =z'
run_cli --repo-root "$CASE_ROOT_NODE"
assert_eq "T2223S-duplicate-exit-0" "0" "$CLI_RC"
assert_eq "T2223S-duplicate-applied" "PROJECT_NFR" "$(section_keys "$CLI_OUT" applied)"
assert_eq "T2223S-duplicate-applied-count" "1" "$(section_count "$CLI_OUT" applied)"
assert_report_lacks "T2223S-unparsable-numeric-key-absent" "$CLI_OUT" "2BAD_KEY"
assert_report_lacks "T2223S-unparsable-hyphen-key-absent" "$CLI_OUT" "BAD-KEY"
assert_eq "T2223S-unparsable-not-refused" "0" \
  "$(section_count "$CLI_OUT" "refused by blocklist")"

# ---------------------------------------------------------------------------
# G16: warnIfTracked fails open when git is not on PATH at all. The half that
# matters is the report: it is never withheld over a failed probe.
# The runner below cannot use run_cli_in — that wrapper resolves `timeout` and
# `perl` through PATH, which is the very thing this case takes away.
# ---------------------------------------------------------------------------
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || true)"

run_cli_with_path() {
    local cwd="$1" newpath="$2"; shift 2
    local outf="$TMP_ROOT/cli-out.txt" errf="$TMP_ROOT/cli-err.txt"
    local cfg; cfg="$(to_node_path "$CASE_CFG")"
    CLI_RC=0
    (
        cd "$cwd" || exit 70
        export PATH="$newpath"
        export AGENTS_CONFIG_DIR="$cfg"
        if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" 20 node "$CLI_NODE" "$@"
        else node "$CLI_NODE" "$@"; fi
    ) >"$outf" 2>"$errf" || CLI_RC=$?
    CLI_OUT="$(cat "$outf")"
    CLI_ERR="$(cat "$errf")"
}

NODE_BIN="$(command -v node 2>/dev/null || true)"
if [ -z "$NODE_BIN" ]; then
    fail "T2223S-nogit — precondition broken: node is not on PATH, so no reduced PATH can be built"
elif ! command -v git >/dev/null 2>&1; then
    fail "T2223S-nogit — git unavailable; the tracked fixture this case degrades cannot be built"
else
    NODE_ONLY_PATH="$(dirname "$NODE_BIN")"
    if PATH="$NODE_ONLY_PATH" command -v git >/dev/null 2>&1; then
        fail "T2223S-nogit — precondition broken: git is still reachable from $NODE_ONLY_PATH"
    else
        new_git_case nogit 'CODE_LANG=english@NL@ENFORCE_WORKTREE=on' \
          'PROJECT_NFR=SENT2223-nogit-nfr-7c40e9@NL@ENFORCE_WORKTREE=SENT2223-nogit-blocked-25ba81'
        NOGIT_ADD_RC=0
        git -C "$CASE_ROOT" add -- "$LOCAL_ENV_BASENAME" >/dev/null 2>&1 || NOGIT_ADD_RC=$?
        assert_eq "T2223S-nogit-fixture-staged" "0" "$NOGIT_ADD_RC"
        run_cli_with_path "$TMP_ROOT" "$NODE_ONLY_PATH" --repo-root "$CASE_ROOT_NODE"
        assert_eq "T2223S-nogit-exit-0" "0" "$CLI_RC"
        assert_not_contains "T2223S-nogit-no-warning" "$CLI_ERR" "$WARN_TEXT"
        # The load-bearing half: a failed probe never withholds the report.
        assert_eq "T2223S-nogit-report-still-applied" "PROJECT_NFR" \
          "$(section_keys "$CLI_OUT" applied)"
        assert_eq "T2223S-nogit-report-still-refused" "ENFORCE_WORKTREE" \
          "$(section_keys "$CLI_OUT" "refused by blocklist")"
        assert_report_lacks "T2223S-nogit-no-value-leak" "$CLI_OUT" "SENT2223-"
    fi
fi
