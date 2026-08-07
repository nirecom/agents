# Sourced from dotfiles' profile.ps1 (sibling-detected) or directly from $PROFILE.
# Idempotent — safe to source twice.
$AgentsRoot = $PSScriptRoot
$env:AGENTS_CONFIG_DIR = $AgentsRoot
$env:AGENTS_DIR        = $AgentsRoot

# Global default for Claude Code's auto-compact token window, read from .env.
# get-config-var resolves process-env-wins-over-.env precedence itself, so a value
# already set in this shell (or by a launcher such as code-ccgw.cmd for a single
# local-LLM session) is left untouched.
$_getCfgAcw = Join-Path $AgentsRoot 'bin\get-config-var.ps1'
if (Test-Path $_getCfgAcw) {
    try {
        $_acw = & $_getCfgAcw CLAUDE_CODE_AUTO_COMPACT_WINDOW
        if ($_acw) { $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = $_acw }
    } catch {}
}
Remove-Variable _getCfgAcw, _acw -ErrorAction SilentlyContinue

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
    # try/catch is mandatory: install.ps1 sets $ErrorActionPreference = "Stop",
    # inherited by called scripts. get-config-var.ps1 can Write-Error (unrecognized
    # value) or throw (node missing) — both become terminating errors under Stop,
    # and redirecting streams does not suppress termination. A profile script must
    # not abort the user's shell startup regardless of the caller's own preference.
    $_ssOn = $false
    $_getCfg = Join-Path $AgentsRoot 'bin\get-config-var.ps1'
    # Save the caller's pre-existing $LASTEXITCODE before the reset below, so it can be
    # restored once the gate check is finalized — this profile block runs on every shell
    # startup and must not leave 0/1 behind for a caller inspecting $LASTEXITCODE for an
    # unrelated prior command.
    $_preLastExitCode = $global:LASTEXITCODE
    if (Test-Path $_getCfg) {
        try {
            # Reset before the call: a stale nonzero $LASTEXITCODE left by an unrelated
            # earlier command must never be read as an "on" verdict (bash sibling: _ss_rc=0).
            $global:LASTEXITCODE = 0
            # *> (all streams) matches the bash sibling's stderr suppression at this call
            # site: this gate must fail safe and silent on every interactive shell startup,
            # not leak a resolver diagnostic (missing Node, unrecognized value, etc.).
            & $_getCfg -IsOff SESSION_SYNC off *> $null
            if ($LASTEXITCODE -eq 1) { $_ssOn = $true }
        } catch {
            $_ssOn = $false
        }
    }
    $global:LASTEXITCODE = $_preLastExitCode
    if ($_ssOn) {
        Write-Host "git fetch Claude session sync ..."
        # -RedirectStandardError keeps stderr (SSH/git diagnostics) out of the console,
        # matching the bash sibling's `2>/dev/null` — Start-Process has no null-redirect
        # shorthand, so a discarded temp file is the idiomatic equivalent.
        $_fetchErrFile = [System.IO.Path]::GetTempFileName()
        # Batch mode mirrors the bash sibling: an auth-required or misconfigured remote
        # fails fast instead of hanging on a credential/host-key prompt. The child inherits
        # $env: from this scope, so prior values are restored in finally — this snippet is
        # sourced into an interactive shell and must not leave the overrides behind.
        $_gitPromptPrev = $env:GIT_TERMINAL_PROMPT
        $_gitSshPrev = $env:GIT_SSH_COMMAND
        $_fetchKilled = $false
        try {
            $env:GIT_TERMINAL_PROMPT = '0'
            # Bare "ssh" resolves via PATH, which on Windows finds Git's bundled MSYS2
            # ssh.exe ahead of the Windows-native one — that binary can't reach the
            # Windows OpenSSH Authentication Agent, so a passphrase-protected key fails
            # publickey auth outright instead of just skipping the interactive prompt.
            # The Windows-native path keeps agent access while still enforcing BatchMode.
            $env:GIT_SSH_COMMAND = '"C:\Windows\System32\OpenSSH\ssh.exe" -o BatchMode=yes'
            # Start-Process -ArgumentList joins array elements with plain spaces before
            # handing them to the OS process-creation API — the array form alone does NOT
            # quote elements containing spaces. $SessionDir must therefore be wrapped in
            # literal double quotes so it stays one git argv entry even when it contains a
            # space (e.g. "C:\Users\First Last\.claude\projects").
            $_fetchSs = Start-Process -FilePath git -ArgumentList @('-C', "`"$SessionDir`"", 'fetch') -NoNewWindow -PassThru -RedirectStandardError $_fetchErrFile
        } finally {
            $env:GIT_TERMINAL_PROMPT = $_gitPromptPrev
            $env:GIT_SSH_COMMAND = $_gitSshPrev
        }
        if (-not $_fetchSs.WaitForExit(3000)) {
            $_fetchSs.Kill()
            # Block until the killed process exits, so it no longer holds the stderr temp file.
            $_fetchSs.WaitForExit()
            $_fetchKilled = $true
        }
        elseif ($_fetchSs.ExitCode -eq 0) { git -C $SessionDir merge --ff-only --no-summary FETCH_HEAD 2>$null }
        if (-not $_fetchKilled -and $_fetchSs.ExitCode -ne 0) {
            # One-line hint only — raw git/SSH stderr is too noisy for shell startup.
            Write-Host "git fetch failed (exit $($_fetchSs.ExitCode)) — run 'git -C $SessionDir fetch' manually to see why" -ForegroundColor DarkGray
        }
        Remove-Item $_fetchErrFile -ErrorAction SilentlyContinue
        Remove-Variable _fetchSs, _fetchErrFile, _fetchKilled, _gitPromptPrev, _gitSshPrev -ErrorAction SilentlyContinue
    }
    Remove-Variable _ssOn, _getCfg, _preLastExitCode -ErrorAction SilentlyContinue
}

# $cmd (built inside codes below) is a command STRING executed by a child pwsh, so every
# value interpolated into it is wrapped in single quotes with embedded quotes doubled (''
# is the PowerShell single-quote escape). Without this, a directory name or a caller
# argument containing a quote or ';' would break out of its quoting and run arbitrary code
# in the hidden window.
function _codesQuote([string]$s) { "'" + ($s -replace "'", "''") + "'" }

# Launch VS Code with session sync (push on window close via title polling)
function codes {
    $syncScript = "$AgentsRoot\bin\session-sync.ps1"
    $waitScript = "$AgentsRoot\bin\wait-vscode-window.ps1"
    $target = if ($args.Count -gt 0) { $args[0] } else { '.' }
    if ($target -match '\.code-workspace$') {
        $name = [IO.Path]::GetFileNameWithoutExtension((Resolve-Path $target).Path)
    } else {
        $name = Split-Path -Leaf (Resolve-Path $target).Path
    }
    $_ssOn = $false
    $_getCfg = Join-Path $AgentsRoot 'bin\get-config-var.ps1'
    # See the auto-fetch block above: save the pre-existing $LASTEXITCODE so it can be
    # restored once the gate is finalized — `codes` must not leave 0/1 behind for a
    # caller inspecting $LASTEXITCODE for an unrelated prior command.
    $_preLastExitCode = $global:LASTEXITCODE
    if (Test-Path $_getCfg) {
        try {
            # Reset first so a stale exit code cannot read as "on". *> (all streams)
            # keeps a resolver diagnostic from leaking on every `codes` invocation,
            # matching the bash sibling's stderr suppression at this call site.
            $global:LASTEXITCODE = 0
            & $_getCfg -IsOff SESSION_SYNC off *> $null
            if ($LASTEXITCODE -eq 1) { $_ssOn = $true }
        } catch { $_ssOn = $false }
    }
    $global:LASTEXITCODE = $_preLastExitCode
    $codeArgs = ($args | ForEach-Object { _codesQuote "$_" }) -join ' '
    $cmd = "code.cmd --new-window $codeArgs"
    if ($_ssOn) { $cmd += "; & $(_codesQuote $waitScript) $(_codesQuote $name); & $(_codesQuote $syncScript) push -Quiet" }
    Start-Process pwsh -ArgumentList "-NoProfile", "-WindowStyle", "Hidden", "-Command", $cmd -WindowStyle Hidden
}
