#!/usr/bin/env node
// Extract multiple fields from a JSON object on stdin.
// Usage: gh pr view --json title,url,state | extract-pr-fields.js --fields title,url,state
// stdout: <field>=<value>\n per field in the specified order.
// Exit 0 always (parse failure → all fields empty).

'use strict';

const args = process.argv.slice(2);
const idx = args.indexOf('--fields');
const fields = idx >= 0 && args[idx + 1] ? args[idx + 1].split(',') : [];

let buf = '';
process.stdin.on('data', (c) => { buf += c; });
process.stdin.on('end', () => {
  let obj = {};
  try {
    obj = JSON.parse(buf);
    if (obj === null || typeof obj !== 'object') obj = {};
  } catch {
    obj = {};
  }
  for (const f of fields) {
    const v = obj[f];
    const s = v === undefined || v === null ? '' : String(v);
    process.stdout.write(`${f}=${s}\n`);
  }
});
