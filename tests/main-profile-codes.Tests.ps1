# Tests: profile-snippet.ps1, bin/get-config-var.ps1
# Tags: profile-snippet, session-sync, toggle, pwsh-required, scope:common
# Tests for the codes function in profile-snippet.ps1
# Verifies that codes uses Start-Process (not Start-Job) for terminal independence

BeforeAll {
    $AgentsDir = Split-Path -Parent $PSScriptRoot
    $ProfileScript = Join-Path $AgentsDir "profile-snippet.ps1"
    $script:ProfileContent = Get-Content $ProfileScript -Raw
}

Describe "codes function (profile-snippet.ps1)" {
    Context "Normal cases" {
        It "uses Start-Process (not Start-Job)" {
            $ProfileContent | Should -Match 'Start-Process'
            $ProfileContent | Should -Not -Match 'Start-Job'
        }

        It "uses -WindowStyle Hidden for background execution" {
            $ProfileContent | Should -Match '-WindowStyle\s+Hidden'
        }

        It "includes code.cmd --new-window (without --wait)" {
            $ProfileContent | Should -Match 'code\.cmd\s+--new-window'
            # --wait should no longer be used (replaced by window polling)
            $codesBlock = ($ProfileContent -split 'function codes')[1] -split 'function ' | Select-Object -First 1
            $codesBlock | Should -Not -Match 'code\.cmd[^;]*--wait'
        }

        It "calls wait-vscode-window.ps1 between code.cmd and session-sync push" {
            $codesBlock = ($ProfileContent -split 'function codes')[1] -split 'function ' | Select-Object -First 1
            $codesBlock | Should -Match 'wait-vscode-window\.ps1' `
                -Because "window polling script must be called"
            $codesBlock | Should -Match 'syncScript.*push' `
                -Because "session-sync push must follow window polling"
        }

        It "resolves workspace name for title matching" {
            $codesBlock = ($ProfileContent -split 'function codes')[1] -split 'function ' | Select-Object -First 1
            $codesBlock | Should -Match '\.code-workspace' `
                -Because "must handle .code-workspace files"
            $codesBlock | Should -Match 'Split-Path|GetFileNameWithoutExtension' `
                -Because "must extract workspace/folder name"
        }
    }

    Context "Edge cases" {
        It "args are joined with space (handles empty args without breaking)" {
            # Verify the per-arg transform + join pattern is used — empty args
            # produce empty string, not error. The join now runs over the
            # per-item quoting pipeline, not the raw $args array.
            $codesBlock = ($ProfileContent -split 'function codes')[1] -split 'function ' | Select-Object -First 1
            $codesBlock | Should -Match '\$args\s*\|\s*ForEach-Object' `
                -Because "each arg must be piped through a per-item transform before joining"
            $codesBlock | Should -Match '\)\s*-join\s+' `
                -Because "the transformed args are joined with space"
        }

        It "args are passed into the command string" {
            $codesBlock = ($ProfileContent -split 'function codes')[1] -split 'function ' | Select-Object -First 1
            $codesBlock | Should -Match '\$codeArgs' -Because "codeArgs variable must be referenced in command"
        }

        It "embedded single quotes in args/name are escaped before reaching the command string (security)" {
            # Locks in the fix for the command-string-injection vulnerability:
            # a directory name or argument containing a single quote must not
            # be able to break out of its quoting and run arbitrary code in
            # the hidden child pwsh. A regression back to raw string
            # interpolation (e.g. "$args -join ' '" or bare "$name") must
            # fail this test.
            $codesBlock = ($ProfileContent -split 'function codes')[1] -split 'function ' | Select-Object -First 1
            $ProfileContent | Should -Match '_codesQuote|-replace\s+"''"' `
                -Because "a quoting/escaping helper that doubles embedded single quotes must exist"
            $codesBlock | Should -Match '_codesQuote' `
                -Because "the codes function must route args and `$name through the quoting helper, not raw interpolation"
        }
    }
}

# ---------------------------------------------------------------------------
# SESSION_SYNC gate — the pwsh half of the contract also covered on the bash
# side by tests/fix-1225-profile-snippet-guards/session-sync-gate.sh. The two
# snippets are symmetric members of one class (CPR-5), so the value domain and
# the expectations below are deliberately identical to TC13-TC21 there.
#
# Contract: SESSION_SYNC gates the two *automatic* call sites only —
#   1. the startup auto-fetch of ~/.claude/projects
#   2. the codes() auto-push (bin/session-sync.ps1 push -Quiet)
# Shipped default is off and resolution is fail-safe OFF: the automatic path
# runs only on an explicit, readable `on`. Unset, unrecognized, and unreadable
# (node broken) must all leave it silent. The manual CLI is NOT gated — that
# contract is pinned in tests/main-session-sync.Tests.ps1.
#
# TL3 gap (what this test does NOT catch):
# - A real interactive $PROFILE load, where the user's actual .env supplies
#   SESSION_SYNC. The snippet is dot-sourced from a mirror tree because
#   profile-snippet.ps1 overwrites $env:AGENTS_CONFIG_DIR with its own parent,
#   so only the process environment can drive the gate here.
# - A real VS Code / git / pwsh process: Start-Process is mocked, so the launch
#   is asserted on the constructed argument list, not on an observed process.
#   The broad-integration counterpart — real child pwsh, real git fetch/merge,
#   recording stubs on PATH — lives in tests/main-profile-codes-subprocess.Tests.ps1;
#   this file stays the fast, mocked layer.
# - Windows PowerShell 5.1 vs pwsh 7 divergence in the snippet itself; this file
#   runs under whichever host the suite is invoked with.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: pwsh-required.
# ---------------------------------------------------------------------------
Describe "SESSION_SYNC gate (profile-snippet.ps1)" -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    BeforeAll {
        # Build a throwaway copy of the agents tree. profile-snippet.ps1 pins
        # $env:AGENTS_CONFIG_DIR to $PSScriptRoot, so the only way to keep the
        # gate reading a controlled config is to run a copy of the snippet.
        # No .env is written: hooks/lib/load-env.js short-circuits on
        # AGENTS_CONFIG_DIR and a missing .env is a silent no-op, which leaves
        # the process environment as the single SESSION_SYNC source.
        function New-MirrorSandbox {
            param([switch]$WithSessionRepo, [switch]$NoopConfigVar)

            $root   = Join-Path $env:TEMP "profile-gate-$(Get-Random)"
            $mirror = Join-Path $root "agents"
            $sbHome = Join-Path $root "home"
            $noNode = Join-Path $root "nonode"

            foreach ($d in @(
                (Join-Path $mirror "bin"),
                (Join-Path $mirror "hooks"),
                (Join-Path $mirror "install\win"),
                (Join-Path $sbHome ".claude"),
                $noNode)) {
                New-Item -ItemType Directory -Path $d -Force | Out-Null
            }

            Copy-Item (Join-Path $AgentsDir "profile-snippet.ps1") (Join-Path $mirror "profile-snippet.ps1")
            Copy-Item (Join-Path $AgentsDir "bin\get-config-var.ps1") (Join-Path $mirror "bin\get-config-var.ps1")
            Copy-Item (Join-Path $AgentsDir "hooks\lib") (Join-Path $mirror "hooks\lib") -Recurse -Force

            if ($NoopConfigVar) {
                # Models a zero-byte/truncated get-config-var.ps1: the call
                # site does `& $_getCfg ...` and this stub returns without
                # setting $LASTEXITCODE and without throwing, so any stale
                # value left over from an earlier command survives the call
                # untouched — exactly the M1 vulnerability scenario.
                Set-Content -Path (Join-Path $mirror "bin\get-config-var.ps1") `
                    -Value '# no-op stub: intentionally does not set $LASTEXITCODE'
            }

            # Recording stubs. Under Mock Start-Process these are never actually
            # executed; they exist so an implementation that probes for them
            # (Test-Path guards) sees the same shape as a real install.
            Set-Content -Path (Join-Path $mirror "bin\session-sync.ps1") -Value @(
                '$callFile = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "session-sync.calls"'
                'Add-Content -Path $callFile -Value ("was-called " + ($args -join " "))')
            Set-Content -Path (Join-Path $mirror "bin\wait-vscode-window.ps1") -Value '# no-op stub'
            Set-Content -Path (Join-Path $mirror "install\win\dotfileslink.ps1") -Value '# no-op stub'

            # A `node` that always fails, used to model an unreadable config.
            Set-Content -Path (Join-Path $noNode "node.cmd") -Value @(
                '@echo off', 'echo node: simulated failure 1>&2', 'exit /b 127')

            if ($WithSessionRepo) {
                New-Item -ItemType Directory -Path (Join-Path $sbHome ".claude\projects\.git") -Force | Out-Null
            }

            @{ Root = $root; Mirror = $mirror; Home = $sbHome; NoNode = $noNode }
        }

        # Dot-source the mirrored snippet with $HOME pointed at the sandbox.
        # $HOME is ReadOnly+AllScope in Windows PowerShell, so it cannot be
        # shadowed in a child scope — it has to be overridden globally, and
        # AfterEach restores the saved value.
        function Invoke-MirrorProfile {
            param(
                [Parameter(Mandatory)]$Sandbox,
                [switch]$InvokeCodes,
                [string[]]$CodesArgs,
                [switch]$NoCodesArgs
            )
            Set-Variable -Name HOME -Value $Sandbox.Home -Scope Global -Force
            . (Join-Path $Sandbox.Mirror "profile-snippet.ps1")
            if ($InvokeCodes) {
                if ($NoCodesArgs) { codes }
                elseif ($CodesArgs) { codes @CodesArgs }
                else { codes $Sandbox.Home }
            }
        }

        function Test-StartupFetchRan {
            foreach ($c in $script:StartProcessCalls) {
                if ($c.FilePath -eq 'git' -and (($c.ArgumentList -join ' ') -match 'fetch')) { return $true }
            }
            # Second signal: an implementation that swaps the launch mechanism
            # but keeps the banner still counts as "the automatic path ran".
            foreach ($l in $script:HostLines) {
                if ($l -match 'git fetch Claude session sync') { return $true }
            }
            return $false
        }

        function Get-CodesLaunchArgs {
            foreach ($c in $script:StartProcessCalls) {
                $joined = $c.ArgumentList -join ' '
                if ($joined -match 'code\.cmd') { return $joined }
            }
            return $null
        }

        function Test-CodesPushWired {
            $joined = Get-CodesLaunchArgs
            return ($null -ne $joined -and $joined -match 'session-sync\.ps1')
        }
    }

    BeforeEach {
        $script:SavedSessionSync   = $env:SESSION_SYNC
        $script:SavedConfigDir     = $env:AGENTS_CONFIG_DIR
        $script:SavedAgentsDir     = $env:AGENTS_DIR
        $script:SavedPath          = $env:PATH
        $script:SavedHome          = $HOME
        $script:SavedHomeOptions   = (Get-Variable HOME).Options
        $script:StartProcessCalls  = [System.Collections.ArrayList]::new()
        $script:HostLines          = [System.Collections.ArrayList]::new()
        $script:Sandbox            = $null

        Mock Start-Process {
            [void]$script:StartProcessCalls.Add([pscustomobject]@{
                FilePath     = $FilePath
                ArgumentList = @($ArgumentList)
            })
            # Stand-in process object: WaitForExit() succeeds and ExitCode is
            # non-zero so the snippet never falls through to a real git merge.
            [pscustomobject]@{ ExitCode = 1 } |
                Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $true } -PassThru |
                Add-Member -MemberType ScriptMethod -Name Kill -Value { } -PassThru
        }
        Mock Write-Host { [void]$script:HostLines.Add(($Object -join ' ')) }
    }

    AfterEach {
        if ($null -eq $script:SavedSessionSync) {
            Remove-Item Env:SESSION_SYNC -ErrorAction SilentlyContinue
        } else { $env:SESSION_SYNC = $script:SavedSessionSync }
        if ($null -eq $script:SavedConfigDir) {
            Remove-Item Env:AGENTS_CONFIG_DIR -ErrorAction SilentlyContinue
        } else { $env:AGENTS_CONFIG_DIR = $script:SavedConfigDir }
        if ($null -eq $script:SavedAgentsDir) {
            Remove-Item Env:AGENTS_DIR -ErrorAction SilentlyContinue
        } else { $env:AGENTS_DIR = $script:SavedAgentsDir }
        $env:PATH = $script:SavedPath
        Set-Variable -Name HOME -Value $script:SavedHome -Scope Global -Force `
            -Option $script:SavedHomeOptions
        if ($script:Sandbox) {
            Remove-Item -Recurse -Force $script:Sandbox.Root -ErrorAction SilentlyContinue
        }
    }

    Context "Startup auto-fetch" {
        # Table-driven over the whole value domain: shipped default (unset),
        # both recognized values, a case variant, an unrecognized value, and an
        # unreadable config. Only an explicit, readable `on` may let it run.
        It "SESSION_SYNC=<label> -> auto-fetch <expectText> (<why>)" -ForEach @(
            @{ label = 'off';         value = 'off';   brokenNode = $false; expect = $false; expectText = 'stays silent'; why = 'explicit off' }
            @{ label = '(unset)';     value = $null;   brokenNode = $false; expect = $false; expectText = 'stays silent'; why = 'shipped default is off' }
            @{ label = 'maybe+nonode'; value = 'maybe'; brokenNode = $true;  expect = $false; expectText = 'stays silent'; why = 'unreadable config, fail-safe off' }
            @{ label = 'maybe';       value = 'maybe'; brokenNode = $false; expect = $false; expectText = 'stays silent'; why = 'unrecognized value, fail-safe off' }
            @{ label = 'on';          value = 'on';    brokenNode = $false; expect = $true;  expectText = 'runs';         why = 'explicit on' }
            @{ label = 'ON';          value = 'ON';    brokenNode = $false; expect = $true;  expectText = 'runs';         why = 'value match is case-insensitive' }
        ) {
            $script:Sandbox = New-MirrorSandbox -WithSessionRepo
            if ($null -eq $value) {
                Remove-Item Env:SESSION_SYNC -ErrorAction SilentlyContinue
            } else { $env:SESSION_SYNC = $value }
            if ($brokenNode) { $env:PATH = "$($script:Sandbox.NoNode);$env:PATH" }

            Invoke-MirrorProfile -Sandbox $script:Sandbox

            Test-StartupFetchRan | Should -Be $expect -Because $why
        }
    }

    Context "codes() auto-push" {
        # Same six rows as the startup-fetch matrix above. The two call sites are
        # symmetric members of one class (CPR-5): a value that must not start the
        # fetch must not start the push either, so neither matrix may be the
        # shorter one — an unrecognized value with a *working* resolver and the
        # upper-case spelling are exactly where the two paths could diverge.
        It "SESSION_SYNC=<label> -> codes() push <expectText> (<why>)" -ForEach @(
            @{ label = 'off';          value = 'off';   brokenNode = $false; expect = $false; expectText = 'stays silent'; why = 'explicit off' }
            @{ label = '(unset)';      value = $null;   brokenNode = $false; expect = $false; expectText = 'stays silent'; why = 'shipped default is off' }
            @{ label = 'maybe+nonode'; value = 'maybe'; brokenNode = $true;  expect = $false; expectText = 'stays silent'; why = 'unreadable config, fail-safe off' }
            @{ label = 'maybe';        value = 'maybe'; brokenNode = $false; expect = $false; expectText = 'stays silent'; why = 'unrecognized value with a working resolver, fail-safe off' }
            @{ label = 'on';           value = 'on';    brokenNode = $false; expect = $true;  expectText = 'runs';         why = 'explicit on' }
            @{ label = 'ON';           value = 'ON';    brokenNode = $false; expect = $true;  expectText = 'runs';         why = 'value match is case-insensitive' }
        ) {
            $script:Sandbox = New-MirrorSandbox
            if ($null -eq $value) {
                Remove-Item Env:SESSION_SYNC -ErrorAction SilentlyContinue
            } else { $env:SESSION_SYNC = $value }
            if ($brokenNode) { $env:PATH = "$($script:Sandbox.NoNode);$env:PATH" }

            Invoke-MirrorProfile -Sandbox $script:Sandbox -InvokeCodes

            Test-CodesPushWired | Should -Be $expect -Because $why
        }

        It "gate ON preserves the codes() push invocation (push -Quiet)" {
            # Guards against a gate rewrite that silently changes the arguments
            # the sync script is called with.
            $script:Sandbox = New-MirrorSandbox
            $env:SESSION_SYNC = 'on'

            Invoke-MirrorProfile -Sandbox $script:Sandbox -InvokeCodes

            $joined = Get-CodesLaunchArgs
            $joined | Should -Not -BeNullOrEmpty
            $joined | Should -Match "session-sync\.ps1'?\s+push" `
                -Because "the push subcommand must survive the gate"
            $joined | Should -Match '-Quiet' `
                -Because "the push must stay quiet in the background launch"
        }

        It "wait-vscode-window runs before the session-sync push in the constructed command (ordering)" {
            # C3: the existing static test only checks that both tokens are
            # present somewhere in the codes function body (regex presence),
            # which an implementation that fires the push before the wait
            # would still pass. This asserts the actual order of the two
            # sub-invocations inside the one constructed -Command string
            # handed to the mocked Start-Process.
            $script:Sandbox = New-MirrorSandbox
            $env:SESSION_SYNC = 'on'

            Invoke-MirrorProfile -Sandbox $script:Sandbox -InvokeCodes

            $joined = Get-CodesLaunchArgs
            $joined | Should -Not -BeNullOrEmpty

            $waitIdx = $joined.IndexOf('wait-vscode-window')
            $pushIdx = $joined.IndexOf('session-sync')
            $waitIdx | Should -BeGreaterThan -1 -Because "wait-vscode-window.ps1 must be invoked"
            $pushIdx | Should -BeGreaterThan -1 -Because "session-sync.ps1 push must be invoked"
            $waitIdx | Should -BeLessThan $pushIdx `
                -Because "the wait must genuinely precede the push in the constructed command, not merely both appear somewhere in it"
        }

        It "re-sourcing the snippet re-evaluates the gate" {
            # The snippet advertises itself as idempotent and safe to source
            # twice. A gate that caches its verdict in a script-scoped variable
            # would keep the first answer forever, so flipping the toggle
            # between two loads must change the outcome.
            $script:Sandbox = New-MirrorSandbox
            $env:SESSION_SYNC = 'off'
            Invoke-MirrorProfile -Sandbox $script:Sandbox -InvokeCodes
            Test-CodesPushWired | Should -BeFalse `
                -Because "the first load sees the toggle off"

            $script:StartProcessCalls.Clear()
            $env:SESSION_SYNC = 'on'
            Invoke-MirrorProfile -Sandbox $script:Sandbox -InvokeCodes
            Test-CodesPushWired | Should -BeTrue `
                -Because "the second load must re-read the toggle, not reuse a cached verdict"
        }

        It "gate OFF still defines codes() and still launches VS Code" {
            # Orthogonality: the toggle gates the sync side effect only, never
            # the codes command itself.
            $script:Sandbox = New-MirrorSandbox
            $env:SESSION_SYNC = 'off'

            Invoke-MirrorProfile -Sandbox $script:Sandbox -InvokeCodes

            $joined = Get-CodesLaunchArgs
            $joined | Should -Not -BeNullOrEmpty `
                -Because "codes must still launch VS Code when sync is off"
            $joined | Should -Match 'code\.cmd\s+--new-window'
            $joined | Should -Not -Match 'session-sync\.ps1'
        }
    }

    Context "Command-string injection (security)" {
        It "an attack payload with a single quote and a statement separator stays inside one properly-escaped quoted token" {
            # C1: the static regression test only checks that a `_codesQuote`
            # token exists somewhere in the source, which would still pass if
            # `_codesQuote` protected only one interpolation site while $args
            # or $name leaked in raw elsewhere. This drives an actual attack
            # payload through `codes` and inspects the real constructed
            # -Command string handed to the mocked Start-Process.
            $script:Sandbox = New-MirrorSandbox
            $payload = "test'; malicious-marker #"

            Invoke-MirrorProfile -Sandbox $script:Sandbox -InvokeCodes `
                -CodesArgs @($script:Sandbox.Home, $payload)

            $joined = Get-CodesLaunchArgs
            $joined | Should -Not -BeNullOrEmpty

            # Positive: the payload must appear exactly as `_codesQuote` would
            # produce it — wrapped in single quotes with every embedded quote
            # doubled — not interpolated raw.
            $expectedQuoted = "'" + ($payload -replace "'", "''") + "'"
            $expectedQuotedPattern = [regex]::Escape($expectedQuoted)
            $joined | Should -Match $expectedQuotedPattern `
                -Because "the payload must be wrapped in single quotes with every embedded ' doubled, not interpolated raw"

            # Negative: a bare (undoubled) quote immediately followed by the
            # statement separator would close the quoted token early and let
            # the rest of the payload run as a new statement in the hidden
            # child pwsh. This pattern must never appear.
            $joined | Should -Not -Match "test';\s*malicious-marker" `
                -Because "an undoubled quote before the separator would break out of the quoted token and execute the payload as a new statement"
        }
    }

    Context "Stale LASTEXITCODE fail-open regression (security)" {
        It "a stale nonzero LASTEXITCODE before a no-op get-config-var.ps1 is not misread as SESSION_SYNC=on" {
            # C2: simulates the exact M1 vulnerability — a zero-byte/truncated
            # get-config-var.ps1 (modeled here as a no-op stub that returns
            # without setting $LASTEXITCODE and without throwing) combined
            # with a stale nonzero $LASTEXITCODE left by an unrelated earlier
            # command. Without the `$global:LASTEXITCODE = 0` reset immediately
            # before each `& $_getCfg` call, the stale 1 would be misread as
            # an "on" verdict for both automatic call sites.
            $script:Sandbox = New-MirrorSandbox -WithSessionRepo -NoopConfigVar
            Remove-Item Env:SESSION_SYNC -ErrorAction SilentlyContinue
            $savedLastExitCode = $global:LASTEXITCODE
            try {
                $global:LASTEXITCODE = 1

                Invoke-MirrorProfile -Sandbox $script:Sandbox -InvokeCodes

                Test-StartupFetchRan | Should -BeFalse `
                    -Because "a stale nonzero LASTEXITCODE must not be misread as SESSION_SYNC=on for the startup auto-fetch"
                Test-CodesPushWired | Should -BeFalse `
                    -Because "a stale nonzero LASTEXITCODE must not be misread as SESSION_SYNC=on for the codes() push"
            } finally {
                $global:LASTEXITCODE = $savedLastExitCode
            }
        }
    }

    Context "Zero-args edge case (executable)" {
        It "codes with no positional argument resolves the default target and still launches VS Code" {
            # C4: the static "args are joined with space" test only pattern-
            # matches the ForEach-Object/-join shape in the source; it never
            # actually calls `codes` with zero arguments. This drives the
            # real zero-args path end-to-end.
            $script:Sandbox = New-MirrorSandbox

            { Invoke-MirrorProfile -Sandbox $script:Sandbox -InvokeCodes -NoCodesArgs } |
                Should -Not -Throw `
                -Because "codes must resolve the default target '.' and launch even with no positional argument"

            $joined = Get-CodesLaunchArgs
            $joined | Should -Not -BeNullOrEmpty `
                -Because "the code.cmd launch must actually happen for the zero-args path, not merely avoid throwing"
            $joined | Should -Match 'code\.cmd\s+--new-window'
        }
    }
}
