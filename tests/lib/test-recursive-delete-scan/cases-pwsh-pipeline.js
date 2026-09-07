"use strict";

// Tests: hooks/lib/bash-write-targets/recursive-delete-scan/stdin-delivery.js
// Tags: scope:issue-specific, recursive-delete, bash-write-targets, guard, TL1
//
// stdin-delivery.js pwshCommandPipelineScript (round10 gap 2): the documented
// round-6 bypass shape — `pwsh -Command <script>` left UNQUOTED, so bash's own
// parser cuts the raw command at the outer `|` before pwsh ever sees one
// string. Proves the scan-level pipeline reconstruction, plus the round11 C4
// gaps (recursive LIST with no delete, the `powershell` alias, a 3+-stage
// pipeline). See ./harness.js for the shared runTable() runner.

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

// round11 C4: the round10 table's only allow-case dropped `-Recurse` entirely,
// so it never proved a pipeline that ENUMERATES recursively but never deletes
// is approved rather than over-blocked on `-Recurse` alone. Also missing: the
// `powershell` alias and a 3+-stage pipeline.
runTable("pwsh-command-pipeline-script-gaps (round11 C4)", [
  // Critical case: recursive LISTING with no delete verb downstream must be
  // approved — traced through pwsh.js: at the Select-Object segment,
  // hasRecursivePwshPipelineFlag's isDelete/isBlock test the CURRENT segment's
  // own command, and "select-object" matches neither, so the upstream
  // -Recurse is never consulted.
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
