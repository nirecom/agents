#!/usr/bin/env bash
# Tests: install.sh, install/linux/glab.sh, install/win/glab.ps1
# Tags: install, glab-install, gitlab, auth-idempotent, non-interactive, scope:issue-specific, TL2, pwsh-required
#
# Tests glab sub-script added in issue #2308, updated for GITLAB flag + non-interactive auth.
# Verifies glab.sh flag gate, install/upgrade, auth behavior, DNS guard, and that install.sh calls glab.sh.
# TL3 gaps: real pkg mgrs / glab auth login (TTY) / winget+keyring; DNS+3s faked (fail T8/P5, success T5/TA/PA, hang T10/P7; real-net + PS [System.Net.Dns] via P2 untested).
#   (C1) PS Wait-Job -Timeout 3 on a truly hanging Job — Windows-native only, .NET DNS not TL2-mockable.
#   (C2) macOS 'timeout 3 host' branch — Darwin-native only (TA-MAC fakes uname=Darwin, real host untested).
#   (C3) PS Job-based DNS (not getent/host) — PC "DNS skipped no-HOSTNAME" / PB "DNS run, partial creds" not TL2-markable.
# Closest-to-action mitigation: bin/check-verification-gate.sh category: installer at WORKFLOW_USER_VERIFIED.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AGENTS_DIR/tests/lib/harness.sh"

INSTALL_SH="$AGENTS_DIR/install.sh"
GLAB_SH="$AGENTS_DIR/install/linux/glab.sh"

# ---------------------------------------------------------------------------
# Detect Windows bash: install.sh / glab.sh (Sections 1–4) skip there;
# install/win/glab.ps1 (Section 5) is tested via pwsh regardless of platform.
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
_SUBDIR="$AGENTS_DIR/tests/feature-2308-install-glab"
if [ "$_on_windows_bash" = "0" ]; then
    source "$_SUBDIR/linux-auth.sh"
    source "$_SUBDIR/linux-dns.sh"
    source "$_SUBDIR/linux-install.sh"
fi

# ---------------------------------------------------------------------------
# Section 5: Windows/pwsh tests (install/win/glab.ps1)
# ---------------------------------------------------------------------------
source "$_SUBDIR/windows.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
