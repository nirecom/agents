# tests/feat-1699-meta-parent-guard/body-file-mode.sh
# Tests: bin/github-issues/issue-create-dispatch.sh
# Tags: issue-create, dispatch, sibling, tmpfile, permissions, leak, security, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Whether the surrounding directory permits traversal at all: on a host whose TMPDIR is
#   already per-user (systemd PrivateTmp, macOS per-user $TMPDIR) the mode matters less,
#   and on a shared /tmp it matters more. Only the file's own mode is pinned here.
# - Windows/MSYS hosts, where POSIX mode bits are not backed by the filesystem — the whole
#   group skips there rather than asserting something the platform cannot express.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# Group M — the sibling path's injected body file is not world-readable.
#
# `sibling` appends "Related to #N" to the body; with --body-file it cannot edit the
# caller's file, so it copies the body to a temp file. That copy holds the FULL issue body
# and sits in a shared temp directory for as long as `gh issue create` runs.
#
# The mode must be observed WHILE the file exists — the dispatcher removes it on exit, so
# a post-hoc stat only reports "gone". The probe therefore sits in the gh mock.

M_SKIP=0
m_skip() { echo "SKIP: $1"; M_SKIP=$((M_SKIP + 1)); }

setup_mock

# Platform gate: without POSIX mode bits (MSYS/Git-Bash) chmod is a no-op and every file
# reports 644, so the assertion would be a false RED, not a finding.
printf 'x' > "$TMP/mode-probe"
chmod 600 "$TMP/mode-probe" 2>/dev/null || true
M_MODE_OBSERVABLE=no
[ "$(stat -c '%a' "$TMP/mode-probe" 2>/dev/null)" = "600" ] && M_MODE_OBSERVABLE=yes

if [ "$M_MODE_OBSERVABLE" != "yes" ]; then
    m_skip "M0-sibling-body-file-rc0"
    m_skip "M1-injected-body-file-is-0600 (POSIX mode bits are not observable on this filesystem: chmod 600 reports $(stat -c '%a' "$TMP/mode-probe" 2>/dev/null || echo '<stat unavailable>'))"
    m_skip "M2-injected-body-file-is-not-the-caller-s"
    m_skip "M3-injected-body-file-is-removed-afterwards"
    teardown_mock
else
    # Records the mode of every --body-file operand, then delegates to the suite's shared
    # mock so the call accounting other groups rely on is unchanged.
    mkdir -p "$TMP/mode-bin"
    cat > "$TMP/mode-bin/gh" <<'MODE_EOF'
#!/usr/bin/env bash
_prev=""
for _a in "$@"; do
    if [ "$_prev" = "--body-file" ] && [ -f "$_a" ]; then
        printf '%s\t%s\n' "$_a" "$(stat -c '%a' "$_a" 2>/dev/null)" >> "$GH_BODYFILE_MODE_LOG"
    fi
    _prev="$_a"
done
exec "$GH_REAL_MOCK" "$@"
MODE_EOF
    chmod +x "$TMP/mode-bin/gh"
    export GH_BODYFILE_MODE_LOG="$TMP/bodyfile-modes.log"
    export GH_REAL_MOCK="$TMP/mock-bin/gh"
    : > "$GH_BODYFILE_MODE_LOG"
    M_OLD_PATH="$PATH"
    export PATH="$TMP/mode-bin:$PATH"

    # Deliberately world-readable: if the dispatcher forwarded it unchanged, M1 fails and
    # M2 names why.
    M_SRC="$TMP/caller-body.md"
    printf "$CANONICAL_BODY\n" > "$M_SRC"
    chmod 644 "$M_SRC"

    export GH_MOCK_NEW_ISSUE_NUM=321
    run_dispatch --verdict sibling --related "42" -- \
        --title "sibling with a body file" --body-file "$M_SRC"

    if [ "$RC" -eq 0 ]; then
        pass "M0-sibling-body-file-rc0"
    else
        fail "M0-sibling-body-file-rc0" "want rc 0 (got: $RC); stderr: $ERR"
    fi

    M_LINE="$(tail -n 1 "$GH_BODYFILE_MODE_LOG" 2>/dev/null)"
    M_PATH="$(printf '%s' "$M_LINE" | cut -f1)"
    M_MODE="$(printf '%s' "$M_LINE" | cut -f2)"

    if [ -z "$M_LINE" ]; then
        fail "M1-injected-body-file-is-0600" "no --body-file ever reached gh, so the mode was never observed — the sibling path did not inject a body file"
        fail "M2-injected-body-file-is-not-the-caller-s" "no --body-file reached gh"
        fail "M3-injected-body-file-is-removed-afterwards" "no --body-file reached gh"
    else
        if [ "$M_MODE" = "600" ]; then
            pass "M1-injected-body-file-is-0600"
        else
            fail "M1-injected-body-file-is-0600" "the injected body temp file was mode $M_MODE while gh read it — the full issue body was readable by every account on the host ($M_PATH)"
        fi

        # Non-vacuity: 600 would also be reported for a forwarded caller file that happened
        # to be private. The source here is 644 on purpose.
        if [ "$M_PATH" != "$M_SRC" ]; then
            pass "M2-injected-body-file-is-not-the-caller-s"
        else
            fail "M2-injected-body-file-is-not-the-caller-s" "the dispatcher passed the caller's own file ($M_SRC) to gh, so M1 says nothing about the temp copy it is supposed to create"
        fi

        # Second defence: the file must not outlive the run. Both are asserted.
        if [ ! -e "$M_PATH" ]; then
            pass "M3-injected-body-file-is-removed-afterwards"
        else
            fail "M3-injected-body-file-is-removed-afterwards" "the injected body temp file survived the dispatcher: $M_PATH"
        fi
    fi

    export PATH="$M_OLD_PATH"
    unset GH_BODYFILE_MODE_LOG GH_REAL_MOCK
    teardown_mock
fi

if [ "$M_SKIP" -gt 0 ]; then
    echo "note: Group M skipped $M_SKIP case(s) — POSIX mode bits unobservable on this host"
fi
