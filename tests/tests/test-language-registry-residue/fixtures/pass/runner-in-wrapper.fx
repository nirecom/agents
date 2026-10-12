=== bin/lib/test-wrappers/pester.ps1
param([string]$Path)
Invoke-Pester -Path $Path -CI
=== hooks/lib/test-language-registry.json
{ "command": ["pwsh", "-NoProfile", "-File", "{wrapper}", "-Path", "{nativePath}"] }
=== bin/lib/launch-pwsh.sh
run_pwsh() { pwsh -NoProfile -File "$1" -Path "$2"; }
