"use strict";

// Tests: hooks/lib/bash-write-targets/recursive-delete-scan/stdin-delivery.js
// Tags: scope:issue-specific, recursive-delete, bash-write-targets, guard, TL1
//
// Bypass shape: an UNQUOTED `pwsh -Command <script>` is cut by bash at the
// outer `|`, so the scan must reconstruct the pipeline before judging it.

const { runTable } = require("./harness");

runTable("pwsh-command-pipeline-script (round10 gap 2)", [
  {
    label: "pwsh -Command Get-ChildItem d -Recurse | Remove-Item (unquoted pipeline reconstruction blocks)",
    cmd: "pwsh -Command Get-ChildItem d -Recurse | Remove-Item",
    want: true,
  },
  {
    label: "pwsh -Command Get-ChildItem d | Remove-Item (same shape, no -Recurse, harmless)",
    cmd: "pwsh -Command Get-ChildItem d | Remove-Item",
    want: false,
  },
]);

runTable("pwsh-command-pipeline-script-gaps (round11 C4)", [
  // `-Recurse` alone must never block: the verdict comes from the delete verb
  // downstream, so a recursive enumeration with no delete stays approved.
  {
    label: "pwsh -Command Get-ChildItem d -Recurse | Select-Object Name (recursive LIST, no delete, must approve)",
    cmd: "pwsh -Command Get-ChildItem d -Recurse | Select-Object Name",
    want: false,
  },
  {
    label: "powershell -Command Get-ChildItem d -Recurse | Remove-Item (powershell alias, same pipeline shape, blocks)",
    cmd: "powershell -Command Get-ChildItem d -Recurse | Remove-Item",
    want: true,
  },
  {
    label: "pwsh -Command Get-ChildItem d -Recurse | Where-Object { $_.Name -like '*' } | Remove-Item (3-stage pipeline, delete at the tail, blocks)",
    cmd: "pwsh -Command Get-ChildItem d -Recurse | Where-Object { $_.Name -like '*' } | Remove-Item",
    want: true,
  },
]);
