#!/usr/bin/env node
// assemble-settings.js
// Merges agents/settings.json + agents/settings-extension.json (if present)
// into ~/.claude/settings.json as a real file (no symlink).
//
// Schema-aware merge (avoids prototype pollution from generic deep-merge):
//   - hooks.*                          : arrays concatenated
//   - permissions.allow/deny/ask       : arrays concatenated
//   - permissions.additionalDirectories: arrays concatenated
//   - permissions (other keys)         : extension overrides base
//   - env, attribution                 : object-level override (extension keys win)
//   - all other top-level keys         : extension overrides base
'use strict';

const fs   = require('fs');
const path = require('path');
const os   = require('os');

const agentsRoot = path.resolve(__dirname, '..');
const basePath   = path.join(agentsRoot, 'settings.json');
const extPath    = path.join(agentsRoot, 'settings-extension.json');
const outPath    = path.join(os.homedir(), '.claude', 'settings.json');

function mergeSettings(base, ext) {
  const result = JSON.parse(JSON.stringify(base)); // deep clone base

  for (const key of Object.keys(ext)) {
    if (key === 'hooks') {
      if (!result.hooks) result.hooks = {};
      for (const event of Object.keys(ext.hooks)) {
        result.hooks[event] = (result.hooks[event] || []).concat(ext.hooks[event]);
      }

    } else if (key === 'permissions') {
      if (!result.permissions) result.permissions = {};
      const concatKeys = ['allow', 'deny', 'ask', 'additionalDirectories'];
      for (const pk of Object.keys(ext.permissions)) {
        if (concatKeys.includes(pk)) {
          result.permissions[pk] = (result.permissions[pk] || []).concat(ext.permissions[pk]);
        } else {
          result.permissions[pk] = ext.permissions[pk];
        }
      }

    } else if (key === 'env' || key === 'attribution') {
      result[key] = Object.assign({}, result[key] || {}, ext[key]);

    } else {
      result[key] = ext[key];
    }
  }

  return result;
}

const base = JSON.parse(fs.readFileSync(basePath, 'utf8'));
const ext  = fs.existsSync(extPath) ? JSON.parse(fs.readFileSync(extPath, 'utf8')) : {};
const out  = mergeSettings(base, ext);

fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + '\n', 'utf8');
console.log('Assembled: ' + outPath);
