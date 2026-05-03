# Tests for bin/wait-vscode-window.ps1 and title matching logic

BeforeAll {
    $AgentsDir = Split-Path -Parent $PSScriptRoot
    $script:WaitScript = Join-Path $AgentsDir "bin\wait-vscode-window.ps1"
}

Describe "wait-vscode-window.ps1" {
    Context "Normal cases" {
        It "EnumWindows type compiles and returns window titles" {
            # Load the type by running the script briefly (will exit quickly with no match)
            & $WaitScript -TitlePattern "nonexistent-ws-$(Get-Random)" -AppearTimeout 3 2>$null
            $titles = [VsCodeWindowFinder]::GetVisibleWindowTitles()
            $titles | Should -Not -BeNullOrEmpty -Because "at least the terminal window should exist"
        }

        It "exits when no matching VS Code window appears (appear timeout)" {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            & $WaitScript -TitlePattern "nonexistent-ws-$(Get-Random)" -AppearTimeout 3
            $sw.Stop()
            $LASTEXITCODE | Should -Be 0
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 10 `
                -Because "should exit after appear timeout without hanging"
        }
    }

    Context "Title matching logic" {
        It "matches exact workspace name with file prefix" {
            $titles = @("file.txt - dotfiles - Visual Studio Code")
            $suffix = "dotfiles - Visual Studio Code"
            $found = $titles | Where-Object { $_ -like "* - $suffix*" -or $_ -like "$suffix*" }
            $found | Should -Not -BeNullOrEmpty
        }

        It "matches workspace without file prefix" {
            $titles = @("dotfiles - Visual Studio Code")
            $suffix = "dotfiles - Visual Studio Code"
            $found = $titles | Where-Object { $_ -like "* - $suffix*" -or $_ -like "$suffix*" }
            $found | Should -Not -BeNullOrEmpty
        }

        It "matches workspace with remote suffix" {
            $titles = @("file.txt - dotfiles - Visual Studio Code [WSL: Ubuntu]")
            $suffix = "dotfiles - Visual Studio Code"
            $found = $titles | Where-Object { $_ -like "* - $suffix*" -or $_ -like "$suffix*" }
            $found | Should -Not -BeNullOrEmpty
        }

        It "matches workspace without file prefix but with remote suffix" {
            $titles = @("dotfiles - Visual Studio Code [SSH: remote]")
            $suffix = "dotfiles - Visual Studio Code"
            $found = $titles | Where-Object { $_ -like "* - $suffix*" -or $_ -like "$suffix*" }
            $found | Should -Not -BeNullOrEmpty
        }

        It "does not match partial workspace name (app vs my-app)" {
            $titles = @(
                "main.py - my-app - Visual Studio Code",
                "my-app - Visual Studio Code"
            )
            $suffix = "app - Visual Studio Code"
            $found = $titles | Where-Object { $_ -like "* - $suffix*" -or $_ -like "$suffix*" }
            $found | Should -BeNullOrEmpty
        }

        It "distinguishes between similar names in multiple windows" {
            $titles = @(
                "file.txt - my-app - Visual Studio Code",
                "index.js - app - Visual Studio Code"
            )
            $suffix = "app - Visual Studio Code"
            $found = $titles | Where-Object { $_ -like "* - $suffix*" -or $_ -like "$suffix*" }
            $found | Should -HaveCount 1
            $found | Should -BeLike "*index.js*"
        }
    }

    Context "Error cases" {
        It "requires TitlePattern parameter" {
            { & $WaitScript 2>$null } | Should -Throw
        }

        It "exits cleanly when VS Code is not running" {
            & $WaitScript -TitlePattern "no-such-workspace-$(Get-Random)" -AppearTimeout 3
            $LASTEXITCODE | Should -Be 0
        }
    }

    Context "Edge cases" {
        It "handles workspace names with spaces" {
            $titles = @("index.ts - My Project - Visual Studio Code")
            $suffix = "My Project - Visual Studio Code"
            $found = $titles | Where-Object { $_ -like "* - $suffix*" -or $_ -like "$suffix*" }
            $found | Should -Not -BeNullOrEmpty
        }

        It "handles workspace names with dots" {
            $titles = @("README.md - my.project.v2 - Visual Studio Code")
            $suffix = "my.project.v2 - Visual Studio Code"
            $found = $titles | Where-Object { $_ -like "* - $suffix*" -or $_ -like "$suffix*" }
            $found | Should -Not -BeNullOrEmpty
        }

        It "handles workspace names with parentheses" {
            $titles = @("file.txt - project (old) - Visual Studio Code")
            $suffix = "project (old) - Visual Studio Code"
            $found = $titles | Where-Object { $_ -like "* - $suffix*" -or $_ -like "$suffix*" }
            $found | Should -Not -BeNullOrEmpty
        }

        It "matches .code-workspace title with (Workspace) suffix" {
            $titles = @("Welcome - ai (Workspace) - Visual Studio Code")
            $suffix = "ai - Visual Studio Code"
            $suffixWs = "ai (Workspace) - Visual Studio Code"
            $found = $titles | Where-Object {
                $_ -like "* - $suffix*" -or $_ -like "$suffix*" -or
                $_ -like "* - $suffixWs*" -or $_ -like "$suffixWs*"
            }
            $found | Should -Not -BeNullOrEmpty
        }

        It "does not match plain folder when only workspace variant exists" {
            $titles = @("Welcome - ai (Workspace) - Visual Studio Code")
            $suffix = "ai - Visual Studio Code"
            # Without workspace variant, plain suffix should NOT match
            $found = $titles | Where-Object { $_ -like "* - $suffix*" -or $_ -like "$suffix*" }
            $found | Should -BeNullOrEmpty
        }
    }
}
