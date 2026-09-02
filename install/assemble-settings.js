#!/usr/bin/env node
// assemble-settings.js
// Deploys ~/.claude/settings.json as a real file (no symlink) from agents/settings.json (base)
// + agents/settings-extension.json (extension) + the generated allow rules.
// The merge contract lives in install/lib/settings-assembly.js and the write in
// install/lib/settings-deploy.js — this file is only the CLI over them.
'use strict';

const { deployAssembledSettings } = require('./lib/settings-deploy');

try {
  const { outPath } = deployAssembledSettings({});
  console.log('Assembled: ' + outPath);
} catch (e) {
  const code = e && e.code ? e.code + ': ' : '';
  process.stderr.write('assemble-settings: ' + code + (e && e.message ? e.message : String(e)) + '\n');
  process.exitCode = 1;
}
