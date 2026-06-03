#!/usr/bin/env node
'use strict';

const fs   = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');

const REPO_ROOT = process.env.REPO_ROOT;
if (!REPO_ROOT) {
  process.stderr.write('REPO_ROOT not set\n');
  process.exit(2);
}

const REPO_ROOT_REAL = fs.realpathSync(REPO_ROOT);

// Credential/sensitive-file blocklist
const BLOCKED_NAMES = new Set([
  'WORKTREE_NOTES.md',
  '.netrc', '.npmrc', '.pypirc', '.gitconfig',
  '.private-info-blocklist', '.private-info-allowlist',
]);
const BLOCKED_EXT = new Set([
  '.key', '.pem', '.p12', '.pfx', '.crt', '.cer', '.der',
  '.keystore', '.jks', '.gpg', '.asc', '.ppk', '.kdbx',
]);
const BLOCKED_DOTENV = /^\.env(\..+)?$/;
// SSH private key basenames (allow .pub)
const BLOCKED_SSH_KEY = /^id_(rsa|dsa|ecdsa|ed25519|xmss)$/;
// Directories whose entire subtree is blocked
const BLOCKED_DIR_PREFIXES = ['.git', '.ssh'];

const MAX_FILE_BYTES = 5 * 1024 * 1024;  // 5 MB defensive cap (MEDIUM-4)
const BINARY_PROBE_BYTES = 8192;         // binary scan window in bytes
const MCP_FS_DEBUG = process.env.MCP_FS_DEBUG === '1';
function dbg(msg) { if (MCP_FS_DEBUG) process.stderr.write('[mcp-fs] ' + msg + '\n'); }

function isBlocked(relPath) {
  const parts = relPath.split(path.sep);
  // Block entire .git/ and .ssh/ subtrees
  if (BLOCKED_DIR_PREFIXES.includes(parts[0])) return true;
  const base = parts[parts.length - 1];
  if (BLOCKED_DOTENV.test(base)) return true;
  if (BLOCKED_NAMES.has(base)) return true;
  if (BLOCKED_SSH_KEY.test(base)) return true;
  if (BLOCKED_EXT.has(path.extname(base).toLowerCase())) return true;
  return false;
}

function isBinary(buf) {
  // Scan first 8 KB for null bytes
  const sample = buf.slice(0, 8192);
  for (let i = 0; i < sample.length; i++) {
    if (sample[i] === 0) return true;
  }
  return false;
}

function deny(id, message) {
  dbg('deny: ' + message);
  return { jsonrpc: '2.0', id, error: { code: -32000, message } };
}

function ok(id, content) {
  return { jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: content }] } };
}

function handleReadFile(id, args) {
  const filePath = (args && args.path) ? String(args.path) : '';
  if (!filePath) return deny(id, 'path argument required');

  // Resolve absolute path: treat paths as relative to REPO_ROOT
  const abs = path.isAbsolute(filePath)
    ? filePath
    : path.join(REPO_ROOT_REAL, filePath);

  // Canonicalize to resolve any symlinks in the path components
  let real;
  try {
    real = fs.realpathSync(abs);
  } catch (_) {
    // File doesn't exist or can't be resolved
    return deny(id, `file not found: ${filePath}`);
  }

  // Boundary check — must be inside REPO_ROOT_REAL
  const rel = path.relative(REPO_ROOT_REAL, real);
  if (rel === '..' || rel.startsWith('..' + path.sep) || path.isAbsolute(rel)) {
    return deny(id, 'path outside REPO_ROOT');
  }

  // Blocklist check
  if (isBlocked(rel)) {
    return deny(id, `file is blocked: ${path.basename(rel)}`);
  }

  // Must be a regular file (not a directory)
  let stat;
  try {
    stat = fs.statSync(real);
  } catch (_) {
    return deny(id, `cannot stat: ${filePath}`);
  }
  if (!stat.isFile()) {
    return deny(id, `not a regular file: ${filePath}`);
  }

  if (stat.size > MAX_FILE_BYTES) {
    return deny(id, `file too large: ${stat.size} bytes (cap ${MAX_FILE_BYTES})`);
  }

  let fd;
  try {
    fd = fs.openSync(real, 'r');
    const fstat = fs.fstatSync(fd);
    const fileSize = fstat.size;
    const probe = Buffer.alloc(BINARY_PROBE_BYTES);
    const probeLen = fs.readSync(fd, probe, 0, BINARY_PROBE_BYTES, 0);
    if (isBinary(probe.slice(0, probeLen))) {
      return deny(id, `binary file not served: ${filePath}`);
    }
    const full = Buffer.alloc(fileSize);
    probe.copy(full, 0, 0, probeLen);
    if (fileSize > probeLen) {
      fs.readSync(fd, full, probeLen, fileSize - probeLen, probeLen);
    }
    dbg('serve: ' + filePath);
    return ok(id, full.toString('utf8'));
  } catch (e) {
    return deny(id, 'read error: ' + e.message);
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

// List tools (MCP initialize / tools/list)
function handleToolsList(id) {
  return {
    jsonrpc: '2.0',
    id,
    result: {
      tools: [{
        name: 'read_file',
        description: 'Read a text file from the repository (REPO_ROOT-confined)',
        inputSchema: {
          type: 'object',
          properties: {
            path: { type: 'string', description: 'Repo-relative or absolute path' },
          },
          required: ['path'],
        },
      }],
    },
  };
}

function handleInitialize(id) {
  return {
    jsonrpc: '2.0',
    id,
    result: {
      protocolVersion: '2024-11-05',
      capabilities: { tools: {} },
      serverInfo: { name: 'mcp-fs-server', version: '1.0.0' },
    },
  };
}

function dispatch(line) {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch (_) {
    return { jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } };
  }
  const { id, method, params } = msg;
  switch (method) {
    case 'initialize':
      return handleInitialize(id);
    case 'initialized':
      return null; // notification, no response
    case 'tools/list':
      return handleToolsList(id);
    case 'tools/call': {
      const toolName = params && params.name;
      if (toolName === 'read_file') {
        return handleReadFile(id, params && params.arguments);
      }
      return deny(id, `unknown tool: ${toolName}`);
    }
    default:
      return { jsonrpc: '2.0', id, error: { code: -32601, message: `Method not found: ${method}` } };
  }
}

// stdin → line-delimited JSON RPC
process.stdin.resume();
process.stdin.setEncoding('utf8');

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });

rl.on('line', (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  const response = dispatch(trimmed);
  if (response !== null) {
    process.stdout.write(JSON.stringify(response) + '\n');
  }
});

rl.on('close', () => process.exit(0));
process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));
