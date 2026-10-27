# codex.ps1 - Install/update Codex CLI via npm
# The update calls npm directly: `codex update` runs npm from codex.exe itself, and npm then
# cannot delete that locked, running exe (EPERM). Waiting for claude and codex to exit first
# leaves no locked exe behind.
# Only the codex whose shim sits in the fnm npm global prefix is updated; others are left alone.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-CodexUnderNpmPrefix {
    param([Parameter(Mandatory)][string]$NpmPrefix)
    $cmd = Get-Command -Name codex -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd -or [string]::IsNullOrWhiteSpace($cmd.Source)) { return $false }
    $shimDir = [IO.Path]::GetFullPath((Split-Path -Parent $cmd.Source)).TrimEnd('\', '/')
    $prefixDir = [IO.Path]::GetFullPath($NpmPrefix).TrimEnd('\', '/')
    return [string]::Equals($shimDir, $prefixDir, [StringComparison]::OrdinalIgnoreCase)
}

if (Get-Command codex -ErrorAction SilentlyContinue) {
    Write-Host "Codex is already installed." -ForegroundColor DarkGray
    $PSNativeCommandUseErrorActionPreference = $false
    $_waitNames = @{ claude = 'Claude Code'; codex = 'Codex' }
    $_waitScript = if ($env:WAIT_CC_EXIT_SCRIPT_OVERRIDE) { $env:WAIT_CC_EXIT_SCRIPT_OVERRIDE } else { Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "install\lib\wait-cc-exit.ps1" }
    foreach ($_proc in @('claude', 'codex')) {
        & pwsh -NoProfile -File $_waitScript -ProcessName $_proc
        if ($LASTEXITCODE -ne 0) { Write-Warning "$($_waitNames[$_proc]) still running — skipping update."; exit 0 }
    }
    try {
        if (Get-Command fnm -ErrorAction SilentlyContinue) {
            $global:LASTEXITCODE = 0
            $_fnmEnv = & fnm env --shell powershell 2>$null | Out-String
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "fnm env failed (exit code: $LASTEXITCODE); using npm from PATH."
            } elseif (-not [string]::IsNullOrWhiteSpace($_fnmEnv)) {
                Invoke-Expression $_fnmEnv
            }
        }
        $_prefix = ''
        if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
            Write-Warning "npm not found; skipping codex update."
        } else {
            $global:LASTEXITCODE = 0
            $_prefixOut = @(& npm prefix -g 2>$null)
            if ($LASTEXITCODE -eq 0 -and $_prefixOut.Count -gt 0) { $_prefix = "$($_prefixOut[0])".Trim() }
            if (-not $_prefix) { Write-Warning "npm prefix -g failed (exit code: $LASTEXITCODE); skipping codex update." }
        }
        if ($_prefix) {
            if (Test-CodexUnderNpmPrefix -NpmPrefix $_prefix) {
                Write-Host "Updating Codex..."
                $global:LASTEXITCODE = 0
                npm install -g @openai/codex
                $npmExit = $LASTEXITCODE
                if ($npmExit -ne 0) {
                    Write-Warning "codex update failed (exit code: $npmExit); retry manually."
                }
            } else {
                $_codexPath = (Get-Command -Name codex -ErrorAction SilentlyContinue | Select-Object -First 1).Source
                Write-Warning "codex found at '$_codexPath' is not under the npm global prefix '$_prefix'; skipping npm update."
            }
        }
    } catch {
        Write-Warning "codex update skipped: $($_.Exception.Message)"
    }
    exit 0
} else {
    fnm env --shell powershell | Out-String | Invoke-Expression
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        Write-Warning "fnm is installed but npm not found. Run: fnm install --lts"
        exit 1
    }
    Write-Host "Installing Codex..."
    npm install -g @openai/codex
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Codex installed." -ForegroundColor Green
    } else {
        Write-Warning "Codex installation failed (exit code: $LASTEXITCODE). Re-run to retry."
    }
}
