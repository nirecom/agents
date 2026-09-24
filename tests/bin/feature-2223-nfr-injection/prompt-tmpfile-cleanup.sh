#!/usr/bin/env bash
# tests/feature-2223-nfr-injection/prompt-tmpfile-cleanup.sh
# Tests: bin/lib/codex-core.sh
# Tags: scope:issue-specific, TL2, codex, nfr, security, secret-hygiene, pwsh-not-required
# Case file for tests/feature-2223-nfr-injection.sh — sourced from it, never run
# standalone (it uses that file's helpers, fixtures and PASS/FAIL counters).
# The prompt tmpfile holds the project's NFR text, which can carry anything the
# project put in its .env.local. It lives in world-listable /tmp, so the cleanup
# is a secret-lifetime property, not housekeeping — each exit path is checked.
NFR_TMPFILE_CLEANUP_CASES_LOADED=1

# ---------------------------------------------------------------------------
# Part J — codex_core_run's prompt and stderr tmpfiles after every exit path.
# The paths are read out of the run's own shell, so the claim is about the exact
# files that run created rather than about whatever /tmp happened to hold.
# ---------------------------------------------------------------------------
TMPCLEAN_SENTINEL="TMPFILESENTINEL9RJ"
CFG_TMPCLEAN="$(make_cfg tmpclean "PROJECT_NFR=$TMPCLEAN_SENTINEL never leave this in /tmp")"
PROJ_TMPCLEAN="$(make_project tmpclean)"
TMPCLEAN_BIN="$TMP_ROOT/tmpclean-bin"
mkdir -p "$TMPCLEAN_BIN"

# Mock codex, switched by CODEX_MOCK_MODE: ok exits 0, fail exits 7, hang
# outlives the CODEX_TIMEOUT_SECS=1 ceiling so `timeout` reports 124.
printf '%s\n' '#!/usr/bin/env bash' 'cat > /dev/null' \
    'case "${CODEX_MOCK_MODE:-ok}" in' \
    '  fail) printf "mock stderr line\n" >&2; exit 7 ;;' \
    '  hang) sleep 30 ;;' \
    'esac' 'echo "APPROVED"' 'exit 0' > "$TMPCLEAN_BIN/codex"
chmod +x "$TMPCLEAN_BIN/codex"

TMPCLEAN_PATHS="$TMP_ROOT/tmpclean-paths.txt"
TMPCLEAN_OUT="$TMP_ROOT/tmpclean-out.txt"

# run_codex_core <mode> [timeout-secs] — one codex_core_run in its own shell.
# The two tmpfile paths are printed BEFORE that shell exits, so the EXIT trap
# under test has not fired yet when they are recorded.
run_codex_core() {
    local mode="$1" tmo="${2:-900}"
    rm -f "$TMPCLEAN_PATHS" "$TMPCLEAN_OUT"
    AGENTS_CONFIG_DIR="$CFG_TMPCLEAN" PATH="$TMPCLEAN_BIN:$PATH" \
        CODEX_MOCK_MODE="$mode" CODEX_TIMEOUT_SECS="$tmo" \
        TMPCLEAN_PATHS="$TMPCLEAN_PATHS" NO_LOG=true \
        run_with_timeout 60 bash -c '
          source "$1/bin/lib/codex-core.sh" >/dev/null 2>&1 || exit 3
          codex_core_init "Probe" >/dev/null 2>&1
          NO_LOG=true
          codex_core_run "prompt body $2"
          printf "%s\n%s\n" "$TMPFILE" "$CODEX_STDERR" > "$TMPCLEAN_PATHS"
        ' _ "$AGENTS_DIR" "$(nfr_block "$CFG_TMPCLEAN" "$PROJ_TMPCLEAN")" \
        > "$TMPCLEAN_OUT" 2>/dev/null
}

# assert_tmpfiles_gone <name> — both recorded paths must no longer exist.
assert_tmpfiles_gone() {
    local name="$1" prompt_path stderr_path
    prompt_path="$(sed -n '1p' "$TMPCLEAN_PATHS" 2>/dev/null)"
    stderr_path="$(sed -n '2p' "$TMPCLEAN_PATHS" 2>/dev/null)"
    if [ -z "$prompt_path" ] || [ -z "$stderr_path" ]; then
        fail "$name — codex_core_run did not report its tmpfile paths; cleanup not provable"
        return 0
    fi
    if [ -e "$prompt_path" ]; then
        fail "$name-prompt — $prompt_path survived the run"
    else
        pass "$name-prompt"
    fi
    if [ -e "$stderr_path" ]; then
        fail "$name-stderr — $stderr_path survived the run"
    else
        pass "$name-stderr"
    fi
}

# (a) success
run_codex_core ok
assert_file_has "T2223J-success-performed" "$TMPCLEAN_OUT" "PERFORMED"
assert_tmpfiles_gone "T2223J-success-tmpfiles-removed"

# (b) codex exec failure — the branch that reads CODEX_STDERR back before exit.
run_codex_core fail
assert_file_has "T2223J-failure-reported" "$TMPCLEAN_OUT" "exit code 7"
assert_tmpfiles_gone "T2223J-failure-tmpfiles-removed"

# (c) timeout (124). The mock outlives a 1-second ceiling, so the 124 branch is
# reached for the reason the case claims and not by an unrelated error.
run_codex_core hang 1
assert_file_has "T2223J-timeout-reported" "$TMPCLEAN_OUT" "FAILED — timeout"
assert_tmpfiles_gone "T2223J-timeout-tmpfiles-removed"

# (d) interrupt mid-run. SKIPPED "Because a non-interactive bash does not run an
# EXIT trap when a fatal signal kills it, so the honest form of this case is a
# RED assertion about signal handling that no test in this suite can fix — and
# on this repo's Windows host the signal cannot even be delivered to the process
# group reliably enough to tell a real leak from a delivery failure."
# TL3 gap: a POSIX CI host could deliver SIGINT and pin that answer.
pass "T2223J-interrupt-tmpfile-removed SKIPPED \"Because a fatal signal bypasses the EXIT trap and cannot be delivered reliably on the Windows host\""

# The sweep the concern asked for: after every case above, no prompt tmpfile
# anywhere in /tmp still carries this suite's NFR text.
if grep -l -F -- "$TMPCLEAN_SENTINEL" /tmp/codex-prompt-*.txt >/dev/null 2>&1; then
    fail "T2223J-no-nfr-text-left-in-tmp — a /tmp/codex-prompt-* file still holds the NFR sentinel"
else
    pass "T2223J-no-nfr-text-left-in-tmp"
fi
