#!/usr/bin/env bash
# Tests: install.sh, install/linux/glab.sh
# Tags: install, glab-install, gitlab, auth-idempotent, non-interactive, scope:issue-specific, TL2, pwsh-required
#
# Tests glab sub-script added in issue #2308, updated for GITLAB flag + non-interactive auth.
# Verifies glab.sh flag gate, install/upgrade, auth behavior, TCP reachability guard, and that install.sh calls glab.sh.
# TL3 gaps: real pkg mgrs / glab auth login (TTY) / winget+keyring. Probe faked: fail T8, success T5/T6/TA; real: hang T10/P9 (TEST-NET), loopback T11/P2/P3/PA/P8.
#   (C2) macOS real /dev/tcp + gtimeout / bg+kill paths — Darwin-native only (TA-MAC fakes uname=Darwin: OS independence only).
#   Also untested: a real GitLab host on 443, and a bash built without /dev/tcp.
# Closest-to-action mitigation: bin/check-verification-gate.sh category: installer at WORKFLOW_USER_VERIFIED.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/home-userprofile-pin.sh"

INSTALL_SH="$SCRIPT_CHECKOUT_ROOT/install.sh"
GLAB_SH="$SCRIPT_CHECKOUT_ROOT/install/linux/glab.sh"

# ---------------------------------------------------------------------------
# Detect Windows bash: install.sh / glab.sh (Sections 1–4) skip there;
# install/win/glab.ps1 is tested by the sibling .Tests.ps1 (Pester).
# ---------------------------------------------------------------------------
_uname_s="$(uname -s 2>/dev/null || true)"
_on_windows_bash=0
if [[ "$_uname_s" == MINGW* || "$_uname_s" == MSYS* || "$_uname_s" == CYGWIN* ]]; then
    _on_windows_bash=1
fi
unset _uname_s

# ---------------------------------------------------------------------------
# Windows-compatible tmpdir
# ---------------------------------------------------------------------------
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || true)
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
    TMP=$(mktemp -d "${_BASH_WIN_TMPDIR}/install2308.XXXXXXXX")
else
    TMP=$(mktemp -d)
fi
trap 'rm -rf "$TMP"' EXIT

GLAB_SH_OK=0
[ -f "$GLAB_SH" ] && GLAB_SH_OK=1

# ---------------------------------------------------------------------------
# Sections 1–4: Linux/macOS tests (install.sh / install/linux/glab.sh)
# ---------------------------------------------------------------------------
_SUBDIR="$SCRIPT_CHECKOUT_ROOT/tests/install/feature-2308-install-glab"
source "$_SUBDIR/linux-lib.sh"

case_begin "glab-sh-flag-gate-install-and-auth" "install/linux/glab.sh"
if [ "$_on_windows_bash" = "0" ]; then
    source "$_SUBDIR/linux-auth.sh"
fi
case_end

case_begin "glab-sh-tcp-reachability-guard" "install/linux/glab.sh"
if [ "$_on_windows_bash" = "0" ]; then
    source "$_SUBDIR/linux-dns.sh"
fi
case_end

case_begin "install-sh-always-calls-glab-sh" "install.sh"
if [ "$_on_windows_bash" = "0" ]; then
    source "$_SUBDIR/linux-install.sh"
fi
case_end

# install/win/glab.ps1 cases (P1-P9, PA-PC): tests/install/feature-2308-install-glab.Tests.ps1.

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
