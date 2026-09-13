# Transaction-suite helpers for session-sync-init.ps1 (#1773).
# Dot-source from a Pester BeforeAll AFTER session-sync-security-common.ps1,
# whose $script:InitScript this file reads. Split out of
# main-session-sync-security-transaction.Tests.ps1 at the 300-line threshold.

# Import-InstallerFunction — define the first candidate that exists as a global
# function. Global, not script, so the migration's own by-name call resolves to
# it (and later to the counting wrapper that shadows it).
function Import-InstallerFunction {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Candidates)
    $tokens = $null
    $errors = $null
    $root = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $defs = $root.FindAll({
        $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)
    foreach ($name in $Candidates) {
        $fn = $defs | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($fn) {
            $body = $fn.Body.Extent.Text
            $body = $body.Substring(1, $body.Length - 2)
            Set-Item -Path "function:global:$name" -Value ([scriptblock]::Create($body))
            return $name
        }
    }
    return $null
}

# The primary names are the ones detail.md D names; the aliases are accepted so a
# reasonable synonym does not turn a passing implementation red.
$script:RenameFn = Import-InstallerFunction $script:InitScript @("Move-NoClobber", "Move-ItemNoClobber", "Invoke-NoClobberRename")
$script:MigrateFn = Import-InstallerFunction $script:InitScript @("Invoke-GitRootMigration", "Move-GitRoot", "Invoke-GitRootMove")
$script:TxReady = ($null -ne $script:RenameFn) -and ($null -ne $script:MigrateFn)
$script:TxMissing = "session-sync-init.ps1 does not define the transaction functions yet (expected Move-NoClobber and Invoke-GitRootMigration)"

# Assert-TxReady — one shared red-by-design failure, so a missing implementation
# reports the same actionable message from every case.
function Assert-TxReady {
    if (-not $script:TxReady) { throw $script:TxMissing }
}

# Get-TxState — one signature covering existence and content of the three
# migrated names, so a before/after comparison is a single assertion.
function Get-TxState {
    param([Parameter(Mandatory)][string]$Dir)
    $parts = foreach ($n in @(".git\marker", ".gitignore", ".gitattributes")) {
        $p = Join-Path $Dir $n
        $v = if (Test-Path $p) { (Get-Content $p -Raw).Trim() } else { "MISSING" }
        "$n=$v;"
    }
    return ($parts -join "")
}

# New-TxFixture — SRC is the claude dir, DST the projects dir nested inside it,
# both carrying all three names so every phase has work to do.
function New-TxFixture {
    param([Parameter(Mandatory)][string]$Tag)
    $base = Join-Path $script:SuiteHome "tx-$Tag-$(Get-Random)"
    $src = Join-Path $base ".claude"
    $dst = Join-Path $src "projects"
    New-Item -ItemType Directory -Path (Join-Path $src ".git") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dst ".git") -Force | Out-Null
    Set-Content -Path (Join-Path $src ".git\marker") -Value "src-git" -NoNewline
    Set-Content -Path (Join-Path $src ".gitignore") -Value "src-ignore" -NoNewline
    Set-Content -Path (Join-Path $src ".gitattributes") -Value "src-attrs" -NoNewline
    Set-Content -Path (Join-Path $dst ".git\marker") -Value "dst-git" -NoNewline
    Set-Content -Path (Join-Path $dst ".gitignore") -Value "dst-ignore" -NoNewline
    Set-Content -Path (Join-Path $dst ".gitattributes") -Value "dst-attrs" -NoNewline
    return @{ Src = $src; Dst = $dst }
}

function New-PairDir {
    param([Parameter(Mandatory)][string]$Tag)
    $d = Join-Path $script:SuiteHome "ncr-$Tag-$(Get-Random)"
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

function Invoke-TxRename {
    param([string]$From, [string]$To)
    return [bool](& $script:RenameFn $From $To)
}

# Invoke-RollbackCase — with all three names on both sides the call order is
# fixed: 1-3 Phase 1a, 4-6 Phase 1b, 7-9 Phase 2. Failing the 2nd-or-later rename
# of a phase leaves earlier ones already committed, which is what rollback undoes.
function Invoke-RollbackCase {
    param([Parameter(Mandatory)][string]$Tag, [Parameter(Mandatory)][int]$FailAt)
    $fx = New-TxFixture $Tag
    $srcBefore = Get-TxState $fx.Src
    $dstBefore = Get-TxState $fx.Dst
    $real = (Get-Item "function:global:$($script:RenameFn)").ScriptBlock
    $global:TxRenameCount = 0
    $global:TxRenameFailAt = $FailAt
    $global:TxRenameReal = $real
    Set-Item -Path "function:global:$($script:RenameFn)" -Value {
        param([string]$From, [string]$To)
        $global:TxRenameCount++
        if ($global:TxRenameCount -eq $global:TxRenameFailAt) { return $false }
        return (& $global:TxRenameReal $From $To)
    }
    try {
        $ok = [bool](& $script:MigrateFn $fx.Src $fx.Dst)
    } finally {
        Set-Item -Path "function:global:$($script:RenameFn)" -Value $real
    }
    $ok | Should -BeFalse -Because "a failed rename must not report success"
    Get-TxState $fx.Src | Should -Be $srcBefore -Because "SRC must be restored"
    Get-TxState $fx.Dst | Should -Be $dstBefore -Because "DST must be restored"
    Get-StagingResidue $fx.Src | Should -BeNullOrEmpty
    Get-StagingResidue $fx.Dst | Should -BeNullOrEmpty
}

# Invoke-VerbFaultCase — the same injection one layer lower: instead of the
# rename helper returning $false, the underlying cmdlet raises a terminating
# error, which the installer's $ErrorActionPreference = "Stop" makes fatal. An
# implementation that only inspects a return value unwinds nothing here.
function Invoke-VerbFaultCase {
    param([Parameter(Mandatory)][string]$Tag, [Parameter(Mandatory)][int]$FailAt)
    $fx = New-TxFixture $Tag
    $srcBefore = Get-TxState $fx.Src
    $dstBefore = Get-TxState $fx.Dst
    $global:TxVerbCount = 0
    $global:TxVerbFailAt = $FailAt
    # Both verbs share one counter: the transaction is free to pick either for a
    # given pair, and the Nth filesystem move is the injection point either way.
    function global:Move-Item {
        $global:TxVerbCount++
        if ($global:TxVerbCount -eq $global:TxVerbFailAt) { throw "injected Move-Item failure" }
        Microsoft.PowerShell.Management\Move-Item @args
    }
    function global:Rename-Item {
        $global:TxVerbCount++
        if ($global:TxVerbCount -eq $global:TxVerbFailAt) { throw "injected Rename-Item failure" }
        Microsoft.PowerShell.Management\Rename-Item @args
    }
    $ok = $false
    try {
        try { $ok = [bool](& $script:MigrateFn $fx.Src $fx.Dst) } catch { $ok = $false }
    } finally {
        Microsoft.PowerShell.Management\Remove-Item function:global:Move-Item -ErrorAction SilentlyContinue
        Microsoft.PowerShell.Management\Remove-Item function:global:Rename-Item -ErrorAction SilentlyContinue
    }
    $ok | Should -BeFalse -Because "a terminating filesystem error is not a successful migration"
    Get-TxState $fx.Src | Should -Be $srcBefore -Because "SRC must be restored"
    Get-TxState $fx.Dst | Should -Be $dstBefore -Because "DST must be restored"
    Get-StagingResidue $fx.Src | Should -BeNullOrEmpty
    Get-StagingResidue $fx.Dst | Should -BeNullOrEmpty
}
