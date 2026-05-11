# tests/feature-worktreeinclude.Tests.ps1
#
# Windows-specific path-handling tests for the .worktreeinclude file-copy
# feature. Verifies that the bin script normalizes Windows backslash paths
# and produces JSON parseable by ConvertFrom-Json.
#
# Source under test (test-first — may not yet exist):
#   bin/worktree-copy-include.js
#
# These tests spawn `node bin/worktree-copy-include.js` with a JSON payload
# whose path fields contain Windows-style backslashes. Contract: the script
# normalizes backslashes to forward slashes internally, executes the copy,
# and emits valid JSON to stdout.

Describe "bin/worktree-copy-include.js Windows path normalization" {
    BeforeAll {
        $script:agentsDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
        $script:binJs     = Join-Path $script:agentsDir "bin\worktree-copy-include.js"
        $script:tmpBase   = Join-Path ([System.IO.Path]::GetTempPath()) ("wti-pester-" + [System.Guid]::NewGuid().ToString("N").Substring(0, 8))
        New-Item -ItemType Directory -Path $script:tmpBase -Force | Out-Null

        # Helper: set up a fake main repo with .gitignore + a gitignored file.
        function script:New-FakeMainRepo {
            param([string]$Name)
            $repo = Join-Path $script:tmpBase $Name
            New-Item -ItemType Directory -Path $repo -Force | Out-Null
            git -C $repo init -q -b main 2>$null
            git -C $repo config user.email "test@example.com" 2>$null
            git -C $repo config user.name "Test" 2>$null
            git -C $repo config core.hooksPath /dev/null 2>$null
            Set-Content -LiteralPath (Join-Path $repo ".gitignore") -Value ".env*`n!.env.example`n*.local`n" -NoNewline
            Set-Content -LiteralPath (Join-Path $repo "README.md")  -Value "init" -NoNewline
            git -C $repo add .gitignore README.md 2>$null
            git -C $repo commit -q -m "initial" 2>$null
            return $repo
        }

        function script:New-WorktreeDest {
            param([string]$Name)
            $wt = Join-Path $script:tmpBase $Name
            New-Item -ItemType Directory -Path $wt -Force | Out-Null
            return $wt
        }

        # Helper: invoke the bin script with a literal JSON string on stdin.
        # Returns @{ stdout = ...; stderr = ...; exit = ... }
        function script:Invoke-Bin {
            param([string]$JsonPayload)
            $stdout = [System.IO.Path]::GetTempFileName()
            $stderr = [System.IO.Path]::GetTempFileName()
            try {
                $p = Start-Process -FilePath "node" `
                                   -ArgumentList @($script:binJs) `
                                   -RedirectStandardInput (New-PayloadFile $JsonPayload) `
                                   -RedirectStandardOutput $stdout `
                                   -RedirectStandardError  $stderr `
                                   -NoNewWindow -PassThru -Wait
                $exit = $p.ExitCode
                $so = (Get-Content -Raw -LiteralPath $stdout -ErrorAction SilentlyContinue)
                $se = (Get-Content -Raw -LiteralPath $stderr -ErrorAction SilentlyContinue)
                return @{ stdout = $so; stderr = $se; exit = $exit }
            } finally {
                Remove-Item -LiteralPath $stdout -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $stderr -ErrorAction SilentlyContinue
            }
        }

        function script:New-PayloadFile {
            param([string]$JsonPayload)
            $f = [System.IO.Path]::GetTempFileName()
            # UTF-8 no BOM
            [System.IO.File]::WriteAllText($f, $JsonPayload, (New-Object System.Text.UTF8Encoding $false))
            return $f
        }
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:tmpBase) {
            Remove-Item -LiteralPath $script:tmpBase -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context "W1: Windows-style backslash mainRoot is normalized" {
        It "accepts mainRoot with backslashes (escaped as \\\\ in JSON) and copies files" {
            if (-not (Test-Path -LiteralPath $script:binJs)) {
                Set-ItResult -Skipped -Because "bin/worktree-copy-include.js not implemented yet"
                return
            }
            $main = script:New-FakeMainRepo "w1-main"
            $wt   = script:New-WorktreeDest  "w1-wt"
            Set-Content -LiteralPath (Join-Path $main ".worktreeinclude") -Value ".env.local" -NoNewline
            Set-Content -LiteralPath (Join-Path $main ".env.local")       -Value "x=1"        -NoNewline

            # Build JSON with explicit backslashes (escaped as \\ in JSON source).
            $mainEsc = $main -replace '\\', '\\'
            $wtEsc   = $wt   -replace '\\', '\\'
            $payload = '{"mainRoot":"' + $mainEsc + '","worktreePath":"' + $wtEsc + '","includeFile":null}'

            $result = script:Invoke-Bin $payload
            $result.exit | Should -Be 0
            (Test-Path -LiteralPath (Join-Path $wt ".env.local")) | Should -BeTrue
        }
    }

    Context "W2: stdout is valid JSON parseable by ConvertFrom-Json" {
        It "emits a JSON object with copied/skipped/denied/errors arrays" {
            if (-not (Test-Path -LiteralPath $script:binJs)) {
                Set-ItResult -Skipped -Because "bin/worktree-copy-include.js not implemented yet"
                return
            }
            $main = script:New-FakeMainRepo "w2-main"
            $wt   = script:New-WorktreeDest  "w2-wt"
            Set-Content -LiteralPath (Join-Path $main ".worktreeinclude") -Value ".env.local" -NoNewline
            Set-Content -LiteralPath (Join-Path $main ".env.local")       -Value "x=1"        -NoNewline

            $mainFwd = $main -replace '\\', '/'
            $wtFwd   = $wt   -replace '\\', '/'
            $payload = '{"mainRoot":"' + $mainFwd + '","worktreePath":"' + $wtFwd + '","includeFile":null}'

            $result = script:Invoke-Bin $payload
            $result.exit | Should -Be 0
            { $script:parsed = $result.stdout | ConvertFrom-Json } | Should -Not -Throw
            $script:parsed.copied  | Should -Not -BeNullOrEmpty
            $script:parsed.PSObject.Properties.Name | Should -Contain "copied"
            $script:parsed.PSObject.Properties.Name | Should -Contain "skipped"
            $script:parsed.PSObject.Properties.Name | Should -Contain "denied"
            $script:parsed.PSObject.Properties.Name | Should -Contain "errors"
        }
    }

    Context "W3: Windows-style backslash worktreePath is normalized" {
        It "accepts worktreePath with backslashes and copies successfully" {
            if (-not (Test-Path -LiteralPath $script:binJs)) {
                Set-ItResult -Skipped -Because "bin/worktree-copy-include.js not implemented yet"
                return
            }
            $main = script:New-FakeMainRepo "w3-main"
            $wt   = script:New-WorktreeDest  "w3-wt"
            Set-Content -LiteralPath (Join-Path $main ".worktreeinclude") -Value ".env.local" -NoNewline
            Set-Content -LiteralPath (Join-Path $main ".env.local")       -Value "x=1"        -NoNewline

            # mainRoot uses forward slashes, worktreePath uses backslashes.
            $mainFwd = $main -replace '\\', '/'
            $wtEsc   = $wt   -replace '\\', '\\'
            $payload = '{"mainRoot":"' + $mainFwd + '","worktreePath":"' + $wtEsc + '","includeFile":null}'

            $result = script:Invoke-Bin $payload
            $result.exit | Should -Be 0
            (Test-Path -LiteralPath (Join-Path $wt ".env.local")) | Should -BeTrue
        }
    }
}
