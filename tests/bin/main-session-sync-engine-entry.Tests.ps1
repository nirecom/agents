# Tests: bin/session-sync.ps1, install/win/session-sync-init.ps1
# Tags: bin, install, git, session-sync, session-sync-engine, pwsh-required, subprocess, scope:issue-specific
#
# #2658: the sh and ps1 entries are thin layers over bin/session-sync-engine;
# one fixture fed to both gives one result (CPR-ORTH). ps1 notification
# contract: -Quiet failure -> toast "push failed (exit code N)", otherwise throw.
#
# TL3 gap: the real WinRT toast (powershell.exe 5.1) is replaced by a recording
# function; see bin/check-verification-gate.sh category pwsh-required.

BeforeDiscovery {
    $script:CanRun = [bool]((Get-Command git -ErrorAction SilentlyContinue) -and (Get-Command node -ErrorAction SilentlyContinue))
    $script:HasBash = [bool](Get-Command bash -ErrorAction SilentlyContinue)
}

Describe 'session-sync entries over the engine' -Tag 'target:bin/session-sync.ps1' -Skip:(-not $script:CanRun) {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
        $script:Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:SyncPs1 = Join-Path $script:Root 'bin\session-sync.ps1'
        $script:SyncSh = (Join-Path $script:Root 'bin\session-sync.sh') -replace '\\', '/'
        $script:InitPs1 = Join-Path $script:Root 'install\win\session-sync-init.ps1'
        $script:Saved = @{
            GIT_CONFIG_NOSYSTEM = $env:GIT_CONFIG_NOSYSTEM; GIT_CONFIG_GLOBAL = $env:GIT_CONFIG_GLOBAL
            WORKFLOW_PLANS_DIR = $env:WORKFLOW_PLANS_DIR; USERPROFILE = $env:USERPROFILE
        }
        $script:Tmp = Join-Path $env:TEMP "ss-entry-$(Get-Random)"
        New-Item -ItemType Directory -Path (Join-Path $script:Tmp 'plans') -Force | Out-Null
        $gc = Join-Path $script:Tmp 'gitconfig'
        Set-Content -Path $gc -Value @('[user]', '  name = Entry Test', '  email = entry@example.com',
            '[init]', '  defaultBranch = main', '[commit]', '  gpgSign = false', '[core]', '  hooksPath = NUL', '  autocrlf = false',
            '[maintenance]', '  auto = false', '[gc]', '  auto = 0')
        $env:GIT_CONFIG_NOSYSTEM = '1'; $env:GIT_CONFIG_GLOBAL = $gc
        $env:WORKFLOW_PLANS_DIR = Join-Path $script:Tmp 'plans'
        # session-sync-init.ps1 refuses a -ClaudeDir outside USERPROFILE (#1773).
        $env:USERPROFILE = $env:TEMP

        # remote.git <- other (one commit after the clone); <name>\.claude\projects
        # is a clone with one unpushed local file: the diverged push case.
        function New-Fixture {
            param([string]$Name)
            $base = Join-Path $script:Tmp $Name
            $remote = Join-Path $base 'remote.git'; $other = Join-Path $base 'other'
            $claude = Join-Path $base '.claude'; $proj = Join-Path $claude 'projects'
            git init -q --bare $remote 2>&1 | Out-Null
            git clone -q $remote $other 2>&1 | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $other '.gitattributes'), "* text eol=lf`n")
            [System.IO.File]::WriteAllText((Join-Path $other 'base.jsonl'), "{`"uuid`":`"base`"}`n")
            git -C $other add -A 2>&1 | Out-Null; git -C $other commit -qm base 2>&1 | Out-Null
            git -C $other push -q -u origin main 2>&1 | Out-Null
            New-Item -ItemType Directory -Path $claude -Force | Out-Null
            git clone -q $remote $proj 2>&1 | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $other 'other.jsonl'), "{`"uuid`":`"other`"}`n")
            git -C $other add -A 2>&1 | Out-Null; git -C $other commit -qm other 2>&1 | Out-Null
            git -C $other push -q 2>&1 | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $proj 'local.jsonl'), "{`"uuid`":`"local`"}`n")
            @{ Base = $base; Remote = $remote; Claude = $claude; Projects = $proj
               OtherTip = (git -C $other rev-parse HEAD).Trim() }
        }

        # Child pwsh, so stdout / stderr / throw are observed as a caller sees
        # them. powershell.exe (the toast host) is shadowed by a recording function.
        function Invoke-Ps1Entry {
            param([string]$ClaudeDir, [string]$Action = 'push', [switch]$Quiet)
            $toast = Join-Path $script:Tmp "toast-$(Get-Random).log"
            $q = if ($Quiet) { ' -Quiet' } else { '' }
            $driver = Join-Path $script:Tmp "drv-$(Get-Random).ps1"
            Set-Content -Path $driver -Value @(
                "function global:powershell.exe { Add-Content -Path '$toast' -Value (`$args -join ' ') }"
                "try { & '$script:SyncPs1' -Action $Action -ClaudeDir '$ClaudeDir'$q } catch { [Console]::Error.WriteLine('THREW: ' + `$_); exit 9 }")
            $out = "$driver.out"; $err = "$driver.err"
            $p = Start-Process pwsh -ArgumentList '-NoProfile', '-NonInteractive', '-File', "`"$driver`"" -NoNewWindow -PassThru `
                -RedirectStandardOutput $out -RedirectStandardError $err
            if (-not $p.WaitForExit(120000)) { $p.Kill(); throw 'ps1 entry exceeded 120s' }
            @{ Code = $p.ExitCode; Out = [string](Get-Content $out -Raw -ErrorAction SilentlyContinue)
               Err = [string](Get-Content $err -Raw -ErrorAction SilentlyContinue)
               Toast = [string](Get-Content $toast -Raw -ErrorAction SilentlyContinue) }
        }

        function Get-RemoteShape {
            param($Fx)
            $tip = (git -C $Fx.Remote rev-parse main).Trim()
            @{ Files = ((git -C $Fx.Remote ls-tree -r --name-only main) -join ',')
               Parents = @((git -C $Fx.Remote rev-list --parents -n 1 $tip).Trim() -split ' ' | Select-Object -Skip 1)
               Message = (git -C $Fx.Remote log -1 --format=%s main).Trim() }
        }
        $script:MsgPattern = '^sync: \S+ \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$'
    }

    AfterAll {
        foreach ($k in $script:Saved.Keys) {
            if ($null -eq $script:Saved[$k]) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue } else { Set-Item "Env:$k" -Value $script:Saved[$k] }
        }
        Remove-Item -Recurse -Force $script:Tmp -ErrorAction SilentlyContinue
    }

    It 'ps1 push of a diverged clone gives one commit on the remote tip, no rebase' {
        $fx = New-Fixture -Name 'ps1-push'
        $r = Invoke-Ps1Entry -ClaudeDir $fx.Claude
        $r.Code | Should -Be 0 -Because "stderr: $($r.Err)"
        $r.Out | Should -Match 'Pushed session data\.'
        $s = Get-RemoteShape $fx
        foreach ($f in @('base.jsonl', 'local.jsonl', 'other.jsonl')) { ",$($s.Files)," | Should -Match ",$([regex]::Escape($f))," }
        $s.Parents.Count | Should -Be 1
        $s.Parents[0] | Should -Be $fx.OtherTip -Because 'the sync commit is built on R, not rebased'
        $s.Message | Should -Match $script:MsgPattern
        Test-Path (Join-Path $fx.Projects '.git\rebase-merge') | Should -BeFalse
    }

    It 'sh and ps1 entries give the same result on the same fixture' -Skip:(-not $script:HasBash) {
        $a = New-Fixture -Name 'sym-ps1'
        $b = New-Fixture -Name 'sym-sh'
        $ra = Invoke-Ps1Entry -ClaudeDir $a.Claude
        $outB = & bash $script:SyncSh push --claude-dir ($b.Claude -replace '\\', '/') 2>$null | Out-String
        $LASTEXITCODE | Should -Be 0
        $sa = Get-RemoteShape $a; $sb = Get-RemoteShape $b
        $sa.Files | Should -Be $sb.Files
        $sa.Parents.Count | Should -Be $sb.Parents.Count
        $sa.Message | Should -Match $script:MsgPattern
        $sb.Message | Should -Match $script:MsgPattern
        ($ra.Out -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 1).Trim() |
            Should -Be (($outB -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 1).Trim())
        [System.IO.File]::ReadAllText((Join-Path $a.Projects '.gitattributes')) |
            Should -Be ([System.IO.File]::ReadAllText((Join-Path $b.Projects '.gitattributes')))
    }

    It 'ps1 -Quiet push failure shows the "push failed (exit code N)" toast and does not throw' {
        $fx = New-Fixture -Name 'quiet-fail'
        git -C $fx.Projects remote set-url origin (Join-Path $script:Tmp 'missing.git') 2>&1 | Out-Null
        $r = Invoke-Ps1Entry -ClaudeDir $fx.Claude -Quiet
        $r.Code | Should -Be 0 -Because "a quiet failure must not throw (stderr: $($r.Err))"
        $r.Toast | Should -Match 'push failed \(exit code [1-9]\d*\)'
        $r.Out | Should -Not -Match 'Pushed session data'
    }

    It 'ps1 non-quiet push failure throws' {
        $fx = New-Fixture -Name 'loud-fail'
        git -C $fx.Projects remote set-url origin (Join-Path $script:Tmp 'missing.git') 2>&1 | Out-Null
        $r = Invoke-Ps1Entry -ClaudeDir $fx.Claude
        $r.Code | Should -Be 9 -Because 'the entry must throw on a non-quiet failure'
        $r.Err | Should -Match 'THREW'
        $r.Toast | Should -BeNullOrEmpty
    }

    It 'init seeds .gitignore once and never overwrites the managed block' {
        $claude = Join-Path $script:Tmp 'init\.claude'
        New-Item -ItemType Directory -Path $claude -Force | Out-Null
        & $script:InitPs1 -ClaudeDir $claude -NoRemote *> $null
        $ignore = Join-Path $claude 'projects\.gitignore'
        [System.IO.File]::ReadAllText($ignore) | Should -Match '(?m)^/workflow/\*\.tmp$'
        $custom = "# BEGIN agents session-sync (managed)`n/workflow/`n# END agents session-sync (managed)`nmy-custom-ignore`n"
        [System.IO.File]::WriteAllText($ignore, $custom)
        & $script:InitPs1 -ClaudeDir $claude -NoRemote *> $null
        & $script:InitPs1 -ClaudeDir $claude -NoRemote *> $null
        [System.IO.File]::ReadAllText($ignore) | Should -Be $custom
    }
}
