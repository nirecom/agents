# Sourced by tests/install/feature-2476-installer-cc-wait-once.sh.
# Group G: the real claude-code child + the REAL wait helper (copied into a mock root,
# unlike feature-2284 exec-integration.sh which mocks the helper) honor the parent memo.
# The process probe contradicts the memo so only a honored memo passes.

_CC_SH="$AGENTS_DIR/install/linux/claude-code.sh"
_CC_PS="$AGENTS_DIR/install/win/claude-code.ps1"

# _g_sh <label> <memo> <pgrep-exit> -> G_RC, G_LOG, G_SECS
_g_sh() {
    local label="$1" memo="$2" pexit="$3"
    local root="$TMP/g-root-$label" stub="$TMP/g-stub-$label" start=$SECONDS
    G_LOG="$TMP/g-log-$label.txt"
    mkdir -p "$root/install/linux" "$root/install/lib" "$stub" "$TMP/g-home"
    cp "$_CC_SH" "$root/install/linux/claude-code.sh"
    cp "$WAIT_SH" "$root/install/lib/wait-cc-exit.sh"
    printf '#!/bin/bash\necho "$@" >> "%s"\nexit 0\n' "$G_LOG" > "$stub/claude"
    printf '#!/bin/bash\n[ "%s" = "0" ] && echo 4242\nexit %s\n' "$pexit" "$pexit" > "$stub/pgrep"
    chmod +x "$stub/claude" "$stub/pgrep"
    G_RC=0
    env -i PATH="$stub:/usr/bin:/bin" HOME="$TMP/g-home" AGENTS_ROOT="$root" \
        WAIT_CC_RESULT="$memo" WAIT_CC_POLL_INTERVAL=1 WAIT_CC_MAX_POLLS=2 \
        bash "$root/install/linux/claude-code.sh" > "$TMP/g-$label.out" 2>&1 || G_RC=$?
    G_SECS=$((SECONDS - start))
}

if [ ! -f "$_CC_SH" ] || [ ! -f "$WAIT_SH" ]; then
    fail "G-sh: claude-code.sh or wait-cc-exit.sh missing"
else
    _g_sh sh-clear clear 0
    if grep -q '^update' "$G_LOG" 2>/dev/null && [ "$G_SECS" -lt 2 ]; then
        pass "G-sh-clear: memo clear + pgrep alive -> claude update called at once (${G_SECS}s)"
    else
        fail "G-sh-clear: want update within 2s" "rc=$G_RC ${G_SECS}s $(head -n 3 "$TMP/g-sh-clear.out")"
    fi

    _g_sh sh-timeout timeout 1
    if ! grep -q '^update' "$G_LOG" 2>/dev/null && [ "$G_RC" = "0" ]; then
        pass "G-sh-timeout: memo timeout + pgrep absent -> update skipped, rc 0"
    else
        fail "G-sh-timeout: want no update and rc 0" "rc=$G_RC $(head -n 3 "$TMP/g-sh-timeout.out")"
    fi
fi

# _g_ps <label> <memo> <override> -> G_RC, G_LOG, G_SECS
_g_ps() {
    local label="$1" memo="$2" ovr="$3"
    local root="$TMP/g-root-$label" stub="$TMP/g-stub-$label" start=$SECONDS
    G_LOG="$TMP/g-log-$label.txt"
    mkdir -p "$root/install/win" "$root/install/lib" "$stub"
    cp "$_CC_PS" "$root/install/win/claude-code.ps1"
    cp "$WAIT_PS" "$root/install/lib/"
    [ -f "$TARGET_PS" ] && cp "$TARGET_PS" "$root/install/lib/"
    # claude.cmd shadows any real claude on Windows; the bash stub serves POSIX pwsh.
    printf '@echo off\r\necho %%* >> "%s"\r\nexit /b 0\r\n' "$(np "$G_LOG")" > "$stub/claude.cmd"
    printf '#!/bin/bash\necho "$@" >> "%s"\nexit 0\n' "$G_LOG" > "$stub/claude"
    chmod +x "$stub/claude"
    G_RC=0
    env PATH="$stub:$PATH" AGENTS_ROOT="$(np "$root")" \
        WAIT_CC_RESULT="$memo" WAIT_CC_PROCESS_OVERRIDE="$ovr" WAIT_CC_POLL_INTERVAL=1 WAIT_CC_MAX_POLLS=2 \
        bash "$RWT" 60 pwsh -NoProfile -NonInteractive -File "$(np "$root/install/win/claude-code.ps1")" \
        > "$TMP/g-$label.out" 2>&1 || G_RC=$?
    G_SECS=$((SECONDS - start))
}

if [ "$HAVE_PWSH" = "0" ]; then
    skip "G-ps: pwsh not on PATH — claude-code.ps1 memo cases skipped"
elif [ ! -f "$_CC_PS" ] || [ ! -f "$WAIT_PS" ]; then
    fail "G-ps: claude-code.ps1 or wait-cc-exit.ps1 missing"
else
    _g_ps ps-clear clear alive
    if grep -q '^update' "$G_LOG" 2>/dev/null; then
        pass "G-ps-clear: memo clear + override alive -> claude update called (${G_SECS}s)"
    else
        fail "G-ps-clear: claude update not called" "rc=$G_RC ${G_SECS}s $(tr -d '\r' < "$TMP/g-ps-clear.out" | head -n 3)"
    fi

    _g_ps ps-timeout timeout none
    if ! grep -q '^update' "$G_LOG" 2>/dev/null && [ "$G_RC" = "0" ]; then
        pass "G-ps-timeout: memo timeout + override none -> update skipped, rc 0"
    else
        fail "G-ps-timeout: want no update and rc 0" "rc=$G_RC $(tr -d '\r' < "$TMP/g-ps-timeout.out" | head -n 3)"
    fi
fi
