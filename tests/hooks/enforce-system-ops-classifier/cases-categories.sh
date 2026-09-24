#!/usr/bin/env bash
# Part of tests/enforce-system-ops-classifier.sh (rules/coding/file-split.md).
# Section C - the category A-F classifier table and the category LABEL table.

# ===========================================================================
# Section C - categories A-F. One canonical BLOCK and one nearest-miss ALLOW
# per category. The ALLOW row is the load-bearing half: it is the boundary the
# category regex must not cross, and a regex widened to "any winget" or "any
# systemctl" would still pass the BLOCK row alone.
# ===========================================================================
run_C_categories() {
while IFS='|' read -r name want cmd; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    name="$(printf '%s' "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    want="$(printf '%s' "$want" | tr -d '[:space:]')"
    cmd="$(printf '%s' "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    assert_eq "C $name" "$want" "$(run_cmd "$cmd")"
done <<'TABLE'
A-winget-install-blocks        | BLOCK | winget install --id jqlang.jq
A-winget-search-allows         | ALLOW | winget search jq
A-apt-get-install-blocks       | BLOCK | sudo apt-get install -y jq
A-apt-list-allows              | ALLOW | apt list --installed
A-npm-global-postflag-blocks   | BLOCK | npm install typescript -g
A-npm-local-allows             | ALLOW | npm install typescript
A-pip-install-blocks           | BLOCK | pip install requests
A-pip-install-user-allows      | ALLOW | pip install --user requests
A-pip-user-agent-blocks        | BLOCK | pip install requests --user-agent=x
A-uv-pip-install-allows        | ALLOW | uv pip install requests
A-pipx-install-blocks          | BLOCK | pipx install black
B-shutdown-posix-blocks        | BLOCK | shutdown -h now
B-restart-computer-blocks      | BLOCK | Restart-Computer -Force
B-reboot-blocks                | BLOCK | sudo reboot
B-shutdown-abort-allows        | ALLOW | shutdown /a
C-systemctl-stop-blocks        | BLOCK | systemctl stop nginx
C-systemctl-restart-allows     | ALLOW | systemctl restart nginx
C-sc-stop-blocks               | BLOCK | sc.exe stop Spooler
C-sc-query-allows              | ALLOW | sc query Spooler
C-stop-service-blocks          | BLOCK | Stop-Service Spooler
C-get-service-allows           | ALLOW | Get-Service Spooler
D-useradd-blocks               | BLOCK | sudo useradd bob
D-usermod-aG-blocks            | BLOCK | usermod -aG sudo bob
D-usermod-comment-allows       | ALLOW | usermod -c Foo bob
D-net-user-add-blocks          | BLOCK | net user bob /add
D-net-user-query-allows        | ALLOW | net user
E-reg-delete-HKLM-blocks       | BLOCK | reg delete HKLM\Software\Foo /f
E-reg-delete-longname-blocks   | BLOCK | reg delete HKEY_LOCAL_MACHINE\Foo /f
E-reg-delete-HKCU-allows       | ALLOW | reg delete HKCU\Software\Foo /f
E-reg-query-HKLM-allows        | ALLOW | reg query HKLM\Software
E-bcdedit-set-blocks           | BLOCK | bcdedit /set nx AlwaysOn
E-bcdedit-enum-allows          | ALLOW | bcdedit /enum
F-mkfs-blocks                  | BLOCK | mkfs.ext4 /dev/sdb1
F-dd-to-dev-blocks             | BLOCK | dd if=/dev/zero of=/dev/sdb
F-dd-img-to-img-allows         | ALLOW | dd if=a.img of=b.img
F-format-blocks                | BLOCK | format C:
F-format-table-allows          | ALLOW | Format-Table %PIPE% Out-Null
F-format-hyphen-word-allows    | ALLOW | format-json foo.json
F-git-format-patch-allows      | ALLOW | git format-patch -1
F-wsl-unregister-blocks        | BLOCK | wsl --unregister Ubuntu
F-wsl-shutdown-allows          | ALLOW | wsl --shutdown
TABLE
}

# The category LABEL is part of the contract (it names which rule fired and is
# what a reader of the block message acts on). Asserting only "blocked" would
# let any rule stand in for any other.
run_C_labels() {
while IFS='|' read -r name want cmd; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    name="$(printf '%s' "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    want="$(printf '%s' "$want" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    cmd="$(printf '%s' "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    assert_eq "L $name" "$want" "$(category_of "$cmd")"
done <<'TABLE'
label-winget    | A (winget)      | winget install jq
label-pip       | A (pip)         | pip install requests
label-shutdown  | B (shutdown)    | shutdown -h now
label-systemctl | C (systemctl)   | systemctl stop nginx
label-useradd   | D (useradd/userdel/groupadd/groupdel) | useradd bob
label-bcdedit   | E (bcdedit)     | bcdedit /set nx AlwaysOn
label-mkfs      | F (mkfs)        | mkfs.ext4 /dev/sdb1
label-clean     | NONE            | ls -la
TABLE
}
