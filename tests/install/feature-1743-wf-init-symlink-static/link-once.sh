# Sourced by tests/install/feature-1743-wf-init-symlink-static.sh inside a case span.

# --- L6: idempotency — the entry is declared exactly once per installer ---
# Re-run safety itself lives in the installers' already-linked short-circuits
# (ps1 loop: "Already linked" + continue; sh _link_one: readlink comparison + return 0),
# which are covered by tests/feature-697-dotfileslink-link-one.*. What is specific to this
# entry — and what those tests cannot see — is that it was added once and not duplicated:
# a duplicate declaration would make the second pass relink an already-correct symlink.
_win_count="$(grep -cE 'Source[[:space:]]*=[[:space:]]*"skills[\\/]workflow-init"' "$PS_FILE")"
_sh_count="$(grep -cE '_link_one[[:space:]]+.*skills/workflow-init.*skills/wf-init' "$SH_FILE")"
if [ "$_win_count" = "1" ] && [ "$_sh_count" = "1" ]; then
    pass "L6: wf-init link declared exactly once per installer (win=$_win_count, posix=$_sh_count)"
else
    fail "L6: duplicate/missing wf-init declaration (win=$_win_count, posix=$_sh_count; expected 1 each)"
fi
