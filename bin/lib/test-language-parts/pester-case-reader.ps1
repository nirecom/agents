# bin/lib/test-language-parts/pester-case-reader.ps1 <file> — the pester entry's case reader child.
# Parses the file with the PowerShell parser (never runs it) and reports each top-level
# Describe '<name>' -Tag 'target:<path>'. Prints
#   FILE<TAB><state><TAB><line><TAB><reason>   and, when conforming, one
#   CASE<TAB><name><TAB><target><TAB><begin><TAB><end><TAB><TAB>   per Describe, in file order
# (begin = the Describe line, end = its closing brace line). Exit 1: unreadable file.
# The case enumeration lives in pester-case-scan.ps1, shared with pester-case-analyzer.ps1.
param([Parameter(Mandatory)][string]$Path)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'pester-case-scan.ps1')

function Write-Record {
    param([object[]]$Row)
    [Console]::Out.Write((($Row | ForEach-Object { $_ -join "`t" }) -join "`n") + "`n")
}

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    [Console]::Error.WriteLine("pester-case-reader: cannot read $Path")
    exit 1
}
$token = $null; $parseError = $null
$full = (Resolve-Path -LiteralPath $Path).ProviderPath
$ast = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$token, [ref]$parseError)
if ($parseError.Count -gt 0) {
    Write-Record -Row @(, @('FILE', 'malformed', $parseError[0].Extent.StartLineNumber, 'grammar'))
    exit 0
}

$scan = Get-CaseScan -Ast $ast
if ($scan.Fault.Count -gt 0) {
    $first = $scan.Fault | Sort-Object -Property { $_[0] } | Select-Object -First 1
    Write-Record -Row @(, @('FILE', 'malformed', $first[0], $first[1]))
    exit 0
}
$row = [System.Collections.Generic.List[object]]::new()
$row.Add(@('FILE', $(if ($scan.Case.Count -gt 0) { 'conforming' } else { 'none' }), '', ''))
foreach ($c in $scan.Case) { $row.Add(@('CASE', $c.Name, $c.Target, $c.Begin, $c.End, '', '')) }
Write-Record -Row $row.ToArray()
