# npm.ps1 - Update npm itself to latest. Never fails the installer: every path exits 0.
# When the current Node cannot run the latest npm, Node is raised first (fnm).

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
# install.ps1 runs this in-process; a native non-zero exit must not throw (same as codex.ps1).
$PSNativeCommandUseErrorActionPreference = $false

$SCRIPT_CHECKOUT_ROOT = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$_npmManual = "Run manually: npm install -g npm@latest"
$_npmNotLatest = "npm is NOT at latest."
$_engineCheck = "$SCRIPT_CHECKOUT_ROOT\install\lib\npm-engine-check.js"

function Test-DirWritable([string]$Dir) {
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir -PathType Container)) { return $false }
    $probe = Join-Path $Dir (".npm-write-probe-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType File -Path $probe -ErrorAction Stop | Out-Null
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

# Raise the default Node (fnm) to a version latest npm supports: the newest of the current
# major when it qualifies, else the LTS. Returns $true when the running Node now qualifies.
function Update-NodeForNpm([string]$Range) {
    if (-not (Get-Command fnm -ErrorAction SilentlyContinue)) { return $false }
    $oldNode = (& node --version | Out-String).Trim()
    $major = (& node -p "process.versions.node.split('.')[0]" | Out-String).Trim()
    $target = (& fnm list-remote 2>$null | & node $_engineCheck --pick $Range $major | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $target) {
        & fnm install --lts | Out-Host
        if ($LASTEXITCODE -ne 0) { return $false }
        $target = "lts-latest"
    } else {
        & fnm install $target | Out-Host
        if ($LASTEXITCODE -ne 0) { return $false }
    }
    & fnm default $target | Out-Host
    if ($LASTEXITCODE -ne 0) { return $false }
    & fnm use $target | Out-Host
    if ($LASTEXITCODE -ne 0) { return $false }
    & node $_engineCheck $Range | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    $newNode = (& node --version | Out-String).Trim()
    Write-Host "Node raised from $oldNode to $newNode so the latest npm can run."
    Write-Host "Note: global npm packages the installer does not reinstall (installed by hand) are not visible to $newNode."
    return $true
}

try {
    if (Get-Command fnm -ErrorAction SilentlyContinue) {
        try { fnm env --shell powershell | Out-String | Invoke-Expression } catch { Write-Warning "fnm env failed: $($_.Exception.Message)" }
    }
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        Write-Warning "npm not found. $_npmNotLatest npm update skipped."
        exit 0
    }

    # Pre-check: the incoming npm must support the current Node; raise Node when it does not.
    $global:LASTEXITCODE = 0
    $_range = (& npm view npm@latest engines.node 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not read the latest npm requirements. $_npmNotLatest Skipping update. $_npmManual"
        exit 0
    }
    & node $_engineCheck $_range
    if ($LASTEXITCODE -eq 1) {
        if (-not (Update-NodeForNpm $_range)) {
            Write-Warning "Latest npm does not support the current Node ($_range) and Node could not be raised. $_npmNotLatest Skipping update. Raise Node (fnm install --lts; fnm default lts-latest), then $_npmManual"
            exit 0
        }
    } elseif ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not verify npm/Node compatibility. $_npmNotLatest Skipping update. $_npmManual"
        exit 0
    }

    # Skip unwritable installs (e.g. Program Files managed Node); checked on the Node npm will use.
    $_root = (& npm root -g 2>$null | Out-String).Trim()
    $_prefix = (& npm prefix -g 2>$null | Out-String).Trim()
    if (-not ($_root -and $_prefix -and (Test-DirWritable $_root) -and (Test-DirWritable (Join-Path $_root "npm")) -and (Test-DirWritable $_prefix))) {
        Write-Warning "npm global location is not writable. $_npmNotLatest Skipping update. $_npmManual"
        exit 0
    }

    Write-Host "Updating npm (latest)..."
    & npm install -g npm@latest
    if ($LASTEXITCODE -eq 0) {
        Write-Host "npm is up to date." -ForegroundColor Green
    } else {
        Write-Warning "npm update failed (exit code: $LASTEXITCODE); keeping the installed version. $_npmNotLatest $_npmManual"
    }
} catch {
    Write-Warning "npm update skipped: $($_.Exception.Message). $_npmNotLatest $_npmManual"
}
exit 0
