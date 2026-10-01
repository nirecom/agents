# Sourced by tests/install/feature-2284-install-cc-claude-codex-cli.sh inside a case span.
# Group E (bash): exit-code contract — guard timeout must not abort the caller.

cat > "$TMP_DIR/fake-guard.sh" << 'FAKE_GUARD_EOF'
#!/bin/bash
exit 1
FAKE_GUARD_EOF
chmod +x "$TMP_DIR/fake-guard.sh"

cat > "$TMP_DIR/caller.sh" << 'CALLER_EOF'
#!/bin/bash
set -euo pipefail
if ! bash "$1"; then
    echo "skipped"
    exit 0
fi
echo "updated"
CALLER_EOF

_e1_rc=0
_e1_out="$(bash "$TMP_DIR/caller.sh" "$TMP_DIR/fake-guard.sh" 2>&1)" || _e1_rc=$?
if [ "$_e1_rc" = "0" ] && [ "$_e1_out" = "skipped" ]; then
    pass "E1: under set -e a guard timeout skips the update and the caller exits 0"
else
    fail "E1: guard timeout broke the caller contract (rc=$_e1_rc, out=$_e1_out)"
fi
