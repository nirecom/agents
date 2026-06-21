# Sourced from dotfiles' profile.ps1 (sibling-detected) or directly from $PROFILE.
# Idempotent — safe to source twice.
$AgentsRoot = $PSScriptRoot
$env:AGENTS_CONFIG_DIR = $AgentsRoot
$env:AGENTS_DIR        = $AgentsRoot

$_agentSymlinks = @("$HOME\.claude\CLAUDE.md", "$HOME\.claude\skills", "$HOME\.claude\rules", "$HOME\.claude\agents")
$_agentBroken = $_agentSymlinks | Where-Object {
    $_path = $_
    $_item = Get-Item -LiteralPath $_path -Force -ErrorAction SilentlyContinue
    if (-not $_item) {
        $true
    } elseif (-not ($_item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        $true
    } else {
        $_target = $_item.Target
        if ($_target -is [array]) { $_target = $_target | Select-Object -First 1 }
        if ([string]::IsNullOrEmpty($_target)) {
            $true
        } else {
            $_resolved = if ([System.IO.Path]::IsPathRooted($_target)) {
                $_target
            } else {
                Join-Path (Split-Path -Parent $_path) $_target
            }
            -not (Test-Path -LiteralPath $_resolved -ErrorAction SilentlyContinue)
        }
    }
}
if ($_agentBroken) {
    Write-Host "Repairing $($_agentBroken.Count) agents symlink(s)..." -ForegroundColor Yellow
    & "$AgentsRoot\install\win\dotfileslink.ps1"
}
Remove-Variable _agentSymlinks, _agentBroken, _path, _item, _target, _resolved -ErrorAction SilentlyContinue

# Auto-pull Claude Code session sync repo (~/.claude/projects/) on startup.
$SessionDir = "$HOME\.claude\projects"
if ((Get-Command git -ErrorAction SilentlyContinue) -and (Test-Path "$SessionDir\.git")) {
    Write-Host "git fetch Claude session sync ..."
    $_fetchSs = Start-Process -FilePath git -ArgumentList "-C $SessionDir fetch" -NoNewWindow -PassThru
    if (-not $_fetchSs.WaitForExit(3000)) { $_fetchSs.Kill() }
    elseif ($_fetchSs.ExitCode -eq 0) { git -C $SessionDir merge --ff-only --no-summary FETCH_HEAD 2>$null }
    Remove-Variable _fetchSs -ErrorAction SilentlyContinue
}

# Launch VS Code with session sync (push on window close via title polling)
function codes {
    $syncScript = "$AgentsRoot\bin\session-sync.ps1"
    $waitScript = "$AgentsRoot\bin\wait-vscode-window.ps1"
    $target = if ($args.Count -gt 0) { $args[0] } else { '.' }
    $codeArgs = $args -join ' '
    if ($target -match '\.code-workspace$') {
        $name = [IO.Path]::GetFileNameWithoutExtension((Resolve-Path $target).Path)
    } else {
        $name = Split-Path -Leaf (Resolve-Path $target).Path
    }
    Start-Process pwsh -ArgumentList "-NoProfile", "-WindowStyle", "Hidden", "-Command",
        "code.cmd --new-window $codeArgs; & '$waitScript' '$name'; & '$syncScript' push -Quiet" -WindowStyle Hidden
}
