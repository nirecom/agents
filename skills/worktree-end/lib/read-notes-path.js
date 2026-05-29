#!/usr/bin/env node
// Read NOTES_BACKUP_PATH from final-report env JSON.
// argv[2] = env file path. Stdout: value (or empty string on any error).
// Exit 0 always — 4-branch fail-safe (missing file / malformed JSON / missing field / ok).

'use strict';

const fs = require('fs');

const p = process.argv[2];
try {
  const j = JSON.parse(fs.readFileSync(p, 'utf8'));
  process.stdout.write(j.NOTES_BACKUP_PATH || '');
} catch {
  process.stdout.write('');
}
