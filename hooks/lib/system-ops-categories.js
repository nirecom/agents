// Pure category detection for system-wide irreversible operations.
// Categories: A (pkg install), B (power), C (svc stop/disable/mask),
//             D (user/group), E (reg/boot), F (disk/FS).
// Consumers: hooks/enforce-system-ops.js (outer command text),
//            hooks/preuse-auto-approve/scratchpad-script.js (script body lines).
"use strict";

// hasUserFlag: exact token match to avoid --user-agent passing as --user
function hasUserFlag(s) {
  return s.split(/\s+/).some((t) => t === "--user");
}

// isSystemHive: only HKLM and HKCR require approval; user-scoped hives pass
function isSystemHive(target) {
  return /^(?:HKLM|HKCR|HKEY_LOCAL_MACHINE|HKEY_CLASSES_ROOT)[\\:]/i.test(target);
}

function getBlockCategory(cmd) {
  // ---- Category A: Package install/uninstall (system-wide) ----
  if (/(?:^|[\s;|&])(?:sudo\s+)?winget\s+(?:install|uninstall|upgrade)\b/.test(cmd))
    return "A (winget)";
  if (/(?:^|[\s;|&])(?:sudo\s+)?choco\s+(?:install|uninstall|upgrade)\b/.test(cmd))
    return "A (choco)";
  if (/(?:^|[\s;|&])(?:sudo\s+)?scoop\s+(?:install|uninstall|update)\b/.test(cmd))
    return "A (scoop)";
  if (/(?:^|[\s;|&])(?:sudo\s+)?brew\s+(?:install|uninstall|upgrade|reinstall|remove|tap|untap)\b/.test(cmd))
    return "A (brew)";
  if (/(?:^|[\s;|&])(?:sudo\s+)?apt(?:-get)?\s+(?:install|remove|purge|autoremove|reinstall|full-upgrade|dist-upgrade|upgrade)\b/.test(cmd))
    return "A (apt)";
  if (/(?:^|[\s;|&])(?:sudo\s+)?yarn\s+global\s+(?:add|remove|upgrade)\b/.test(cmd))
    return "A (yarn global)";
  // npm: pre-flag (-g before verb) OR post-flag (-g after verb)
  if (/(?:^|[\s;|&])(?:sudo\s+)?npm\s+(?:-g|--global)\s+(?:install|i|uninstall|update)\b/.test(cmd))
    return "A (npm -g)";
  if (/(?:^|[\s;|&])(?:sudo\s+)?npm\s+(?:install|i|uninstall|update)\b[^|;&]*\s(?:-g|--global)\b/.test(cmd))
    return "A (npm -g)";
  // pnpm: pre-flag OR post-flag
  if (/(?:^|[\s;|&])(?:sudo\s+)?pnpm\s+(?:-g|--global)\s+(?:add|install|remove|uninstall|update|upgrade)\b/.test(cmd))
    return "A (pnpm -g)";
  if (/(?:^|[\s;|&])(?:sudo\s+)?pnpm\s+(?:add|install|remove|uninstall|update|upgrade)\b[^|;&]*\s(?:-g|--global)\b/.test(cmd))
    return "A (pnpm -g)";
  // pip: two-stage — block unless --user token present (exact match).
  // `uv pip install` is project-local (uv manages the venv), not system-wide.
  if (
    /(?:^|[\s;|&])(?:sudo\s+)?pip3?\s+(?:install|uninstall)\b/.test(cmd) &&
    !hasUserFlag(cmd) &&
    !/(?:^|[\s;|&])uv\s+pip3?\s+(?:install|uninstall)\b/.test(cmd)
  )
    return "A (pip)";
  if (
    /(?:^|[\s;|&])(?:sudo\s+)?(?:python3?|py)\s+-m\s+pip\s+(?:install|uninstall)\b/.test(cmd) &&
    !hasUserFlag(cmd)
  )
    return "A (python -m pip)";
  if (/(?:^|[\s;|&])(?:sudo\s+)?pipx\s+(?:install|uninstall|upgrade|inject|reinstall)\b/.test(cmd))
    return "A (pipx)";

  // ---- Category B: Power ----
  if (/(?:^|[\s;|&])(?:sudo\s+)?(?:Restart-Computer|Stop-Computer)\b/i.test(cmd))
    return "B (power)";
  if (/(?:^|[\s;|&])(?:sudo\s+)?shutdown(?:\.exe)?\s+[/-][rshHP]\b/i.test(cmd))
    return "B (shutdown)";
  if (/(?:^|[\s;|&])(?:sudo\s+)?(?:reboot|halt|poweroff)\b/.test(cmd))
    return "B (reboot/halt/poweroff)";

  // ---- Category C: Service control — stop/disable/mask only (per intent.md) ----
  if (/(?:^|[\s;|&])(?:Stop-Service|Set-Service|Remove-Service)\b/i.test(cmd))
    return "C (service cmdlet)";
  if (/(?:^|[\s;|&])sc(?:\.exe)?\s+(?:stop|delete|config)\b/i.test(cmd))
    return "C (sc.exe)";
  if (/(?:^|[\s;|&])(?:sudo\s+)?systemctl\s+(?:stop|disable|mask)\b/.test(cmd))
    return "C (systemctl)";
  if (/(?:^|[\s;|&])(?:sudo\s+)?service\s+\S+\s+stop\b/.test(cmd))
    return "C (service stop)";

  // ---- Category D: User/group management ----
  if (/(?:^|[\s;|&])(?:New-LocalUser|Remove-LocalUser|Add-LocalGroupMember|Remove-LocalGroupMember)\b/i.test(cmd))
    return "D (local user/group cmdlet)";
  if (/(?:^|[\s;|&])net\s+(?:user|localgroup)\s+\S+(?:\s+\S+)?\s+\/(?:add|delete)\b/i.test(cmd))
    return "D (net user/localgroup)";
  if (/(?:^|[\s;|&])(?:sudo\s+)?(?:useradd|userdel|groupadd|groupdel)\b/.test(cmd))
    return "D (useradd/userdel/groupadd/groupdel)";
  // usermod: only block when -G appears (standalone or compound flag like -aG)
  if (
    /(?:^|[\s;|&])(?:sudo\s+)?usermod\b/.test(cmd) &&
    /\s-[a-zA-Z]*G\b/.test(cmd)
  )
    return "D (usermod -G)";

  // ---- Category E: Registry/boot/system config ----
  {
    const m = cmd.match(/(?:^|[\s;|&])reg(?:\.exe)?\s+delete\s+(\S+)/i);
    if (m && isSystemHive(m[1])) return "E (reg delete system hive)";
  }
  if (/(?:^|[\s;|&])(?:Remove-Item|Remove-ItemProperty)\b[^|;&]*\bHKLM:/i.test(cmd))
    return "E (Remove-Item HKLM)";
  if (/(?:^|[\s;|&])bcdedit(?:\.exe)?\s+\/(?:set|delete|create|copy|export|import|default|displayorder|timeout|bootsequence|deletevalue)\b/i.test(cmd))
    return "E (bcdedit)";
  if (/(?:^|[\s;|&])Set-ExecutionPolicy\b/i.test(cmd))
    return "E (Set-ExecutionPolicy)";
  if (/(?:^|[\s;|&])(?:Disable-WindowsOptionalFeature|Enable-WindowsOptionalFeature|Add-WindowsCapability|Remove-WindowsCapability)\b/i.test(cmd))
    return "E (Windows feature/capability)";

  // ---- Category F: Disk / filesystem ----
  // format: lookahead ensures not `Format-Table` (hyphen after `format` fails (?=\s|$))
  if (/(?:^|[\s;|&])format(?:\.com|\.exe)?(?=\s|$)/i.test(cmd))
    return "F (format)";
  if (/(?:^|[\s;|&])diskpart(?:\.exe)?\b/i.test(cmd))
    return "F (diskpart)";
  if (/(?:^|[\s;|&])mkfs(?:\.[a-z0-9]+)?\s/.test(cmd))
    return "F (mkfs)";
  if (/(?:^|[\s;|&])dd\s+[^|;&]*\b(?:if|of)=\/dev\//.test(cmd))
    return "F (dd /dev/)";
  if (/(?:^|[\s;|&])wsl(?:\.exe)?\s+--unregister\b/i.test(cmd))
    return "F (wsl --unregister)";

  return null;
}

module.exports = { getBlockCategory };
