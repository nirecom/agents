# Sourced by tests/install/feature-1743-wf-init-symlink-static.sh inside a case span.

# --- L4: CPR-ORTH symmetry — both platforms must carry the entry ---
_win_found=0; _sh_found=0
has_win_entry "$PS_FILE" && _win_found=1
has_sh_entry "$SH_FILE" && _sh_found=1
if [ "$_win_found" = "1" ] && [ "$_sh_found" = "1" ]; then
    pass "L4: both installers declare the wf-init link (win=$_win_found, posix=$_sh_found)"
else
    fail "L4: one-sided wf-init link — win=$_win_found, posix=$_sh_found (both must be 1)"
fi

# --- L4b: mutation probe — a one-sided removal must be detected, not silently green ---
_mut_win="$TMP_DIR/dotfileslink-no-win-entry.ps1"
grep -vE 'Source[[:space:]]*=[[:space:]]*"skills[\\/]workflow-init"' "$PS_FILE" > "$_mut_win"
_mut_sh="$TMP_DIR/dotfileslink-no-sh-entry.sh"
grep -vE '_link_one[[:space:]]+.*skills/workflow-init.*skills/wf-init' "$SH_FILE" > "$_mut_sh"

_mut_win_found=0; _mut_sh_found=0
has_win_entry "$_mut_win" && _mut_win_found=1
has_sh_entry "$_mut_sh" && _mut_sh_found=1
if [ "$_mut_win_found" = "0" ] && [ "$_mut_sh_found" = "0" ]; then
    pass "L4b: detectors report absent on mutated copies (win=$_mut_win_found, posix=$_mut_sh_found)"
else
    fail "L4b: detectors still report present after removal — false-green risk (win=$_mut_win_found, posix=$_mut_sh_found)"
fi
