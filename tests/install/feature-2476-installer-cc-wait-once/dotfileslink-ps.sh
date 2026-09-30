# Sourced by tests/install/feature-2476-installer-cc-wait-once.sh.
# TL2 (Windows only): dotfileslink.ps1 on a wait timeout skips only the settings.json
# write (node not called) and still sets core.hooksPath and writes the launchers.
# The override is set to contradict the memo so only a honored memo passes.

if [ "$ON_WINDOWS_BASH" = "0" ]; then
    skip "DL-ps: dotfileslink.ps1 needs Windows (WindowsIdentity privilege check, node.cmd stub)"
elif [ "$HAVE_PWSH" = "0" ]; then
    skip "DL-ps: pwsh not on PATH"
else
    # _dl_run <label> <memo> <override> -> DL_RC, DL_OUT, DL_HOME, DL_NODELOG
    _dl_run() {
        local label="$1" memo="$2" ovr="$3"
        local root="$TMP/dl-root-$label" stub="$TMP/dl-stub-$label"
        DL_HOME="$TMP/dl-home-$label"
        DL_NODELOG="$TMP/dl-node-$label.log"
        mkdir -p "$root/install/win" "$root/install/lib" "$stub" "$DL_HOME"
        cp "$AGENTS_DIR/install/win/dotfileslink.ps1" "$root/install/win/"
        cp "$WAIT_PS" "$root/install/lib/"
        [ -f "$TARGET_PS" ] && cp "$TARGET_PS" "$root/install/lib/"
        printf '@echo off\r\necho %%* >> "%s"\r\nexit /b 0\r\n' "$(cygpath -w "$DL_NODELOG")" > "$stub/node.cmd"
        DL_RC=0
        DL_OUT="$(env PATH="$stub:$PATH" \
            DOTFILESLINK_HOME_OVERRIDE="$(cygpath -w "$DL_HOME")" DOTFILESLINK_SKIP_PRIV_CHECK=1 \
            WAIT_CC_RESULT="$memo" WAIT_CC_PROCESS_OVERRIDE="$ovr" \
            WAIT_CC_POLL_INTERVAL=1 WAIT_CC_MAX_POLLS=1 \
            bash "$RWT" 90 pwsh -NoProfile -NonInteractive -File "$(cygpath -w "$root/install/win/dotfileslink.ps1")" 2>&1)" || DL_RC=$?
        DL_OUT="$(printf '%s' "$DL_OUT" | tr -d '\r')"
    }

    _dl_run timeout timeout none
    _dl_hooks="$(git config --file "$DL_HOME/.gitconfig" core.hooksPath 2>/dev/null || true)"
    _dl_problems=""
    [ "$DL_RC" = "0" ] || _dl_problems="$_dl_problems rc=$DL_RC"
    printf '%s' "$DL_OUT" | grep -q 'skipping settings.json write' || _dl_problems="$_dl_problems no-warning"
    [ ! -s "$DL_NODELOG" ] || _dl_problems="$_dl_problems node-called"
    [ -n "$_dl_hooks" ] || _dl_problems="$_dl_problems no-hooksPath"
    [ -f "$DL_HOME/.local/bin/doc-append.cmd" ] || _dl_problems="$_dl_problems no-doc-append.cmd"
    if [ -z "$_dl_problems" ]; then
        pass "DL-ps-timeout: memo timeout -> warning, node skipped, hooksPath set, launcher written, rc 0"
    else
        fail "DL-ps-timeout:$_dl_problems" "$(printf '%s' "$DL_OUT" | grep -iE 'warn|error|exception' | head -n 3)"
    fi

    _dl_run clear clear alive
    if grep -q 'assemble-settings\.js' "$DL_NODELOG" 2>/dev/null; then
        pass "DL-ps-clear: memo clear (CC alive) -> node assemble-settings.js called"
    else
        fail "DL-ps-clear: node assemble-settings.js not called" \
            "rc=$DL_RC $(printf '%s' "$DL_OUT" | grep -iE 'warn|error|poll' | head -n 3)"
    fi
fi
