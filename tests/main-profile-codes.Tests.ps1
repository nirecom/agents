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
            # Verify the join pattern is used — empty args produce empty string, not error
            $ProfileContent | Should -Match '\$args\s+-join\s+'
        }

        It "args are passed into the command string" {
            $codesBlock = ($ProfileContent -split 'function codes')[1] -split 'function ' | Select-Object -First 1
            $codesBlock | Should -Match '\$codeArgs' -Because "codeArgs variable must be referenced in command"
        }
    }
}
