#!/usr/bin/env node
// Write Final Report env vars to JSON file.
// argv[2] = output JSON path.
// Reads 18 env vars (BRANCH_DELETED intentionally omitted — issue #504 fail-safe).
// Exit 0 = success, 1 = write failure.
//
// Post-render fields (NOT written by this script):
//   - `reported` (boolean): set to true by `bin/worktree-final-report.js`
//     after the renderer successfully writes the Final Report to stdout.
//     `hooks/stop-final-report-guard.js` reads this flag to decide whether
//     to block the Stop event. See issue #626.
//   - `reportedAt` (ISO 8601 string): timestamp of the successful emission,
//     stamped alongside `reported` by the renderer.
// These fields are appended to the env-file by the renderer via atomic
// write (temp + rename); this script only writes the initial 18 fields.

'use strict';

const fs = require('fs');

const FIELDS = [
  'PR_NUMBER',
  'PR_TITLE',
  'PR_URL',
  'PR_STATE',
  'BRANCH',
  'WORKTREE_PATH',
  'CREATED_DATE',
  'BACKUP_MANIFEST_PATH',
  'NOTES_BACKUP_PATH',
  'CLAUDE_CODE_RESTART_REQUIRED',
  'CC_RESTART_REQUIRED',
  'CC_RESTART_REASON',
  'VSCODE_RELOAD_REQUIRED',
  'VSCODE_RELOAD_REASON',
  'INSTALLER_RERUN_REQUIRED',
  'INSTALLER_RERUN_REASON',
  'OS_REBOOT_REQUIRED',
  'OS_REBOOT_REASON',
];

const outPath = process.argv[2];
if (!outPath) {
  process.stderr.write('ERROR: output path argument required\n');
  process.exit(1);
}

const data = {};
for (const f of FIELDS) {
  data[f] = process.env[f] || '';
}

try {
  fs.writeFileSync(outPath, JSON.stringify(data, null, 2));
  process.exit(0);
} catch (e) {
  process.stderr.write(`ERROR: write failed: ${e.message}\n`);
  process.exit(1);
}
