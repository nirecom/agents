#!/bin/bash
# Tests: hooks/enforce-system-ops.js
# Tags: system-ops, enforce, hook, bin, tests
# Tests for hooks/enforce-system-ops.js — system-ops PreToolUse guard.
#
# Blocks destructive/global system operations from the Bash tool unless
# SYSTEM_OPS_APPROVED=1 is inherited in the hook's environment.
#
# RED: this suite fails clean while hooks/enforce-system-ops.js is missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/enforce-system-ops.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

if [ ! -f "$HOOK" ]; then
    echo "FAIL: precondition missing — hooks/enforce-system-ops.js"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

run_hook_block_env() {
    local json="$1"
    OUT=$(unset SYSTEM_OPS_APPROVED; echo "$json" | run_with_timeout 15 node "$HOOK" 2>/tmp/.enforce_sysops_err.$$)
    RC=$?; ERR=$(cat /tmp/.enforce_sysops_err.$$ 2>/dev/null); rm -f /tmp/.enforce_sysops_err.$$
}

run_hook_bypass_env() {
    local json="$1"
    OUT=$(echo "$json" | SYSTEM_OPS_APPROVED=1 run_with_timeout 15 node "$HOOK" 2>/tmp/.enforce_sysops_err.$$)
    RC=$?; ERR=$(cat /tmp/.enforce_sysops_err.$$ 2>/dev/null); rm -f /tmp/.enforce_sysops_err.$$
}

expect_block() {
    local desc="$1" json="$2"
    run_hook_block_env "$json"
    if [ "$RC" -eq 2 ]; then
        pass "$desc"
    else
        fail "$desc — expected exit 2 (rc=$RC stderr=$ERR)"
    fi
}

expect_pass() {
    local desc="$1" json="$2"
    run_hook_block_env "$json"
    if [ "$RC" -eq 0 ]; then
        pass "$desc"
    else
        fail "$desc — expected exit 0 (rc=$RC stderr=$ERR)"
    fi
}

# ============================================================================
# Category A — Package install
# ============================================================================
expect_block "A1: winget install" '{"tool_name":"Bash","tool_input":{"command":"winget install --id jqlang.jq"}}'
expect_block "A2: winget uninstall" '{"tool_name":"Bash","tool_input":{"command":"winget uninstall jq"}}'
expect_block "A3: winget upgrade --all" '{"tool_name":"Bash","tool_input":{"command":"winget upgrade --all"}}'
expect_pass  "A4: winget search (query)" '{"tool_name":"Bash","tool_input":{"command":"winget search jq"}}'
expect_block "A5: sudo winget install" '{"tool_name":"Bash","tool_input":{"command":"sudo winget install jq"}}'
expect_block "A6: choco install" '{"tool_name":"Bash","tool_input":{"command":"choco install jq"}}'
expect_block "A7: scoop install" '{"tool_name":"Bash","tool_input":{"command":"scoop install jq"}}'
expect_block "A8: apt install" '{"tool_name":"Bash","tool_input":{"command":"apt install jq"}}'
expect_block "A9: sudo apt install" '{"tool_name":"Bash","tool_input":{"command":"sudo apt install jq"}}'
expect_block "A10: apt-get install -y" '{"tool_name":"Bash","tool_input":{"command":"apt-get install -y jq"}}'
expect_pass  "A11: apt list --installed (query)" '{"tool_name":"Bash","tool_input":{"command":"apt list --installed"}}'
expect_block "A12: brew install" '{"tool_name":"Bash","tool_input":{"command":"brew install jq"}}'
expect_block "A13: sudo brew uninstall" '{"tool_name":"Bash","tool_input":{"command":"sudo brew uninstall jq"}}'
expect_pass  "A14: brew info (query)" '{"tool_name":"Bash","tool_input":{"command":"brew info jq"}}'
expect_block "A15: npm install -g (post-flag)" '{"tool_name":"Bash","tool_input":{"command":"npm install -g typescript"}}'
expect_block "A16: npm install --global" '{"tool_name":"Bash","tool_input":{"command":"npm install --global typescript"}}'
expect_block "A17: npm i -g (i alias)" '{"tool_name":"Bash","tool_input":{"command":"npm i -g typescript"}}'
expect_block "A18: npm -g install (pre-flag)" '{"tool_name":"Bash","tool_input":{"command":"npm -g install typescript"}}'
expect_block "A19: npm -g i (pre-flag + alias)" '{"tool_name":"Bash","tool_input":{"command":"npm -g i typescript"}}'
expect_pass  "A20: npm install (per-repo)" '{"tool_name":"Bash","tool_input":{"command":"npm install typescript"}}'
expect_block "A21: pnpm add -g" '{"tool_name":"Bash","tool_input":{"command":"pnpm add -g typescript"}}'
expect_block "A22: pnpm -g add (pre-flag)" '{"tool_name":"Bash","tool_input":{"command":"pnpm -g add typescript"}}'
expect_pass  "A23: pnpm add (per-repo)" '{"tool_name":"Bash","tool_input":{"command":"pnpm add typescript"}}'
expect_block "A24: yarn global add" '{"tool_name":"Bash","tool_input":{"command":"yarn global add typescript"}}'
expect_pass  "A25: yarn add (per-repo)" '{"tool_name":"Bash","tool_input":{"command":"yarn add typescript"}}'
expect_block "A26: pip install (no --user)" '{"tool_name":"Bash","tool_input":{"command":"pip install requests"}}'
expect_pass  "A27: pip install --user (at end)" '{"tool_name":"Bash","tool_input":{"command":"pip install requests --user"}}'
expect_pass  "A28: pip install --user (at start)" '{"tool_name":"Bash","tool_input":{"command":"pip install --user requests"}}'
expect_block "A29: pip install --user-agent (not --user)" '{"tool_name":"Bash","tool_input":{"command":"pip install requests --user-agent=foo"}}'
expect_block "A30: pip install \"package --user\" (--user in quotes)" '{"tool_name":"Bash","tool_input":{"command":"pip install \"package --user\""}}'
expect_block "A31: pip3 install" '{"tool_name":"Bash","tool_input":{"command":"pip3 install requests"}}'
expect_block "A32: python -m pip install" '{"tool_name":"Bash","tool_input":{"command":"python -m pip install requests"}}'
expect_block "A33: py -m pip install (Windows launcher)" '{"tool_name":"Bash","tool_input":{"command":"py -m pip install requests"}}'
expect_pass  "A34: python3 -m pip install --user" '{"tool_name":"Bash","tool_input":{"command":"python3 -m pip install --user requests"}}'
expect_block "A35: pipx install" '{"tool_name":"Bash","tool_input":{"command":"pipx install black"}}'
expect_pass  "A36: pip list (query)" '{"tool_name":"Bash","tool_input":{"command":"pip list"}}'
expect_pass  "A37: uv pip install (project-local)" '{"tool_name":"Bash","tool_input":{"command":"uv pip install requests"}}'

# ============================================================================
# Category B — Power
# ============================================================================
expect_block "B1: Restart-Computer" '{"tool_name":"Bash","tool_input":{"command":"Restart-Computer"}}'
expect_block "B2: Restart-Computer -Force" '{"tool_name":"Bash","tool_input":{"command":"Restart-Computer -Force"}}'
expect_block "B3: Stop-Computer" '{"tool_name":"Bash","tool_input":{"command":"Stop-Computer"}}'
expect_block "B4: shutdown /r /t 0" '{"tool_name":"Bash","tool_input":{"command":"shutdown /r /t 0"}}'
expect_block "B5: shutdown -h now (POSIX)" '{"tool_name":"Bash","tool_input":{"command":"shutdown -h now"}}'
expect_block "B6: sudo reboot" '{"tool_name":"Bash","tool_input":{"command":"sudo reboot"}}'
expect_block "B7: halt" '{"tool_name":"Bash","tool_input":{"command":"halt"}}'
expect_block "B8: poweroff" '{"tool_name":"Bash","tool_input":{"command":"poweroff"}}'

# ============================================================================
# Category C — Service
# ============================================================================
expect_block "C1: Stop-Service" '{"tool_name":"Bash","tool_input":{"command":"Stop-Service Spooler"}}'
expect_block "C2: Set-Service -StartupType Disabled" '{"tool_name":"Bash","tool_input":{"command":"Set-Service Spooler -StartupType Disabled"}}'
expect_block "C3: Remove-Service" '{"tool_name":"Bash","tool_input":{"command":"Remove-Service Svc"}}'
expect_block "C4: sc.exe stop" '{"tool_name":"Bash","tool_input":{"command":"sc.exe stop Spooler"}}'
expect_block "C5: sc stop (.exe omitted)" '{"tool_name":"Bash","tool_input":{"command":"sc stop Spooler"}}'
expect_block "C6: sc.exe delete" '{"tool_name":"Bash","tool_input":{"command":"sc.exe delete Svc"}}'
expect_block "C7: sc.exe config start=disabled" '{"tool_name":"Bash","tool_input":{"command":"sc.exe config Svc start=disabled"}}'
expect_pass  "C8: sc query (query)" '{"tool_name":"Bash","tool_input":{"command":"sc query Spooler"}}'
expect_pass  "C9: Get-Service (query)" '{"tool_name":"Bash","tool_input":{"command":"Get-Service"}}'
expect_block "C10: systemctl stop" '{"tool_name":"Bash","tool_input":{"command":"systemctl stop nginx"}}'
expect_block "C11: systemctl disable" '{"tool_name":"Bash","tool_input":{"command":"systemctl disable nginx"}}'
expect_block "C12: systemctl mask" '{"tool_name":"Bash","tool_input":{"command":"systemctl mask nginx"}}'
expect_pass  "C13: systemctl status (query)" '{"tool_name":"Bash","tool_input":{"command":"systemctl status nginx"}}'
expect_pass  "C14: systemctl start (not blocked)" '{"tool_name":"Bash","tool_input":{"command":"systemctl start nginx"}}'
expect_pass  "C15: systemctl restart (not blocked)" '{"tool_name":"Bash","tool_input":{"command":"systemctl restart nginx"}}'
expect_pass  "C16: systemctl enable (not blocked)" '{"tool_name":"Bash","tool_input":{"command":"systemctl enable nginx"}}'
expect_block "C17: service nginx stop (POSIX)" '{"tool_name":"Bash","tool_input":{"command":"service nginx stop"}}'
expect_pass  "C18: service nginx status (query)" '{"tool_name":"Bash","tool_input":{"command":"service nginx status"}}'

# ============================================================================
# Category D — User/group
# ============================================================================
expect_block "D1: New-LocalUser" '{"tool_name":"Bash","tool_input":{"command":"New-LocalUser foo"}}'
expect_block "D2: Remove-LocalUser" '{"tool_name":"Bash","tool_input":{"command":"Remove-LocalUser foo"}}'
expect_block "D3: Add-LocalGroupMember" '{"tool_name":"Bash","tool_input":{"command":"Add-LocalGroupMember -Group Admins -Member foo"}}'
expect_block "D4: Remove-LocalGroupMember" '{"tool_name":"Bash","tool_input":{"command":"Remove-LocalGroupMember -Group Admins -Member foo"}}'
expect_block "D5: net user /add" '{"tool_name":"Bash","tool_input":{"command":"net user foo /add"}}'
expect_block "D6: net user /delete" '{"tool_name":"Bash","tool_input":{"command":"net user foo /delete"}}'
expect_block "D7: net localgroup /add" '{"tool_name":"Bash","tool_input":{"command":"net localgroup Admins foo /add"}}'
expect_pass  "D8: net user (query)" '{"tool_name":"Bash","tool_input":{"command":"net user"}}'
expect_pass  "D9: Get-LocalUser (query)" '{"tool_name":"Bash","tool_input":{"command":"Get-LocalUser"}}'
expect_block "D10: useradd" '{"tool_name":"Bash","tool_input":{"command":"useradd foo"}}'
expect_block "D11: userdel" '{"tool_name":"Bash","tool_input":{"command":"userdel foo"}}'
expect_block "D12: usermod -G" '{"tool_name":"Bash","tool_input":{"command":"usermod -G wheel foo"}}'
expect_block "D12b: usermod -aG (compound flag)" '{"tool_name":"Bash","tool_input":{"command":"usermod -aG sudo alice"}}'
expect_pass  "D13: usermod -c (no -G)" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"usermod -c 'Foo Bar' foo\"}}"
expect_block "D14: groupadd" '{"tool_name":"Bash","tool_input":{"command":"groupadd wheel"}}'
expect_block "D15: groupdel" '{"tool_name":"Bash","tool_input":{"command":"groupdel wheel"}}'
expect_pass  "D16: passwd (not blocked)" '{"tool_name":"Bash","tool_input":{"command":"passwd foo"}}'

# ============================================================================
# Category E — Registry/boot
# ============================================================================
expect_block "E1: reg.exe delete HKLM" '{"tool_name":"Bash","tool_input":{"command":"reg.exe delete HKLM\\Software\\Foo /f"}}'
expect_block "E2: reg delete HKCR" '{"tool_name":"Bash","tool_input":{"command":"reg delete HKCR\\Foo /f"}}'
expect_pass  "E3: reg delete HKCU (user scope)" '{"tool_name":"Bash","tool_input":{"command":"reg delete HKCU\\Software\\Foo /f"}}'
expect_pass  "E4: reg delete HKU (user scope)" '{"tool_name":"Bash","tool_input":{"command":"reg delete HKU\\Foo /f"}}'
expect_pass  "E5: reg query HKLM (query)" '{"tool_name":"Bash","tool_input":{"command":"reg query HKLM\\Software"}}'
expect_pass  "E6: reg add HKLM (not blocked)" '{"tool_name":"Bash","tool_input":{"command":"reg add HKLM\\Software\\Foo /v Bar /d 1"}}'
expect_pass  "E7: reg import (not blocked)" '{"tool_name":"Bash","tool_input":{"command":"reg import foo.reg"}}'
expect_block "E8: Remove-Item HKLM:" '{"tool_name":"Bash","tool_input":{"command":"Remove-Item -Path HKLM:\\Software\\Foo"}}'
expect_pass  "E9: Remove-Item HKCU: (user scope)" '{"tool_name":"Bash","tool_input":{"command":"Remove-Item -Path HKCU:\\Software\\Foo"}}'
expect_block "E10: Remove-ItemProperty HKLM:" '{"tool_name":"Bash","tool_input":{"command":"Remove-ItemProperty -Path HKLM:\\Software\\Foo -Name Bar"}}'
expect_block "E11: bcdedit /set" '{"tool_name":"Bash","tool_input":{"command":"bcdedit /set {default} bootstatuspolicy ignoreallfailures"}}'
expect_pass  "E12: bcdedit /enum (query)" '{"tool_name":"Bash","tool_input":{"command":"bcdedit /enum"}}'
expect_block "E13: Set-ExecutionPolicy" '{"tool_name":"Bash","tool_input":{"command":"Set-ExecutionPolicy RemoteSigned"}}'
expect_pass  "E14: Get-ExecutionPolicy (query)" '{"tool_name":"Bash","tool_input":{"command":"Get-ExecutionPolicy"}}'
expect_block "E15: Disable-WindowsOptionalFeature" '{"tool_name":"Bash","tool_input":{"command":"Disable-WindowsOptionalFeature -Online -FeatureName Foo"}}'
expect_block "E16: Enable-WindowsOptionalFeature" '{"tool_name":"Bash","tool_input":{"command":"Enable-WindowsOptionalFeature -Online -FeatureName Foo"}}'
expect_block "E17: Add-WindowsCapability" '{"tool_name":"Bash","tool_input":{"command":"Add-WindowsCapability -Online -Name Foo"}}'
expect_block "E18: Remove-WindowsCapability" '{"tool_name":"Bash","tool_input":{"command":"Remove-WindowsCapability -Online -Name Foo"}}'
expect_pass  "E19: Get-WindowsOptionalFeature (query)" '{"tool_name":"Bash","tool_input":{"command":"Get-WindowsOptionalFeature -Online"}}'

# ============================================================================
# Category F — Disk/FS
# ============================================================================
expect_block "F1: format C:" '{"tool_name":"Bash","tool_input":{"command":"format C:"}}'
expect_block "F2: format.com D:" '{"tool_name":"Bash","tool_input":{"command":"format.com D: /fs:ntfs"}}'
expect_block "F3: diskpart" '{"tool_name":"Bash","tool_input":{"command":"diskpart"}}'
expect_block "F4: mkfs.ext4" '{"tool_name":"Bash","tool_input":{"command":"mkfs.ext4 /dev/sdb1"}}'
expect_block "F5: dd of=/dev/sdb" '{"tool_name":"Bash","tool_input":{"command":"dd if=/dev/zero of=/dev/sdb"}}'
expect_block "F6: dd of=/dev/ (img source)" '{"tool_name":"Bash","tool_input":{"command":"dd if=disk.img of=/dev/sdb"}}'
expect_block "F7: dd if=/dev/ (img target)" '{"tool_name":"Bash","tool_input":{"command":"dd if=/dev/sda of=disk.img"}}'
expect_pass  "F8: dd img to img (no /dev/)" '{"tool_name":"Bash","tool_input":{"command":"dd if=disk.img of=disk2.img"}}'
expect_block "F9: wsl --unregister" '{"tool_name":"Bash","tool_input":{"command":"wsl --unregister Ubuntu"}}'
expect_pass  "F10: wsl --shutdown (not blocked)" '{"tool_name":"Bash","tool_input":{"command":"wsl --shutdown"}}'
expect_pass  "F11: wsl --list (query)" '{"tool_name":"Bash","tool_input":{"command":"wsl --list"}}'
expect_pass  "F12: parted (not blocked)" '{"tool_name":"Bash","tool_input":{"command":"parted /dev/sda"}}'
expect_pass  "F13: fdisk (not blocked)" '{"tool_name":"Bash","tool_input":{"command":"fdisk /dev/sda"}}'

# ============================================================================
# Non-target / regression (quoted string false-positives)
# ============================================================================
expect_pass  "NON1: ls" '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
expect_pass  "NON2: echo \"winget install jq\" (quoted)" '{"tool_name":"Bash","tool_input":{"command":"echo \"winget install jq\""}}'
expect_pass  "NON3: echo single-quoted apt install" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo 'apt install jq'\"}}"
expect_pass  "NON4: printf single-quoted pip install" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"printf 'pip install requests'\"}}"
expect_pass  "NON5: grep -r Restart-Computer" '{"tool_name":"Bash","tool_input":{"command":"grep -r \"Restart-Computer\" ."}}'
expect_pass  "NON6: git log --grep shutdown" '{"tool_name":"Bash","tool_input":{"command":"git log --grep \"shutdown\""}}'
expect_pass  "NON7: Format-Table | Out-Null" '{"tool_name":"Bash","tool_input":{"command":"Format-Table | Out-Null"}}'
expect_block "NON8: bash -c 'winget install jq' (inner body tested)" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash -c 'winget install jq'\"}}"

# ============================================================================
# Bypass / spoof
# ============================================================================
run_hook_bypass_env '{"tool_name":"Bash","tool_input":{"command":"winget install jq"}}'
if [ "$RC" -eq 0 ]; then
    pass "BP1: SYSTEM_OPS_APPROVED=1 inherited bypasses winget install"
else
    fail "BP1: rc=$RC stderr=$ERR"
fi

run_hook_bypass_env '{"tool_name":"Bash","tool_input":{"command":"apt install jq"}}'
if [ "$RC" -eq 0 ]; then
    pass "BP2: SYSTEM_OPS_APPROVED=1 inherited bypasses apt install"
else
    fail "BP2: rc=$RC stderr=$ERR"
fi

expect_block "BP3: inline 'export SYSTEM_OPS_APPROVED=1 && winget install' still blocked" \
    '{"tool_name":"Bash","tool_input":{"command":"export SYSTEM_OPS_APPROVED=1 && winget install jq"}}'

expect_block "BP4: inline 'SYSTEM_OPS_APPROVED=1 winget install' still blocked" \
    '{"tool_name":"Bash","tool_input":{"command":"SYSTEM_OPS_APPROVED=1 winget install jq"}}'

# ============================================================================
# Tool name coverage — runInTerminal and runCommands
# ============================================================================
run_hook_block_env '{"tool_name":"runInTerminal","tool_input":{"command":"winget install jq"}}'
if [ "$RC" -eq 2 ]; then
    pass "TOOL1: runInTerminal winget install blocked"
else
    fail "TOOL1: runInTerminal — expected exit 2 (rc=$RC stderr=$ERR)"
fi

run_hook_block_env '{"tool_name":"runCommands","tool_input":{"commands":["winget install jq"]}}'
if [ "$RC" -eq 2 ]; then
    pass "TOOL2: runCommands winget install blocked"
else
    fail "TOOL2: runCommands — expected exit 2 (rc=$RC stderr=$ERR)"
fi

run_hook_block_env '{"tool_name":"runCommands","tool_input":{"commands":["ls","winget install jq"]}}'
if [ "$RC" -eq 2 ]; then
    pass "TOOL3: runCommands multi-cmd with winget blocked"
else
    fail "TOOL3: runCommands multi-cmd — expected exit 2 (rc=$RC stderr=$ERR)"
fi

run_hook_block_env '{"tool_name":"runCommands","tool_input":{"commands":["ls","pwd"]}}'
if [ "$RC" -eq 0 ]; then
    pass "TOOL4: runCommands safe commands pass"
else
    fail "TOOL4: runCommands safe — expected exit 0 (rc=$RC stderr=$ERR)"
fi

run_hook_block_env '{"tool_name":"OtherTool","tool_input":{"command":"winget install jq"}}'
if [ "$RC" -eq 0 ]; then
    pass "TOOL5: non-Bash tool_name passes (hook scoped to Bash/runInTerminal/runCommands)"
else
    fail "TOOL5: OtherTool — expected exit 0 (rc=$RC stderr=$ERR)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
