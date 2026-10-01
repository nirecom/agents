# Sourced by tests/install/feature-1743-wf-init-symlink-static.sh inside a case span.

# --- B3: Windows installer calls the guard before assemble-settings.js ---
if _guard_precedes_assemble "$PS_FILE"; then
    pass "B3: dotfileslink.ps1 calls wait-cc-exit.ps1 before assemble-settings.js"
else
    fail "B3: dotfileslink.ps1 has no wait-cc-exit.ps1 call preceding assemble-settings.js"
fi

# --- B4: Windows installer skips the write when the guard times out ---
if _guard_skips_assemble "$PS_FILE"; then
    pass "B4: dotfileslink.ps1 skips assemble-settings.js on a wait-cc-exit timeout"
else
    fail "B4: dotfileslink.ps1 has no skip path between wait-cc-exit.ps1 and assemble-settings.js"
fi

# --- B4b: PS guard is scoped after DOTFILESLINK_LINKS_ONLY (not at script top) ---
if _guard_scope_ok_dotfiles "$PS_FILE"; then
    pass "B4b: dotfileslink.ps1 guard is placed after the DOTFILESLINK_LINKS_ONLY exit"
else
    fail "B4b: dotfileslink.ps1 guard precedes DOTFILESLINK_LINKS_ONLY exit — would block links-only mode"
fi
