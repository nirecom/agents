# ---------------------------------------------------------------------------
# Section 4: install.sh always calls glab.sh (flag gate is inside glab.sh)
# ---------------------------------------------------------------------------

INSTALL_SH_OK=0
[ -f "$INSTALL_SH" ] && INSTALL_SH_OK=1

build_fake_root() {
    local n="$1"
    local FAKE_ROOT="$TMP/fake-$n"
    mkdir -p "$FAKE_ROOT/install/linux" "$FAKE_ROOT/mock-bin" "$FAKE_ROOT/fake-nvm"

    for _stub in dotfileslink.sh claude-code.sh session-sync-init.sh vscode-settings.sh \
                 global-gitignore.sh codex.sh jq.sh shellcheck.sh pwsh.sh codegraph.sh rtk.sh; do
        printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_ROOT/install/linux/$_stub"
        chmod +x "$FAKE_ROOT/install/linux/$_stub"
    done
    unset _stub

    printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$TMP/${n}-gh-marker" \
        > "$FAKE_ROOT/install/linux/gh.sh"
    printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$TMP/${n}-glab-marker" \
        > "$FAKE_ROOT/install/linux/glab.sh"
    chmod +x "$FAKE_ROOT/install/linux/gh.sh" "$FAKE_ROOT/install/linux/glab.sh"

    printf '# fake nvm\n' > "$FAKE_ROOT/fake-nvm/nvm.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_ROOT/mock-bin/npm"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_ROOT/mock-bin/claude"
    chmod +x "$FAKE_ROOT/mock-bin/npm" "$FAKE_ROOT/mock-bin/claude"

    printf '# agents profile snippet\n' > "$FAKE_ROOT/profile-snippet.sh"
    cp "$INSTALL_SH" "$FAKE_ROOT/install.sh"
}

run_install() {
    local fake_root="$1"
    local fake_home="$TMP/home-run-$$"
    mkdir -p "$fake_home"
    touch "$fake_home/.bashrc"
    run_with_timeout 30 env -i \
        PATH="$fake_root/mock-bin:$PATH" \
        HOME="$fake_home" \
        NVM_DIR="$fake_root/fake-nvm" \
        SHELL="/bin/bash" \
        TERM="dumb" \
        bash "$fake_root/install.sh" \
        >/dev/null 2>/dev/null
}

case_begin "T7" "install.sh"
# T7: install.sh always calls glab.sh (GITLAB gate lives inside glab.sh, not install.sh)
if [ "$INSTALL_SH_OK" = "1" ]; then
    build_fake_root "t7"
    run_install "$TMP/fake-t7"
    RC=$?
    GH_CALLED=$([ -f "$TMP/t7-gh-marker" ] && echo yes || echo no)
    GLAB_CALLED=$([ -f "$TMP/t7-glab-marker" ] && echo yes || echo no)
    if [ "$RC" -eq 0 ] && [ "$GH_CALLED" = "yes" ] && [ "$GLAB_CALLED" = "yes" ]; then
        pass "T7: install.sh -> both gh.sh and glab.sh always called"
    else
        fail "T7: rc=$RC gh=$GH_CALLED glab=$GLAB_CALLED"
    fi
else
    fail "T7: install.sh not found"
fi
case_end
