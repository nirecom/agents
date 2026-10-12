=== bin/lib/launch-pwsh.sh
run_pwsh() {
  pwsh -NoProfile -Command "Invoke-Pester -Path '$1' -CI"
}
=== hooks/lib/test-language-registry.json
{ "command": ["pwsh", "-NoProfile", "-Command", "Invoke-Pester -Path '{nativePathSq}' -CI"] }
=== bin/lib/test-wrappers-old/pester.ps1
Invoke-Pester -Path $Path -CI
=== bin/lib/pester-config.sh
# Invoke-Pester -Path x -CI is how the old launcher ran it (a comment: never flagged)
pwsh -NoProfile -Command "Invoke-Pester -Configuration $cfg"
