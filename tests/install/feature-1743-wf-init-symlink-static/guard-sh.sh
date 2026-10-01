# Sourced by tests/install/feature-1743-wf-init-symlink-static.sh inside a case span.

# --- B1: POSIX installer calls the guard before assemble-settings.js ---
if _guard_precedes_assemble "$SH_FILE"; then
    pass "B1: dotfileslink.sh calls wait-cc-exit.sh before node assemble-settings.js"
else
    fail "B1: dotfileslink.sh has no wait-cc-exit.sh call preceding assemble-settings.js"
fi

# --- B2: POSIX installer skips the write when the guard times out ---
if _guard_skips_assemble "$SH_FILE"; then
    pass "B2: dotfileslink.sh skips assemble-settings.js on a wait-cc-exit timeout"
else
    fail "B2: dotfileslink.sh has no skip path between wait-cc-exit.sh and assemble-settings.js"
fi

# --- B2b: POSIX guard is scoped after DOTFILESLINK_LINKS_ONLY (not at script top) ---
if _guard_scope_ok_dotfiles "$SH_FILE"; then
    pass "B2b: dotfileslink.sh guard is placed after the DOTFILESLINK_LINKS_ONLY exit"
else
    fail "B2b: dotfileslink.sh guard precedes DOTFILESLINK_LINKS_ONLY exit — would block links-only mode"
fi
