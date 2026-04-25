# Structural tests for install/win/dotfileslink.ps1 — verifies claude-global\agents symlink entry
# Does NOT execute the install script (would touch real $HOME).

Describe "dotfileslink.ps1 claude-global\agents symlink entry" {
    BeforeAll {
        $script:scriptPath = Join-Path $PSScriptRoot "..\install\win\dotfileslink.ps1"
        $script:content = Get-Content -Raw -LiteralPath $script:scriptPath
    }

    Context "Normal cases" {
        It "contains an entry with Source claude-global\agents, Dest \$HOME\.claude\agents, IsDir = \$true" {
            # Match the hashtable entry format used for skills/rules
            $pattern = '@\{\s*Source\s*=\s*"claude-global\\agents"\s*;\s*Dest\s*=\s*"\$HOME\\\.claude\\agents"\s*;\s*IsDir\s*=\s*\$true\s*\}'
            $script:content | Should -Match $pattern
        }

        It "uses the same hashtable format as the skills entry" {
            $skillsPattern   = '@\{\s*Source\s*=\s*"claude-global\\skills"\s*;\s*Dest\s*=\s*"\$HOME\\\.claude\\skills"\s*;\s*IsDir\s*=\s*\$true\s*\}'
            $agentsPattern   = '@\{\s*Source\s*=\s*"claude-global\\agents"\s*;\s*Dest\s*=\s*"\$HOME\\\.claude\\agents"\s*;\s*IsDir\s*=\s*\$true\s*\}'
            $script:content | Should -Match $skillsPattern
            $script:content | Should -Match $agentsPattern
        }

        It "uses the same hashtable format as the rules entry" {
            $rulesPattern    = '@\{\s*Source\s*=\s*"claude-global\\rules"\s*;\s*Dest\s*=\s*"\$HOME\\\.claude\\rules"\s*;\s*IsDir\s*=\s*\$true\s*\}'
            $agentsPattern   = '@\{\s*Source\s*=\s*"claude-global\\agents"\s*;\s*Dest\s*=\s*"\$HOME\\\.claude\\agents"\s*;\s*IsDir\s*=\s*\$true\s*\}'
            $script:content | Should -Match $rulesPattern
            $script:content | Should -Match $agentsPattern
        }
    }

    Context "Idempotency cases" {
        It "contains the string 'claude-global\agents' exactly once (no duplicate)" {
            $matches = [regex]::Matches($script:content, [regex]::Escape('claude-global\agents'))
            $matches.Count | Should -Be 1
        }
    }
}
