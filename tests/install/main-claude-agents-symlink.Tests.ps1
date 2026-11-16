# Tests: install/win/dotfileslink.ps1
# Tags: installer, dotfileslink, pwsh-required, scope:common
# Structural tests for install/win/dotfileslink.ps1 — verifies the agents symlink entry
# Does NOT execute the install script (would touch real $HOME).

Describe "dotfileslink.ps1 agents symlink entry" {
    BeforeAll {
        $script:scriptPath = Join-Path $PSScriptRoot "..\..\install\win\dotfileslink.ps1"
        $script:content = Get-Content -Raw -LiteralPath $script:scriptPath
        # Closing Source with a quote keeps "skills\workflow-init" from matching the skills entry.
        $script:agentsPattern = '@\{\s*Source\s*=\s*"agents"\s*;\s*Dest\s*=\s*"\$ClaudeDir\\agents"\s*;\s*IsDir\s*=\s*\$true\s*\}'
        $script:skillsPattern = '@\{\s*Source\s*=\s*"skills"\s*;\s*Dest\s*=\s*"\$ClaudeDir\\skills"\s*;\s*IsDir\s*=\s*\$true\s*\}'
        $script:rulesPattern  = '@\{\s*Source\s*=\s*"rules"\s*;\s*Dest\s*=\s*"\$ClaudeDir\\rules"\s*;\s*IsDir\s*=\s*\$true\s*\}'
    }

    Context "Normal cases" {
        It "contains an entry with Source agents, Dest \$ClaudeDir\agents, IsDir = \$true" {
            $script:content | Should -Match $script:agentsPattern
        }

        It "uses the same hashtable format as the skills entry" {
            $script:content | Should -Match $script:skillsPattern
            $script:content | Should -Match $script:agentsPattern
        }

        It "uses the same hashtable format as the rules entry" {
            $script:content | Should -Match $script:rulesPattern
            $script:content | Should -Match $script:agentsPattern
        }
    }

    Context "Idempotency cases" {
        It "contains exactly one hashtable entry with Source agents (no duplicate)" {
            $matches = [regex]::Matches($script:content, 'Source\s*=\s*"agents"')
            $matches.Count | Should -Be 1
        }
    }
}
