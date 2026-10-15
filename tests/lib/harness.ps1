# Shared test helpers. Dot-source inside the top-level BeforeAll of a test file:
#   . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
# Functions defined during discovery are gone at run time, so every helper here is called from
# BeforeAll or It; Skip-HarnessUnlessTL3 cannot feed an It's -Skip: argument.

$script:HarnessIsolation = $null
$script:HarnessPinned = [ordered]@{ WORKFLOW_STATE_DIR = 'workflow-state'; WORKFLOW_PLANS_DIR = 'plans' }
$script:HarnessRemoved = @('CLAUDE_CODE_SESSION_ID')

# Re-points the workflow dirs into a fresh temp directory and removes the session variables.
# Pair it with Exit-HarnessIsolation in a finally block; a second exit does nothing.
function Enter-HarnessIsolation {
    Exit-HarnessIsolation
    $saved = @{}
    foreach ($name in @($script:HarnessPinned.Keys) + $script:HarnessRemoved) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-' + [guid]::NewGuid().ToString('N'))
    foreach ($name in $script:HarnessPinned.Keys) {
        $dir = Join-Path $root $script:HarnessPinned[$name]
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [Environment]::SetEnvironmentVariable($name, $dir)
    }
    foreach ($name in $script:HarnessRemoved) { [Environment]::SetEnvironmentVariable($name, $null) }
    $script:HarnessIsolation = @{ Root = $root; Saved = $saved }
}

function Exit-HarnessIsolation {
    $state = $script:HarnessIsolation
    if ($null -eq $state) { return }
    $script:HarnessIsolation = $null
    foreach ($name in $state.Saved.Keys) { [Environment]::SetEnvironmentVariable($name, $state.Saved[$name]) }
    Remove-Item -LiteralPath $state.Root -Recurse -Force -ErrorAction SilentlyContinue
}

# A fixture repo where no installed hook fires and no ignore file of the developer applies.
function New-HarnessGitRepo {
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $excludes = (Join-Path $full '.git' 'info' 'exclude') -replace '\\', '/'
    foreach ($arguments in @(
            @('init', '-q', $full),
            @('-C', $full, 'config', 'core.hooksPath', '/dev/null'),
            @('-C', $full, 'config', 'core.excludesFile', $excludes))) {
        $output = & git @arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($arguments -join ' ') failed: $output" }
    }
}

# A known failure: passes while the block throws, fails the test once it stops throwing.
function Invoke-HarnessKnownFailure {
    param([Parameter(Mandatory)][string]$Because, [Parameter(Mandatory)][scriptblock]$ScriptBlock)
    $failed = $false
    try { & $ScriptBlock | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw "known failure no longer fails ($Because): remove the known-failure wrapper" }
}

# Call first inside an It: marks it skipped and ends it unless RUN_TL3 is on. The process
# value wins; without one, bin/get-config-var answers. A lookup that fails reads as off.
function Skip-HarnessUnlessTL3 {
    $value = $env:RUN_TL3
    if ([string]::IsNullOrEmpty($value)) {
        $value = ''
        try {
            $reader = (Join-Path $PSScriptRoot '..' '..' 'bin' 'get-config-var') -replace '\\', '/'
            $output = & bash $reader RUN_TL3 off 2>$null
            if ($LASTEXITCODE -eq 0) { $value = "$output".Trim() }
        } catch { $value = '' }
    }
    if ($value -ne 'on') { Set-ItResult -Skipped -Because 'RUN_TL3 is off' }
}
