# Tests for install/win/vscode-settings.ps1

# Evaluated at discovery time so -Skip:(-not $script:ScriptExists) works in Pester 5
$script:ScriptPath = Join-Path $PSScriptRoot "..\install\win\vscode-settings.ps1"
$script:ScriptExists = Test-Path $script:ScriptPath

# The 8 keys that must appear in the output settings.json (also used in It blocks at discovery time)
$script:RequiredKeys = @(
    'chat.useClaudeMdFile',
    'chat.useAgentsMdFile',
    'chat.useNestedAgentsMdFiles',
    'github.copilot.chat.codeGeneration.useInstructionFiles',
    'chat.includeApplyingInstructions',
    'chat.promptFiles',
    'chat.promptFilesLocations',
    'chat.hookFilesLocations'
)

BeforeAll {
    # Recompute at runtime — $script: scope inside BeforeAll differs from file top-level scope
    $script:ScriptPath = Join-Path $PSScriptRoot "..\install\win\vscode-settings.ps1"

    function Invoke-VscodeSettings {
        param([string]$SettingsDir)
        $env:VSCODE_USER_SETTINGS_DIR = $SettingsDir
        $sp = $script:ScriptPath
        try {
            & $sp 2>&1
            return $LASTEXITCODE
        } finally {
            Remove-Item Env:VSCODE_USER_SETTINGS_DIR -ErrorAction SilentlyContinue
        }
    }
}

Describe "vscode-settings.ps1" {
    BeforeEach {
        $script:TestDir = [System.IO.Path]::GetTempPath() + "vscode-settings-test-" + [System.Guid]::NewGuid().ToString("N")
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
        $script:SettingsFile = Join-Path $script:TestDir "settings.json"
    }

    AfterEach {
        Remove-Item -Recurse -Force $script:TestDir -ErrorAction SilentlyContinue
    }

    Context "Normal cases" {
        It "Normal 1: creates settings.json with all 8 keys when file does not exist" -Skip:(-not $script:ScriptExists) {
            Invoke-VscodeSettings -SettingsDir $script:TestDir | Out-Null
            Test-Path $script:SettingsFile | Should -BeTrue
            $json = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json
            foreach ($key in $script:RequiredKeys) {
                $json.PSObject.Properties.Name | Should -Contain $key -Because "key '$key' must be present"
            }
        }

        It "Normal 2: adds 8 keys to existing file while preserving unrelated keys" -Skip:(-not $script:ScriptExists) {
            @{ "editor.fontSize" = 14 } | ConvertTo-Json | Set-Content $script:SettingsFile -Encoding UTF8
            Invoke-VscodeSettings -SettingsDir $script:TestDir | Out-Null
            $json = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json
            $json."editor.fontSize" | Should -Be 14 -Because "pre-existing key must be preserved"
            foreach ($key in $script:RequiredKeys) {
                $json.PSObject.Properties.Name | Should -Contain $key -Because "key '$key' must be added"
            }
        }

        It "Normal 3: creates a .bak file when settings.json already exists" -Skip:(-not $script:ScriptExists) {
            Set-Content $script:SettingsFile -Value '{"editor.fontSize":14}' -Encoding UTF8
            Invoke-VscodeSettings -SettingsDir $script:TestDir | Out-Null
            $bakFile = $script:SettingsFile + ".bak"
            Test-Path $bakFile | Should -BeTrue -Because ".bak must be created for existing file"
        }
    }

    Context "Idempotency cases" {
        It "Idempotency 4: running twice produces identical output without duplicating keys" -Skip:(-not $script:ScriptExists) {
            Invoke-VscodeSettings -SettingsDir $script:TestDir | Out-Null
            Invoke-VscodeSettings -SettingsDir $script:TestDir | Out-Null
            $second = Get-Content $script:SettingsFile -Raw
            # Key counts must not grow
            $json = $second | ConvertFrom-Json
            foreach ($key in $script:RequiredKeys) {
                $count = ($json.PSObject.Properties | Where-Object { $_.Name -eq $key }).Count
                $count | Should -Be 1 -Because "key '$key' must appear exactly once after two runs"
            }
        }
    }

    Context "Edge cases" {
        It "Edge 5: handles empty (0-byte) settings.json without error" -Skip:(-not $script:ScriptExists) {
            New-Item -ItemType File -Path $script:SettingsFile -Force | Out-Null
            { Invoke-VscodeSettings -SettingsDir $script:TestDir } | Should -Not -Throw
            $json = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json
            foreach ($key in $script:RequiredKeys) {
                $json.PSObject.Properties.Name | Should -Contain $key
            }
        }

        It "Edge 6: overwrites existing key with correct value (chat.promptFiles false -> true)" -Skip:(-not $script:ScriptExists) {
            @{ "chat.promptFiles" = $false } | ConvertTo-Json | Set-Content $script:SettingsFile -Encoding UTF8
            Invoke-VscodeSettings -SettingsDir $script:TestDir | Out-Null
            $json = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json
            $json."chat.promptFiles" | Should -Be $true -Because "script must overwrite incorrect value"
        }
    }

    Context "Error cases" {
        It "Error 7: exits 0 and does not create settings.json when directory does not exist" -Skip:(-not $script:ScriptExists) {
            $missing = Join-Path $script:TestDir "nonexistent"
            Invoke-VscodeSettings -SettingsDir $missing | Out-Null
            $LASTEXITCODE | Should -Be 0 -Because "missing dir should not be fatal"
            # Settings dir was not created (script skipped gracefully)
            Test-Path $missing | Should -BeFalse -Because "script must not create the missing directory"
        }

        It "Error 8: exits 0 and does not corrupt file when JSON is malformed" -Skip:(-not $script:ScriptExists) {
            $broken = "{ broken:"
            # Use WriteAllText to avoid Set-Content adding a trailing newline
            [System.IO.File]::WriteAllText($script:SettingsFile, $broken)
            Invoke-VscodeSettings -SettingsDir $script:TestDir | Out-Null
            $LASTEXITCODE | Should -Be 0
            # Original content must still be intact (file not silently cleared)
            $after = [System.IO.File]::ReadAllText($script:SettingsFile)
            $after | Should -Be $broken -Because "malformed JSON file must not be overwritten"
        }
    }
}
