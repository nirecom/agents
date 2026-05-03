# wait-vscode-window.ps1 - Wait for a VS Code window to close by polling window titles
# Usage: wait-vscode-window.ps1 [-TitlePattern] <string> [-PollInterval <int>] [-AppearTimeout <int>]
#
# Polls all visible window titles via Win32 EnumWindows API.
# Phase 1: Wait for a window matching "<TitlePattern> - Visual Studio Code" to appear
# Phase 2: Wait for that window to disappear, then exit

param(
    [Parameter(Mandatory, Position = 0)]
    [string]$TitlePattern,

    [int]$PollInterval = 5,
    [int]$AppearTimeout = 30
)

Set-StrictMode -Version Latest

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class VsCodeWindowFinder {
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    public static List<string> GetVisibleWindowTitles() {
        var titles = new List<string>();
        EnumWindows((hWnd, lParam) => {
            if (IsWindowVisible(hWnd)) {
                var sb = new StringBuilder(512);
                GetWindowText(hWnd, sb, 512);
                if (sb.Length > 0) titles.Add(sb.ToString());
            }
            return true;
        }, IntPtr.Zero);
        return titles;
    }
}
"@

$suffix = "$TitlePattern - Visual Studio Code"
$suffixWs = "$TitlePattern (Workspace) - Visual Studio Code"

function Find-VsCodeWindow {
    $titles = [VsCodeWindowFinder]::GetVisibleWindowTitles()
    # Match: "... - <name> - Visual Studio Code..." or "<name> - Visual Studio Code..."
    # Also match workspace variant: "<name> (Workspace) - Visual Studio Code..."
    # The " - " prefix prevents partial matches (e.g., "app" won't match "my-app")
    $titles | Where-Object {
        $_ -like "* - $suffix*" -or $_ -like "$suffix*" -or
        $_ -like "* - $suffixWs*" -or $_ -like "$suffixWs*"
    }
}

# Phase 1: Wait for window to appear
$appeared = $false
$elapsed = 0
while ($elapsed -lt $AppearTimeout) {
    Start-Sleep 3
    $elapsed += 3
    if (Find-VsCodeWindow) { $appeared = $true; break }
}
if (-not $appeared) { exit 0 }

# Phase 2: Wait for window to disappear
while ($true) {
    Start-Sleep $PollInterval
    if (-not (Find-VsCodeWindow)) { break }
}
