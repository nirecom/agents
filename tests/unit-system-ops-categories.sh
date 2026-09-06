#!/usr/bin/env bash
# tests/unit-system-ops-categories.sh
# Tests: hooks/lib/system-ops-categories.js
# Tags: unit, system-ops, classifier, table-driven, security, scope:common, pwsh-not-required
# Unit coverage of getBlockCategory() — the pure predicate extracted from
# hooks/enforce-system-ops.js (#2170), now also read by the scratchpad body scan.
# CPR-ORTH: each category-hit row is paired with a same-family near-miss row that
# must classify NONE, so over-blocking fails as loudly as under-blocking.
# TL3 gap: does not prove the two consumers CALL this lib (wiring: classifier
# section M, part4-scratchpad section D-6) nor real PreToolUse dispatch. Closest-to-
# action mitigation: WORKFLOW_USER_VERIFIED preflight, category hook-registration.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
topath() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}
MODULE="$(topath "$AGENTS_DIR/hooks/lib/system-ops-categories.js")"

command -v node >/dev/null 2>&1 || exit 77

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"; else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TABLE="$TMP/cases.txt"

# Table columns: name | command | want-category ("NONE" = classified as harmless).
cat >"$TABLE" <<'TABLE'
# ---- Category A: package install/uninstall (system-wide) ----
A-winget-install            | winget install jq                        | A (winget)
A-winget-list-miss          | winget list                              | NONE
A-choco-install             | choco install jq -y                      | A (choco)
A-scoop-install             | scoop install jq                         | A (scoop)
A-brew-install              | brew install jq                          | A (brew)
A-brew-list-miss            | brew list                                | NONE
A-apt-get-sudo-install      | sudo apt-get install curl                | A (apt)
A-apt-list-miss             | apt list --installed                     | NONE
A-yarn-global-add           | yarn global add serve                    | A (yarn global)
A-yarn-add-miss             | yarn add serve                           | NONE
A-npm-global-postflag       | npm install -g typescript                | A (npm -g)
A-npm-global-preflag        | npm -g install typescript                | A (npm -g)
A-npm-local-miss            | npm install lodash                       | NONE
A-pnpm-global               | pnpm add -g eslint                       | A (pnpm -g)
A-pnpm-local-miss           | pnpm add eslint                          | NONE
A-pip-install               | pip install requests                     | A (pip)
A-pip-user-flag-miss        | pip install --user requests              | NONE
A-uv-pip-miss               | uv pip install requests                  | NONE
# `python3 -m pip install` is blocked by the BARE-pip rule first (it contains
# " pip install"), so the label reads A (pip). Blocked either way; label pinned.
A-python-m-pip              | python3 -m pip install black             | A (pip)
A-python-m-pip-user-miss    | python3 -m pip install --user black      | NONE
A-pipx-install              | pipx install black                       | A (pipx)
A-pipx-run-miss             | pipx run black                           | NONE
# ---- Category B: power ----
B-shutdown-flag             | shutdown -h now                          | B (shutdown)
B-shutdown-help-miss        | shutdown --help                          | NONE
B-restart-computer          | Restart-Computer -Force                  | B (power)
B-reboot                    | reboot                                   | B (reboot/halt/poweroff)
B-rebooting-word-miss       | echo rebooting the service               | NONE
# ---- Category C: service stop/disable/mask ----
C-systemctl-stop            | systemctl stop nginx                     | C (systemctl)
C-systemctl-status-miss     | systemctl status nginx                   | NONE
C-stop-service-cmdlet       | Stop-Service Spooler                     | C (service cmdlet)
C-get-service-miss          | Get-Service Spooler                      | NONE
C-sc-exe-stop               | sc.exe stop Spooler                      | C (sc.exe)
C-sc-query-miss             | sc.exe query Spooler                     | NONE
C-service-stop              | service nginx stop                       | C (service stop)
C-service-status-miss       | service nginx status                     | NONE
# ---- Category D: user/group management ----
D-useradd                   | useradd bob                              | D (useradd/userdel/groupadd/groupdel)
D-new-localuser             | New-LocalUser bob                        | D (local user/group cmdlet)
D-get-localuser-miss        | Get-LocalUser bob                        | NONE
D-net-user-add              | net user bob Passw0rd /add               | D (net user/localgroup)
D-net-user-query-miss       | net user bob                             | NONE
D-usermod-group             | usermod -aG docker bob                   | D (usermod -G)
D-usermod-comment-miss      | usermod -c developer bob                 | NONE
# ---- Category E: registry / boot / system config ----
E-reg-delete-hklm           | reg delete HKLM\Software\Foo /f          | E (reg delete system hive)
E-reg-delete-hkcu-miss      | reg delete HKCU\Software\Foo /f          | NONE
E-reg-query-hklm-miss       | reg query HKLM\Software\Foo              | NONE
E-remove-item-hklm          | Remove-Item HKLM:\Software\Foo           | E (Remove-Item HKLM)
E-remove-item-hkcu-miss     | Remove-Item HKCU:\Software\Foo           | NONE
E-bcdedit-set               | bcdedit /set nx AlwaysOn                 | E (bcdedit)
E-bcdedit-enum-miss         | bcdedit /enum                            | NONE
E-set-executionpolicy       | Set-ExecutionPolicy Bypass               | E (Set-ExecutionPolicy)
E-get-executionpolicy-miss  | Get-ExecutionPolicy                      | NONE
E-windows-capability        | Add-WindowsCapability -Online -Name Foo  | E (Windows feature/capability)
# ---- Category F: disk / filesystem ----
F-format                    | format C:                                | F (format)
F-format-table-miss         | Get-Process %PIPE% Format-Table Name     | NONE
F-diskpart                  | diskpart                                 | F (diskpart)
F-mkfs                      | mkfs.ext4 /dev/sdb1                      | F (mkfs)
F-dd-dev                    | dd if=/dev/zero of=/dev/sdb bs=1M        | F (dd /dev/)
F-dd-regular-files-miss     | dd if=input.img of=output.img bs=1M      | NONE
F-wsl-unregister            | wsl --unregister Ubuntu                  | F (wsl --unregister)
F-wsl-list-miss             | wsl --list --verbose                     | NONE
# ---- Benign / edge inputs ----
X-empty-string              |                                          | NONE
X-plain-ls                  | ls -la                                   | NONE
X-git-status                | git status --short                       | NONE
X-node-script               | node bin/workflow/next-step --list       | NONE
TABLE

EXPECTED="$(grep -c -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$TABLE")"

# One node process classifies the whole table; bash keeps the assertion, so a
# driver that dies yields zero result lines (caught by the count assertion)
# instead of a silently green table.
RESULTS="$TMP/results.txt"
run_with_timeout 60 node -e '
"use strict";
const fs = require("fs");
const { getBlockCategory } = require(process.argv[1]);
const lines = fs.readFileSync(process.argv[2], "utf8").split(/\r?\n/);
for (const raw of lines) {
  const line = raw.trim();
  if (!line || line.startsWith("#")) continue;
  const parts = line.split("|").map((s) => s.trim());
  const cmd = (parts[1] || "").split("%PIPE%").join("|");
  const got = getBlockCategory(cmd);
  process.stdout.write(parts[0] + "|" + parts[2] + "|" + (got === null ? "NONE" : got) + "\n");
}
' "$MODULE" "$(topath "$TABLE")" >"$RESULTS" 2>"$TMP/err.txt"

GOT_LINES="$(grep -c . "$RESULTS" 2>/dev/null || printf '0')"
assert_eq "driver classified every table row" "$EXPECTED" "$GOT_LINES"
if [ "$GOT_LINES" = "0" ]; then
    echo "driver stderr: $(cat "$TMP/err.txt" 2>/dev/null)"
fi

while IFS='|' read -r name want got; do
    [ -n "$name" ] || continue
    assert_eq "$name" "$want" "$got"
done <"$RESULTS"

# Contract shape: the module exports the pure predicate both consumers import.
EXPORTS="$(run_with_timeout 20 node -e '
const m = require(process.argv[1]);
process.stdout.write(typeof m.getBlockCategory);
' "$MODULE" 2>/dev/null)"
assert_eq "getBlockCategory is exported as a function" "function" "$EXPORTS"

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
