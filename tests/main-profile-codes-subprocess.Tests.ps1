# Tests: profile-snippet.ps1, bin/get-config-var.ps1
# Tags: profile-snippet, session-sync, toggle, pwsh-required, subprocess, scope:common
#
# Real-process companion to tests/main-profile-codes.Tests.ps1. That file mocks
# Start-Process, which makes both automatic call sites unobservable in the ways
# that matter most:
#   - startup fetch: with the mock in place `git fetch` never runs, so a gate
#     that lets the fetch through but is only checked around the banner, or one
#     that blocks the fetch yet still reaches `git merge --ff-only FETCH_HEAD`,
#     looks identical to a correctly gated snippet;
#   - codes(): the push is asserted on the constructed -ArgumentList string, so
#     broken quoting, a bad argument boundary, or a command that simply cannot
#     launch still passes.
# Here the snippet runs in a real child pwsh with real git repositories and real
# recording stubs on PATH, so fetch, merge, editor launch, and push are observed
# as side effects rather than as strings. The mocked file is kept as-is: it is
# the fast layer, this is the broad-integration layer.
#
# TL3 gap (what this test does NOT catch):
# - A real interactive $PROFILE load driven by the user's own .env: the snippet
#   is dot-sourced from a mirror tree, so only the process environment and the
#   shipped default drive the gate.
# - Real VS Code and the real bin/session-sync.ps1: code.cmd, the window-wait
#   script, and the sync script are recording stubs, so a push that launches
#   correctly but fails inside session-sync.ps1 is out of scope here.
# - Windows PowerShell 5.1 as the host: the child is always pwsh 7.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: pwsh-required.

BeforeDiscovery {
    $script:CanRunSubprocessTests = (
        $IsWindows -and
        (Get-Command pwsh -ErrorAction SilentlyContinue) -and
        (Get-Command git  -ErrorAction SilentlyContinue)
    )
}

Describe "SESSION_SYNC gate in a real child process (profile-snippet.ps1)" -Skip:(-not $script:CanRunSubprocessTests) {
    BeforeAll {
        $script:AgentsDir = Split-Path -Parent $PSScriptRoot

        # A mirror of the agents tree plus a private HOME. profile-snippet.ps1
        # pins $env:AGENTS_CONFIG_DIR to its own parent, so a copy of the snippet
        # is the only way to control which config the gate reads. No .env is
        # written: a missing .env is a silent no-op in hooks/lib/load-env.js,
        # which leaves the process environment as the single SESSION_SYNC source.
        function New-RealSandbox {
            param([switch]$WithGitRepo)

            $root   = Join-Path $env:TEMP "profile-subproc-$(Get-Random)"
            $mirror = Join-Path $root "agents"
            $sbHome = Join-Path $root "home"
            $stubs  = Join-Path $root "stubs"
            $noNode = Join-Path $root "nonode"
            $calls  = Join-Path $root "calls"

            foreach ($d in @(
                (Join-Path $mirror "bin"), (Join-Path $mirror "hooks"),
                (Join-Path $mirror "install\win"),
                (Join-Path $sbHome ".claude"), $stubs, $noNode, $calls)) {
                New-Item -ItemType Directory -Path $d -Force | Out-Null
            }

            Copy-Item (Join-Path $script:AgentsDir "profile-snippet.ps1")   (Join-Path $mirror "profile-snippet.ps1")
            Copy-Item (Join-Path $script:AgentsDir "bin\get-config-var.ps1") (Join-Path $mirror "bin\get-config-var.ps1")
            Copy-Item (Join-Path $script:AgentsDir "hooks\lib") (Join-Path $mirror "hooks\lib") -Recurse -Force

            # Recording stubs — each appends one line per invocation, so both
            # "was it called" and "with which arguments" are observable.
            Set-Content -Path (Join-Path $mirror "bin\session-sync.ps1") -Value @(
                "Add-Content -Path '$calls\sync.calls' -Value ('was-called ' + (`$args -join ' '))")
            Set-Content -Path (Join-Path $mirror "bin\wait-vscode-window.ps1") -Value @(
                "Add-Content -Path '$calls\wait.calls' -Value ('was-called ' + (`$args -join ' '))")
            Set-Content -Path (Join-Path $mirror "install\win\dotfileslink.ps1") -Value '# no-op stub'
            Set-Content -Path (Join-Path $stubs "code.cmd") -Value @(
                '@echo off', "echo was-called %* >> `"$calls\code.calls`"", 'exit /b 0')
            Set-Content -Path (Join-Path $noNode "node.cmd") -Value @(
                '@echo off', 'echo node: simulated failure 1>&2', 'exit /b 127')

            $sb = @{
                Root = $root; Mirror = $mirror; Home = $sbHome; Stubs = $stubs
                NoNode = $noNode; Calls = $calls
                Projects = (Join-Path $sbHome ".claude\projects")
                GitConfig = (Join-Path $root "gitconfig"); RemoteHead = $null
            }

            Set-Content -Path $sb.GitConfig -Value @(
                '[user]', '  name = Session Sync Test', '  email = session-sync-test@example.com'
                '[init]', '  defaultBranch = main', '[commit]', '  gpgSign = false'
                '[advice]', '  detachedHead = false')

            if ($WithGitRepo) { Initialize-SandboxRepo -Sandbox $sb }
            $sb
        }

        # Real repositories, so fetch and merge are real operations:
        #   remote.git  <- seed (2 commits, second pushed after the clone)
        #   ~/.claude/projects  <- clone at commit 1, FETCH_HEAD removed
        # A correctly gated ON run therefore fetches (FETCH_HEAD appears) and
        # fast-forwards (HEAD reaches the remote tip); a gated-off run leaves
        # both untouched, which is what distinguishes "no fetch" from "fetched
        # but did not merge".
        function Initialize-SandboxRepo {
            param([Parameter(Mandatory)]$Sandbox)
            $prevNoSystem = $env:GIT_CONFIG_NOSYSTEM
            $prevGlobal   = $env:GIT_CONFIG_GLOBAL
            $env:GIT_CONFIG_NOSYSTEM = '1'
            $env:GIT_CONFIG_GLOBAL   = $Sandbox.GitConfig
            try {
                $remote = Join-Path $Sandbox.Root "remote.git"
                $seed   = Join-Path $Sandbox.Root "seed"
                git init --bare $remote *> $null
                git clone $remote $seed *> $null
                Set-Content -Path (Join-Path $seed "a.jsonl") -Value '{"a":1}'
                git -C $seed add -A *> $null
                git -C $seed commit -m "base" *> $null
                git -C $seed push -u origin main *> $null

                git clone $remote $Sandbox.Projects *> $null
                Remove-Item (Join-Path $Sandbox.Projects ".git\FETCH_HEAD") -Force -ErrorAction SilentlyContinue

                Set-Content -Path (Join-Path $seed "b.jsonl") -Value '{"b":2}'
                git -C $seed add -A *> $null
                git -C $seed commit -m "advance" *> $null
                git -C $seed push *> $null
                $Sandbox.RemoteHead = (git -C $seed rev-parse HEAD).Trim()
            } finally {
                if ($null -eq $prevNoSystem) { Remove-Item Env:GIT_CONFIG_NOSYSTEM -ErrorAction SilentlyContinue }
                else { $env:GIT_CONFIG_NOSYSTEM = $prevNoSystem }
                if ($null -eq $prevGlobal) { Remove-Item Env:GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue }
                else { $env:GIT_CONFIG_GLOBAL = $prevGlobal }
            }
        }

        # $HOME is ReadOnly+AllScope, so the child driver overrides it globally
        # before dot-sourcing; that is also what a real profile load looks like.
        function Invoke-ChildProfile {
            param([Parameter(Mandatory)]$Sandbox, [string]$CodesTarget, [int]$TimeoutSec = 60)

            $lines = @(
                '$ErrorActionPreference = "Continue"'
                "Set-Variable -Name HOME -Value '$($Sandbox.Home)' -Scope Global -Force"
                "`$env:GIT_CONFIG_NOSYSTEM = '1'"
                "`$env:GIT_CONFIG_GLOBAL = '$($Sandbox.GitConfig)'"
                ". '$($Sandbox.Mirror)\profile-snippet.ps1'")
            if ($CodesTarget) { $lines += "codes '$CodesTarget'" }
            $driver = Join-Path $Sandbox.Root "driver.ps1"
            Set-Content -Path $driver -Value $lines

            $stdout = Join-Path $Sandbox.Root "child.out"
            $stderr = Join-Path $Sandbox.Root "child.err"
            $p = Start-Process pwsh -ArgumentList '-NoProfile', '-NonInteractive', '-File', $driver `
                -NoNewWindow -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
            if (-not $p.WaitForExit($TimeoutSec * 1000)) {
                $p.Kill()
                throw "child profile load exceeded ${TimeoutSec}s"
            }
            @{ ExitCode = $p.ExitCode
               Output = ((Get-Content $stdout -Raw -ErrorAction SilentlyContinue) +
                         (Get-Content $stderr -Raw -ErrorAction SilentlyContinue)) }
        }

        # codes() detaches its work into a grandchild process, so the marker
        # files appear asynchronously.
        function Wait-ForCallFile {
            param([Parameter(Mandatory)][string]$Path, [int]$TimeoutSec = 30)
            $deadline = (Get-Date).AddSeconds($TimeoutSec)
            while ((Get-Date) -lt $deadline) {
                if (Test-Path $Path) { return $true }
                Start-Sleep -Milliseconds 200
            }
            return $false
        }
    }

    BeforeEach {
        $script:SavedSessionSync = $env:SESSION_SYNC
        $script:SavedConfigDir   = $env:AGENTS_CONFIG_DIR
        $script:SavedAgentsDir   = $env:AGENTS_DIR
        $script:SavedPath        = $env:PATH
        $script:Sandbox          = $null
    }

    AfterEach {
        if ($null -eq $script:SavedSessionSync) { Remove-Item Env:SESSION_SYNC -ErrorAction SilentlyContinue }
        else { $env:SESSION_SYNC = $script:SavedSessionSync }
        if ($null -eq $script:SavedConfigDir) { Remove-Item Env:AGENTS_CONFIG_DIR -ErrorAction SilentlyContinue }
        else { $env:AGENTS_CONFIG_DIR = $script:SavedConfigDir }
        if ($null -eq $script:SavedAgentsDir) { Remove-Item Env:AGENTS_DIR -ErrorAction SilentlyContinue }
        else { $env:AGENTS_DIR = $script:SavedAgentsDir }
        $env:PATH = $script:SavedPath
        if ($script:Sandbox) {
            Remove-Item -Recurse -Force $script:Sandbox.Root -ErrorAction SilentlyContinue
        }
    }

    Context "Startup auto-fetch against a real repository" {
        # Same value domain as the bash side (TC16d-TC16i in
        # tests/fix-1225-profile-snippet-guards/session-sync-gate.sh) — the two
        # snippets are symmetric members of one class (CPR-5).
        It "SESSION_SYNC=<label> -> fetch and merge <expectText> (<why>)" -ForEach @(
            @{ label = 'off';           value = 'off';   brokenNode = $false; expect = $false; expectText = 'do not run'; why = 'explicit off' }
            @{ label = '(unset)';       value = $null;   brokenNode = $false; expect = $false; expectText = 'do not run'; why = 'shipped default is off' }
            @{ label = 'maybe+nonode';  value = 'maybe'; brokenNode = $true;  expect = $false; expectText = 'do not run'; why = 'unreadable config, fail-safe off' }
            @{ label = 'maybe';         value = 'maybe'; brokenNode = $false; expect = $false; expectText = 'do not run'; why = 'unrecognized value, fail-safe off' }
            @{ label = 'on';            value = 'on';    brokenNode = $false; expect = $true;  expectText = 'both run';   why = 'explicit on' }
            @{ label = 'ON';            value = 'ON';    brokenNode = $false; expect = $true;  expectText = 'both run';   why = 'value match is case-insensitive' }
        ) {
            $script:Sandbox = New-RealSandbox -WithGitRepo
            if ($null -eq $value) { Remove-Item Env:SESSION_SYNC -ErrorAction SilentlyContinue }
            else { $env:SESSION_SYNC = $value }
            $env:PATH = if ($brokenNode) { "$($script:Sandbox.NoNode);$($script:Sandbox.Stubs);$env:PATH" }
                        else { "$($script:Sandbox.Stubs);$env:PATH" }

            $result = Invoke-ChildProfile -Sandbox $script:Sandbox

            $fetched = Test-Path (Join-Path $script:Sandbox.Projects ".git\FETCH_HEAD")
            $head    = (git -C $script:Sandbox.Projects rev-parse HEAD 2>$null)
            $merged  = ($null -ne $head -and $head.Trim() -eq $script:Sandbox.RemoteHead)

            $fetched | Should -Be $expect -Because "$why — git fetch must run only on an explicit, readable on. Child output: $($result.Output)"
            $merged  | Should -Be $expect -Because "$why — git merge --ff-only FETCH_HEAD must not be reached when the gate is off. Child output: $($result.Output)"
        }

        It "gate OFF leaves the rest of the profile working" {
            # Orthogonality: the toggle gates the fetch, never the snippet. The
            # codes function must still be defined after an OFF load.
            $script:Sandbox = New-RealSandbox -WithGitRepo
            $env:SESSION_SYNC = 'off'
            $env:PATH = "$($script:Sandbox.Stubs);$env:PATH"

            $driverProbe = Join-Path $script:Sandbox.Root "probe.ps1"
            Set-Content -Path $driverProbe -Value @(
                "Set-Variable -Name HOME -Value '$($script:Sandbox.Home)' -Scope Global -Force"
                ". '$($script:Sandbox.Mirror)\profile-snippet.ps1'"
                'if (Get-Command codes -CommandType Function -ErrorAction SilentlyContinue) { "codes-defined" }')
            $out = pwsh -NoProfile -NonInteractive -File $driverProbe 2>&1 | Out-String

            $out | Should -Match 'codes-defined' `
                -Because "an off toggle must not stop the snippet from defining codes()"
        }
    }

    Context "codes() auto-push through real child processes" {
        It "SESSION_SYNC=<label> -> push <expectText> (<why>)" -ForEach @(
            @{ label = 'off';          value = 'off';   brokenNode = $false; expect = $false; expectText = 'does not run'; why = 'explicit off' }
            @{ label = '(unset)';      value = $null;   brokenNode = $false; expect = $false; expectText = 'does not run'; why = 'shipped default is off' }
            @{ label = 'maybe+nonode'; value = 'maybe'; brokenNode = $true;  expect = $false; expectText = 'does not run'; why = 'unreadable config, fail-safe off' }
            @{ label = 'maybe';        value = 'maybe'; brokenNode = $false; expect = $false; expectText = 'does not run'; why = 'unrecognized value, fail-safe off' }
            @{ label = 'on';           value = 'on';    brokenNode = $false; expect = $true;  expectText = 'runs';         why = 'explicit on' }
            @{ label = 'ON';           value = 'ON';    brokenNode = $false; expect = $true;  expectText = 'runs';         why = 'value match is case-insensitive' }
        ) {
            # No git repo in HOME, so the startup fetch is out of the picture and
            # the only observable left is what codes() launches.
            $script:Sandbox = New-RealSandbox
            if ($null -eq $value) { Remove-Item Env:SESSION_SYNC -ErrorAction SilentlyContinue }
            else { $env:SESSION_SYNC = $value }
            $env:PATH = if ($brokenNode) { "$($script:Sandbox.NoNode);$($script:Sandbox.Stubs);$env:PATH" }
                        else { "$($script:Sandbox.Stubs);$env:PATH" }

            $result = Invoke-ChildProfile -Sandbox $script:Sandbox -CodesTarget $script:Sandbox.Home

            # The editor launch is unconditional, so it is both an orthogonality
            # assertion and the synchronization point: once it has landed, the
            # push (next in the same command string) has had its chance to run.
            $codeCalls = Join-Path $script:Sandbox.Calls "code.calls"
            (Wait-ForCallFile -Path $codeCalls) | Should -BeTrue `
                -Because "codes() must launch VS Code whatever the toggle says. Child output: $($result.Output)"

            $syncCalls = Join-Path $script:Sandbox.Calls "sync.calls"
            if ($expect) {
                (Wait-ForCallFile -Path $syncCalls) | Should -BeTrue -Because $why
                (Get-Content $syncCalls -Raw) | Should -Match 'push' `
                    -Because "the launched command must reach session-sync.ps1 with the push subcommand"
                (Get-Content $syncCalls -Raw) | Should -Match '-Quiet' `
                    -Because "quoting must survive the -Command string: -Quiet has to arrive as its own argument"
            } else {
                # Give the (absent) push the same wall-clock budget the ON rows
                # need, so a slow launch is not mistaken for a blocked one.
                Start-Sleep -Seconds 3
                (Test-Path $syncCalls) | Should -BeFalse -Because $why
            }
        }

        It "the launched command string is executable, not merely well-formed" {
            # The mocked sibling test asserts on -ArgumentList text. This one
            # proves the same string actually runs: all three stages of the
            # chain (editor, window wait, push) must record.
            $script:Sandbox = New-RealSandbox
            $env:SESSION_SYNC = 'on'
            $env:PATH = "$($script:Sandbox.Stubs);$env:PATH"

            $result = Invoke-ChildProfile -Sandbox $script:Sandbox -CodesTarget $script:Sandbox.Home

            foreach ($stage in @('code.calls', 'wait.calls', 'sync.calls')) {
                (Wait-ForCallFile -Path (Join-Path $script:Sandbox.Calls $stage)) | Should -BeTrue `
                    -Because "stage $stage of the codes() chain never executed. Child output: $($result.Output)"
            }
        }
    }
}
